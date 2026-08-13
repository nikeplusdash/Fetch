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
        VStack(alignment: .leading, spacing: Spacing.s16) {
            Text("Add Link")
                .font(FetchFont.title3)

            HStack(spacing: Spacing.s8) {
                TextField("magnet:?xt=urn:btih:… or https://…", text: $linkText)
                .textFieldStyle(.roundedBorder)
                    .disabled(isPreparing)
                    .onSubmit(confirm)

                Button("Choose .torrent…") { chooseTorrentFile() }
                    .disabled(isPreparing)
            }

            statusLine
            availabilityLine
            providerPicker

            if isPreparing {
                HStack(spacing: Spacing.s8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing…")
                        .font(FetchFont.callout)
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(FetchFont.callout)
                    .foregroundStyle(Palette.miss)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    addTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(addButtonTitle) { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(Spacing.s20)
        .frame(width: 420)
        .onDisappear { addTask?.cancel() }
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

    @ViewBuilder
    private var statusLine: some View {
        switch resolved {
        case .empty:
            EmptyView()

        case .magnet(let magnet):
            status(magnet.displayName ?? "Magnet link", tint: Palette.textSecondary)

        case .hosted(_, let host, let provider):
            status(
                "\(host.displayName) · via \(providerName(provider))",
                tint: Palette.cached)

        case .hostDown(_, let host):
            status(
                "\(host.displayName) — reported down. It may work again later.",
                tint: Palette.attention)

        case .unsupportedHost(_, let hostName):
            status("No configured debrid handles \(hostName).", tint: Palette.miss)

        case .checkingCoverage:
            status("Checking which debrid handles this…", tint: Palette.textSecondary)

        case .noDebridConfigured:
            status("No debrid configured. Add one in Settings.", tint: Palette.miss)

        case .invalid:
            status("Not a magnet link or a web address.", tint: Palette.miss)
        }
    }

    /// What adding this will actually do. Without it the instant case and the
    /// twenty-minute case look identical until one of them isn't.
    @ViewBuilder
    private var availabilityLine: some View {
        if case .magnet = resolved {
            switch currentAvailability {
            case .none:
                status("Checking availability…", tint: Palette.textSecondary)
            case .cached(let id):
                status("Cached on \(providerName(id)) · downloads immediately",
                       tint: Palette.cached)
            case .notCached(let id):
                status("Not cached. \(providerName(id)) would fetch it first — "
                       + "this can take a while.", tint: Palette.attention)
            case .unknowable(let id):
                // Not "not cached": nothing asserted that.
                status("\(providerName(id)) cannot report availability.",
                       tint: Palette.textSecondary)
            case .noProviders:
                EmptyView()   // the status line already says there is no debrid
            }
        }
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

    /// The same per-download choice the picker sheet offers, for a magnet
    /// pasted or dropped rather than searched for. Only when there is a choice
    /// to make: one configured service is not a decision.
    @ViewBuilder
    private var providerPicker: some View {
        if model.providers.count > 1 {
            Picker(selection: Binding(
                get: { model.pinnedProvider },
                set: { model.pinProvider($0) }
            )) {
                Text("Auto").tag(DebridProviderID?.none)
                ForEach(model.providers, id: \.id) { provider in
                    Text(provider.displayName).tag(DebridProviderID?.some(provider.id))
                }
            } label: {
                Text("Download via")
            }
            .pickerStyle(.menu)
            .font(FetchFont.callout)
        }
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
                    try await model.prepareInBackground(
                        magnet.raw, displayName: magnet.displayName)
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
