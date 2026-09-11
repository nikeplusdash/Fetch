import SwiftUI
import UniformTypeIdentifiers
import FetchKit

/**
 Sheet presented from the Downloads toolbar's Add button (and ⌘N).

 Takes a magnet **or** a hoster link (7e §5.1). `PastedLink` validates the
 field live so the confirm button can only fire on something actionable;
 confirming then awaits the debrid, which does not return until the torrent
 or the link is ready (§ `DownloadEngine`'s poll backoff) — the indefinite
 wait is why this shows an indeterminate "Preparing…" state rather than a
 determinate progress bar.

 The status line carries four distinct refusals rather than one "invalid
 link", because whether the problem is the link, the host or the account
 changes what the user should do about it.
 */
struct AddLinkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var linkText: String
    @State private var isPreparing = false
    @State private var availability: (text: String, answer: LinkAvailability)?
    @State private var isConfirmingUncached = false
    @State private var errorMessage: String?
    @State private var addTask: Task<Void, Never>?

    init(initialText: String = "") {
        _linkText = State(initialValue: initialText)
    }

    private var resolved: PastedLink { model.resolvePastedLink(linkText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ThemedDivider()

            VStack(alignment: .leading, spacing: Spacing.s12) {
                HStack(spacing: Spacing.s8) {
                    TextField("magnet:?xt=urn:btih:… or https://…", text: $linkText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isPreparing)
                        .onSubmit(confirm)

                    Button("Choose .torrent…") { chooseTorrentFile() }
                        .disabled(isPreparing)
                }

                refusalLine
            }
            .padding(.horizontal, WindowMetrics.sheetInset)
            .padding(.vertical, Spacing.s14)

            ThemedDivider()
            footer
        }
        .frame(width: 440)
        .onDisappear {
            addTask?.cancel()
            if case .magnet(let magnet) = resolved {
                model.forgetDestinationOverride(key: magnet.infoHash.hex)
            }
        }
        .confirmationDialog(
            "Queue this on \(providerName(currentAvailability?.provider)) ?",
            isPresented: $isConfirmingUncached,
            titleVisibility: .visible
        ) {
            Button("Queue anyway") {
                isConfirmingUncached = false
                proceed()
            }
            Button("Cancel", role: .cancel) { isConfirmingUncached = false }
        } message: {
            Text("No configured debrid has this yet, so it has to fetch the "
                 + "whole torrent before your download starts. That uses a slot "
                 + "on your account and can take a long time.")
        }
        .onChange(of: linkText) { _, _ in
            availability = nil
            isConfirmingUncached = false
            Task { await resolveAvailability() }
        }
        .task { await resolveAvailability() }
        .task { await model.refreshHostCoverage() }
    }

    private var header: some View {
        SheetHeaderBlock(title: headerTitle, tag: statusTag) {
            switch resolved {
            case .magnet(let magnet):
                Text(MagnetOffer(magnet: magnet).shortHash)
                    .font(FetchFont.footnoteMono)
                if model.providers.count > 1 {
                    SheetFactSeparator()
                    providerPicker
                }
                SheetFactSeparator()
                DestinationReadoutButton(
                    readout: model.destinationReadout(
                        key: magnet.infoHash.hex, metadata: metadata(for: magnet)),
                    isOverridden: model.hasDestinationOverride(
                        key: magnet.infoHash.hex, metadata: metadata(for: magnet)),
                    menu: destinationMenu(for: magnet))

            case .hosted(_, let host, let provider):
                Text(host.displayName)
                SheetFactSeparator()
                Text("via \(providerName(provider))")

            default:
                EmptyView()
            }
        }
    }

    private var headerTitle: String {
        switch resolved {
        case .magnet(let magnet): MagnetOffer(magnet: magnet).displayName
        case .hosted(let url, _, _), .hostDown(let url, _): url.lastPathComponent
        default: "Add Link"
        }
    }

    private var statusTag: TagPill? {
        switch resolved {
        case .magnet:
            switch currentAvailability {
            case .none, .noProviders:
                return nil
            case .cached(let id):
                return TagPill(
                    title: "Ready", tone: .ready,
                    explanation: "\(providerName(id)) already holds this, so it "
                        + "downloads immediately.")
            case .notCached(let id):
                return TagPill(
                    title: "Queued", tone: .waiting,
                    explanation: "No configured service has this yet. "
                        + "\(providerName(id)) would fetch it first, which can "
                        + "take a while.")
            case .unknowable(let id):
                return TagPill(
                    title: "Unknown", tone: .quiet,
                    explanation: "\(providerName(id)) cannot report whether it "
                        + "already holds this.")
            }
        case .hosted:
            return TagPill(
                title: "Ready", tone: .ready,
                explanation: "A debrid covers this host, so it downloads "
                    + "without a queue.")
        default:
            return nil
        }
    }

    @ViewBuilder
    private var refusalLine: some View {
        switch resolved {
        case .hostDown(_, let host):
            status("\(host.displayName) is reported down. It may work again later.",
                   tint: Palette.attention)
        case .unsupportedHost(_, let hostName):
            status("No configured debrid handles \(hostName).", tint: Palette.miss)
        case .checkingCoverage:
            status("Checking which debrid handles this…", tint: Palette.textSecondary)
        case .noDebridConfigured:
            status("No debrid configured. Add one in Settings.", tint: Palette.miss)
        case .invalid:
            status("Not a magnet link or a web address.", tint: Palette.miss)
        case .magnet where currentAvailability == nil:
            status("Checking availability…", tint: Palette.textSecondary)
        default:
            EmptyView()
        }
    }

    private func metadata(for magnet: MagnetLink) -> ReleaseMetadata {
        SearchResult.pastedMagnet(magnet, source: AppModel.droppedSource).metadata
    }

    private func destinationMenu(for magnet: MagnetLink) -> DestinationMenuItems {
        DestinationMenuItems(
            entries: model.destinationEntries(for: metadata(for: magnet)),
            root: model.destinationRoot,
            selected: model.selectedDestinationEntry(
                key: magnet.infoHash.hex, metadata: metadata(for: magnet)),
            onSelect: { model.selectDestination($0, key: magnet.infoHash.hex, metadata: metadata(for: magnet)) })
    }

    private var currentAvailability: LinkAvailability? {
        guard let availability, availability.text == linkText.trimmingCharacters(
            in: .whitespacesAndNewlines) else { return nil }
        return availability.answer
    }

    private func resolveAvailability() async {
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .magnet(let magnet) = model.resolvePastedLink(text) else { return }
        let answer = await model.availability(forMagnet: magnet.raw)
        if linkText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
            availability = (text, answer)
        }
    }

    private func chooseTorrentFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType("com.bittorrent.torrent")].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(torrentAt: url)
    }

    func load(torrentAt url: URL) {
        guard let magnet = model.magnet(fromTorrentFileAt: url) else {
            errorMessage = "“\(url.lastPathComponent)” is not a readable .torrent file."
            return
        }
        errorMessage = nil
        linkText = magnet.raw
    }

    private func status(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(FetchFont.callout)
            .foregroundStyle(tint)
            .lineLimit(2)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func providerName(_ id: DebridProviderID?) -> String {
        guard let id else { return "your debrid" }
        return model.providers.first { $0.id == id }?.displayName ?? id.rawValue
    }

    private var canAdd: Bool {
        guard resolved.isActionable, !isPreparing else { return false }
        if case .magnet = resolved { return currentAvailability != nil }
        return true
    }

    private var addButtonTitle: String {
        currentAvailability?.needsConfirmation == true ? "Queue…" : "Add"
    }

    private var footer: some View {
        HStack(spacing: Spacing.s12) {
            Spacer()
            Button("Cancel") {
                addTask?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            if resolved.isActionable {
                Button("Add to Cloud") { proceedToCloud() }
                    .disabled(isPreparing)
                    .help("Adds this to your debrid account and leaves it there. "
                          + "Nothing is downloaded to this Mac.")
            }

            PrimaryActionButton(
                title: addButtonTitle,
                isBusy: isPreparing,
                isEnabled: canAdd,
                action: confirm)
        }
        .padding(.horizontal, WindowMetrics.sheetInset)
        .padding(.vertical, Spacing.s12)
    }

    private var providerPicker: some View {
        Menu {
            Picker("Via", selection: Binding(
                get: { model.pinnedProvider },
                set: { model.pinProvider($0) }
            )) {
                Text("Auto").tag(DebridProviderID?.none)
                ForEach(model.providers, id: \.id) { provider in
                    Text(provider.displayName).tag(DebridProviderID?.some(provider.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text("via \(providerName(model.pinnedProvider ?? currentAvailability?.provider))")
                .font(FetchFont.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which debrid service downloads this")
    }

    private func confirm() {
        guard canAdd else { return }
        if currentAvailability?.needsConfirmation == true, !isConfirmingUncached {
            isConfirmingUncached = true
            return
        }
        proceed()
    }

    /**
     Hands the link to the account and closes.

     The uncached confirmation does not gate this. That dialog warns about a
     long wait before a *local download* starts, and there is no local
     download here — an uncached torrent is the case this button exists for.
     */
    private func proceedToCloud() {
        let resolution = resolved
        errorMessage = nil
        isPreparing = true
        addTask = Task {
            do {
                switch resolution {
                case .magnet(let magnet):
                    try await model.addToCloud(magnet: magnet)
                case .hosted(let url, _, let provider):
                    try await model.addToCloud(hostedLink: url, using: provider)
                default:
                    isPreparing = false
                    return
                }
                isPreparing = false
                dismiss()
            } catch is CancellationError {
            } catch {
                isPreparing = false
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func proceed() {
        let resolution = resolved
        errorMessage = nil
        isPreparing = true
        addTask = Task {
            do {
                switch resolution {
                case .magnet(let magnet):
                    let metadata = metadata(for: magnet)
                    try await model.prepareInBackground(
                        magnet.raw,
                        subfolder: model.plannedSubfolder(
                            key: magnet.infoHash.hex, metadata: metadata),
                        metadata: metadata,
                        displayName: magnet.displayName)
                case .hosted(let url, _, let provider):
                    try await model.addHostedLink(url, using: provider)
                default:
                    isPreparing = false
                    return
                }
                isPreparing = false
                dismiss()
            } catch is CancellationError {
            } catch {
                isPreparing = false
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}
