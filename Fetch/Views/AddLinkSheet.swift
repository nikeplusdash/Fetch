import SwiftUI
import UniformTypeIdentifiers
import FetchKit

/// Sheet presented from the Downloads toolbar's Add button (and ⌘N).
///
/// Takes a magnet **or** a hoster link (7e §5.1). `PastedLink` validates the
/// field live so the confirm button can only fire on something actionable;
/// confirming then awaits the debrid, which does not return until the torrent
/// or the link is ready (§ `DownloadEngine`'s poll backoff) — the indefinite
/// wait is why this shows an indeterminate "Preparing…" state rather than a
/// determinate progress bar.
///
/// The status line carries four distinct refusals rather than one "invalid
/// link", because whether the problem is the link, the host or the account
/// changes what the user should do about it.
struct AddLinkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var linkText: String
    @State private var isPreparing = false
    /// Availability for the magnet currently in the field, or nil while it is
    /// being resolved. Keyed on the text it was resolved for, so a stale
    /// answer never describes a link the user has since replaced.
    @State private var availability: (text: String, answer: LinkAvailability)?
    @State private var isConfirmingUncached = false
    @State private var errorMessage: String?
    @State private var addTask: Task<Void, Never>?

    /// `initialText` lets the search bar's paste detection (§12.1: "pasting a
    /// string starting with magnet: skips search entirely and opens the
    /// add-flow directly", now extended to http(s)) hand off the already-typed
    /// text instead of making the user paste it a second time.
    init(initialText: String = "") {
        _linkText = State(initialValue: initialText)
    }

    /// Whitespace is trimmed inside `resolve`, so a link pasted with
    /// surrounding newlines — common when copied from chat apps — still
    /// parses.
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

                // What is *wrong* with the link stays here, because it is about
                // the text in the field beside it. What is true about a link
                // that parsed is in the header block with its name, which is
                // the rule the other three sheets follow.
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
            // An override belongs to one download. Keyed on the infohash of
            // whatever is in the field now, which is the only one this sheet
            // can have set.
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
        // Coverage decides what this sheet can say, and the cache makes the
        // repeat cost nothing. Asking on appear rather than at launch keeps a
        // user who never pastes a hoster link from paying for it at all.
        .task { await model.refreshHostCoverage() }
    }

    /// The same block the other three sheets use, so the four stop being four
    /// designs.
    ///
    /// The name is the link's own — a magnet's `dn`, a hoster's host — and the
    /// pill is the availability answer this sheet was already computing and
    /// rendering as a sentence in a coloured line.
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
                // Only the magnet path carries one: `addHostedLink` prepares
                // its request with `subfolder: nil`, so a hosted link lands at
                // the root whatever a menu here claimed. A control that does
                // not do what it says is worse than no control.
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

    /// **Ready** or **Queued**, from the availability answer, once it lands.
    ///
    /// It replaces two coloured sentences — "Cached on TorBox · downloads
    /// immediately" and "Not cached. TorBox would fetch it first" — which is
    /// one bit of information wearing about nine words. The words survive as
    /// the tooltip.
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
                // Not "not cached": nothing asserted that. Real-Debrid's
                // availability endpoint is disabled, so an RD-only user would
                // otherwise be told "Queued" about every torrent they add.
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

    /// What is wrong with the text in the field. Only refusals: everything a
    /// parsed link is true about lives in the header block.
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

    /// A magnet pasted here is routed by the same rules a searched one is, so
    /// its `dn` is parsed rather than left `.unparsed`.
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

    /// The answer, only if it was resolved for the text now in the field.
    private var currentAvailability: LinkAvailability? {
        guard let availability, availability.text == linkText.trimmingCharacters(
            in: .whitespacesAndNewlines) else { return nil }
        return availability.answer
    }

    private func resolveAvailability() async {
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .magnet(let magnet) = model.resolvePastedLink(text) else { return }
        let answer = await model.availability(forMagnet: magnet.raw)
        // Only apply if the field has not moved on while we were asking.
        if linkText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
            availability = (text, answer)
        }
    }

    /// Opens a `.torrent` and puts its magnet in the field, so the one
    /// availability-and-confirm path handles it — rather than a second flow
    /// that could drift out of step with the first.
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

    /// The debrid's own name, so "via Real-Debrid" reads as the service the
    /// user configured rather than as an internal identifier.
    private func providerName(_ id: DebridProviderID?) -> String {
        guard let id else { return "your debrid" }
        return model.providers.first { $0.id == id }?.displayName ?? id.rawValue
    }

    /// Add is refused until the answer is in.
    ///
    /// **This is a safety rule, not a nicety.** `needsConfirmation` is read
    /// off an optional; while availability is still resolving it is nil, so a
    /// click in that window would have sailed past the confirmation and
    /// queued an uncached torrent — spending an account slot on an
    /// open-ended fetch the user never agreed to. `⌘↩` makes that window very
    /// easy to hit.
    private var canAdd: Bool {
        guard resolved.isActionable, !isPreparing else { return false }
        // Only magnets have an availability question; a hoster link does not.
        if case .magnet = resolved { return currentAvailability != nil }
        return true
    }

    /// Queueing an uncached torrent spends an account slot and quota on an
    /// open-ended wait, so it is confirmed rather than done. The cached case
    /// stays one click.
    private var addButtonTitle: String {
        currentAvailability?.needsConfirmation == true ? "Queue…" : "Add"
    }

    /// Cancel, then the split button. The same footer the other three sheets
    /// have.
    private var footer: some View {
        HStack(spacing: Spacing.s12) {
            Spacer()
            Button("Cancel") {
                addTask?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            // One button for both kinds. They were two only because a magnet's
            // carried the destination chevron and a hosted link's could not —
            // a hosted link lands where its debrid puts it. With the chevron
            // gone the branches were the same control written twice, and the
            // hosted one was missing the spinner `confirm()` sets for both.
            PrimaryActionButton(
                title: addButtonTitle,
                isBusy: isPreparing,
                isEnabled: canAdd,
                action: confirm)
        }
        .padding(.horizontal, WindowMetrics.sheetInset)
        .padding(.vertical, Spacing.s12)
    }

    /// Which debrid serves this, as a fact on the facts line rather than a
    /// labelled row. "Auto" is not a provider: it is the absence of a pin,
    /// which lets the routing prefer whichever service already holds it.
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
        // Re-checked here as well as on the button: `.onSubmit` fires on
        // Return regardless of whether the button is disabled.
        guard canAdd else { return }
        if currentAvailability?.needsConfirmation == true, !isConfirmingUncached {
            isConfirmingUncached = true
            return
        }
        proceed()
    }

    private func proceed() {
        let resolution = resolved
        errorMessage = nil
        isPreparing = true
        addTask = Task {
            do {
                switch resolution {
                case .magnet(let magnet):
                    // Background, not `addMagnet`: that submits and then polls
                    // until the debrid holds the whole torrent, so pasting an
                    // uncached magnet held this sheet open for as long as the
                    // fetch took. A cached one resolves on the first poll and
                    // its row becomes files immediately, so one path serves
                    // both.
                    //
                    // The rules' folder, or the override the header's menu
                    // set. This used to pass no subfolder at all, so a magnet
                    // pasted here landed at the root while the identical one
                    // opened from a search result was routed by the rules.
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
                    // The button is disabled for everything else; reaching
                    // here would be a bug in `isActionable`, not user input.
                    isPreparing = false
                    return
                }
                isPreparing = false
                dismiss()
            } catch is CancellationError {
                // Sheet was dismissed while preparing — nothing to report.
            } catch {
                isPreparing = false
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}
