import SwiftUI
import AppKit
import FetchKit

/// The Settings screen, reached as the third sidebar destination (below
/// Downloads) rather than the standard ⌘,-opens-a-window Settings scene:
/// "Open Settings" from a banner used to raise a window over the thing the
/// banner was about, landing on whichever tab was last open. Six tabs, all
/// shipping: **Debrid** (service keys, M1), **Search**
/// (Torznab endpoints, §12.4), **Sources** (the keyless sources — Internet
/// Archive and Project Gutenberg, M7 §6), **Quality** (the profile Best match
/// ranks on), **Organization** (routing rules and naming templates, M4),
/// **Transfers** (concurrency and segments).
/// The spec's General tab has no settings of its own yet, so it is not here,
/// and M5's **Plugins** pane is hidden for now — see `SettingsTab`.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    /// The measure both the header and every pane are held to. Settings panes
    /// read as forms, and a form line that runs the full width of a widened
    /// window is unreadable — this is the same reason macOS's own Settings
    /// stops growing its content long before its window does.
    private static let paneWidth: CGFloat = 720

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // The header is a grouped `Form` too, and that is the whole
            // trick: matching its width to the panes' by hand meant guessing
            // the grouped style's internal inset, and guessing it wrong twice.
            // Two `Form`s of the same style inside the same width constraint
            // lay their cards out identically by construction, so the
            // segmented control and the settings below it cannot disagree
            // about where the content edge is.
            Form {
                Picker("Settings section", selection: $model.settingsTab) {
                    ForEach(SettingsTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .segmentedFillsEqually()
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            // Takes its natural height and refuses to give it up. A shrinking
            // window compresses the pane below instead — which can scroll —
            // rather than squeezing the control that switches panes off the
            // screen.
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)

            Divider()

            // Structurally below the header, so nothing scrolls under it.
            // macOS's default form style is column-aligned — right for a
            // modal sheet, wrong for a settings pane, and why six tabs looked
            // unlike the one hand-built as a `VStack`.
            pane
                .formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // One measure, applied once, inherited by both.
        .frame(maxWidth: Self.paneWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Settings")
        // No minimum height. One here would make a short window overflow
        // rather than scroll, and the first thing pushed out of view is the
        // header — which is exactly the "decreasing height hides the
        // segmented panel" this replaced. The panes scroll; letting them is
        // the whole answer.
    }

    @ViewBuilder
    private var pane: some View {
        switch model.settingsTab {
        case .debrid: DebridSettingsView()
        case .search: SearchSettingsView()
        case .sources: SourcesSettingsView()
        case .quality: QualitySettingsView()
        case .organization: OrganizationSettingsView()
        case .transfers: TransferSettingsView()
        }
    }
}

/// Settings § Debrid — the configured services, in preference order.
///
/// Was a single TorBox key field. Now a list, because a download can route to
/// whichever service already holds the torrent, and because the three services
/// are not equivalent: Real-Debrid cannot report cache status at all, which is
/// stated here rather than left to be discovered as a missing badge column.
struct DebridSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var addingKind: DebridKind?
    @State private var removeError: String?
    /// Shared across providers on purpose: the question is "who covers this
    /// host?", so typing it once and reading down the services answers it.
    @State private var hostQuery = ""

    var body: some View {
        Form {
            Section {
                if model.debridConfigs.isEmpty {
                    Text("No debrid provider configured. Fetch downloads through "
                         + "a debrid service, so add one to get started.")
                        .font(FetchFont.callout)
                        .foregroundStyle(Palette.textSecondary)
                } else {
                    ReorderableRows(
                        count: model.debridConfigs.count,
                        onMove: { model.moveDebrid(from: $0, to: $1) }
                    ) { index in
                        let config = model.debridConfigs[index]
                        if let kind = DebridKind.kind(for: config.id) {
                            // No live connection check runs against a saved
                            // provider, so `.untested` is what is actually
                            // known — the one-off "Test Connection" result in
                            // `DebridKeySheet` is not persisted anywhere this
                            // row could read it back from.
                            ProviderCardView(
                                title: kind.displayName,
                                detail: kind.canReportCacheStatus ? nil : "cannot report cached status",
                                status: .untested,
                                isEnabled: Binding(
                                    get: { config.isEnabled },
                                    set: { model.setDebridEnabled(config.id, isEnabled: $0) }),
                                trailing: {
                                    HStack(spacing: Spacing.s8) {
                                        // The star *is* the order: preference
                                        // was already the list's order and
                                        // nothing said so, so the one that
                                        // wins ties was invisible unless you
                                        // guessed that dragging meant
                                        // something. Starring moves it to the
                                        // top rather than storing a second
                                        // notion of "primary" that could
                                        // disagree with the order.
                                        Button {
                                            model.makePrimaryDebrid(config.id)
                                        } label: {
                                            Image(systemName: index == 0 ? "star.fill" : "star")
                                                .foregroundStyle(index == 0
                                                                 ? Palette.attention
                                                                 : Palette.textTertiary)
                                        }
                                        .buttonStyle(.borderless)
                                        .help(index == 0
                                              ? "Preferred — used unless another service already "
                                                + "has the torrent"
                                              : "Make \(kind.displayName) preferred")
                                        .accessibilityLabel(
                                            index == 0
                                            ? "\(kind.displayName), preferred"
                                            : "Make \(kind.displayName) preferred")

                                        Button("Key…") { addingKind = kind }
                                            .buttonStyle(.borderless)
                                        Button {
                                            do { try model.removeDebrid(config.id) }
                                            catch {
                                                removeError = (error as? AppModelError)?.errorDescription
                                                    ?? String(describing: error)
                                            }
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("Remove \(kind.displayName)")
                                    }
                                })
                            .opacity(config.isEnabled ? 1 : 0.5)
                        }
                    }
                }

                if model.debridConfigs.count > 1 {
                    // Order is load-bearing, so say what it does — and the
                    // star now says which one wins, which the order alone
                    // never did.
                    Text("Downloads use whichever provider already has the "
                         + "torrent cached; otherwise the starred one. Star a "
                         + "provider or drag to reorder.")
                        .font(FetchFont.footnote)
                        .foregroundStyle(Palette.textSecondary)
                }

                if let removeError {
                    Text(removeError)
                        .font(FetchFont.callout)
                        .foregroundStyle(Palette.miss)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Somewhere to send someone who is asked for their log.
                // Redacted on the way in (`LogRedaction`), so it can be
                // attached to a bug report without attaching the user's
                // library along with it.
                HStack(spacing: Spacing.s8) {
                    Button("Reveal Log in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [FetchLog.shared.fileURL])
                    }
                    .buttonStyle(.borderless)
                    Button("Copy Log") {
                        Task {
                            let contents = await FetchLog.shared.contents()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(contents, forType: .string)
                        }
                    }
                    .buttonStyle(.borderless)
                    Text("Filenames, paths and links are replaced before they are written.")
                        .font(FetchFont.footnote)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                }

                HStack {
                    Spacer()
                    Menu("Add Provider…") {
                        ForEach(unconfiguredKinds) { kind in
                            Button(kind.displayName) { addingKind = kind }
                        }
                    }
                    .fixedSize()
                    .disabled(unconfiguredKinds.isEmpty)
                }
            } header: {
                Text("Debrid Providers").font(FetchFont.headline)
            }

            hostCoverageSection
        }
        .formStyle(.grouped)
        .sheet(item: $addingKind) { DebridKeySheet(kind: $0) }
        .task { await model.refreshHostCoverage() }
    }

    private func hostRow(_ host: DebridHost) -> some View {
        HStack(spacing: Spacing.s6) {
            Image(systemName: host.isActive ? "checkmark.circle.fill" : "slash.circle")
                .foregroundStyle(host.isActive ? Palette.cached : Palette.attention)
            Text(host.displayName)
                .font(FetchFont.callout)
            if !host.isActive {
                Text("reported down")
                    .font(FetchFont.footnote)
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(host.isActive
            ? host.displayName
            : "\(host.displayName), reported down")
    }

    /// Which file hosts each debrid can unrestrict (7e §5.3).
    ///
    /// Coverage differs per service — a Rapidgator link may work through one
    /// configured debrid and not another — and without this, "no configured
    /// debrid handles rapidgator.net" is unfalsifiable from inside the app.
    @ViewBuilder
    private var hostCoverageSection: some View {
        if !model.providers.isEmpty {
            Section {
                ForEach(model.providers, id: \.id) { provider in
                    let hosts = model.hostCoverage[provider.id]
                    DisclosureGroup {
                        if let hosts, !hosts.isEmpty {
                            // Searched, and bounded. A debrid reports several
                            // hundred hosts; rendering them all as sibling
                            // rows made this pane taller than the window.
                            // Nobody reads the catalogue — they arrive holding
                            // a link and want to know whether it is covered.
                            TextField("Search hosts…", text: $hostQuery)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Search \(provider.displayName)'s hosts")

                            let matches = HostSearch.filter(hosts, matching: hostQuery)
                            if matches.isEmpty {
                                Text("No host matches “\(hostQuery)”.")
                                    .font(FetchFont.footnote)
                                    .foregroundStyle(Palette.textSecondary)
                            } else {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: Spacing.s2) {
                                        ForEach(matches, id: \.id) { host in
                                            hostRow(host)
                                        }
                                    }
                                }
                                // Caps the pane's growth at roughly eight rows
                                // whatever the catalogue's size — the fixed
                                // ceiling is the point, not the exact value.
                                .frame(maxHeight: 180)

                                if matches.count < hosts.count {
                                    Text("\(matches.count) of \(hosts.count)")
                                        .font(FetchFont.footnote)
                                        .foregroundStyle(Palette.textTertiary)
                                }
                            }
                        } else if hosts != nil {
                            // Answered, and the answer was none — which is
                            // what a debrid without web downloads reports.
                            Text("This service does not offer web downloads.")
                                .font(FetchFont.footnote)
                                .foregroundStyle(Palette.textSecondary)
                        } else {
                            Text("Not loaded yet.")
                                .font(FetchFont.footnote)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    } label: {
                        HStack {
                            Text(provider.displayName).font(FetchFont.body)
                            Spacer()
                            Text(hosts.map { "\($0.count) hosts" } ?? "—")
                                .font(FetchFont.footnote)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                }

                Button("Refresh") {
                    Task { await model.refreshHostCoverage(force: true) }
                }
                .buttonStyle(.borderless)

                Text("Paste a link from one of these hosts into Add Link, and "
                     + "Fetch routes it to whichever service covers it. Lists "
                     + "are cached for six hours.")
                    .font(FetchFont.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("File Hosts").font(FetchFont.headline)
            }
        }
    }

    private var unconfiguredKinds: [DebridKind] {
        DebridKind.all.filter { kind in
            !model.debridConfigs.contains { $0.id == kind.id }
        }
    }

}


/// Key entry for one provider, with a button straight to that service's token
/// page — the key is otherwise buried several clicks into each site.
private struct DebridKeySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let kind: DebridKind

    @State private var apiKeyInput = ""
    @State private var testState: TestState = .idle
    @State private var saveError: String?

    private enum TestState: Equatable {
        case idle, testing
        case success(plan: String, expiresAt: Date?)
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s12) {
            Text(kind.displayName).font(FetchFont.title3)

            SecureField(
                model.hasStoredKey(for: kind.id)
                    ? "API Key (leave blank to keep current)" : "API Key",
                text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)

            Button {
                openURL(kind.apiKeyPageURL)
            } label: {
                Label("Get my API key", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .font(FetchFont.callout)
            .help(kind.apiKeyPageURL.absoluteString)

            statusLine

            if let saveError {
                Text(saveError).font(FetchFont.callout).foregroundStyle(Palette.miss)
            }

            HStack(spacing: Spacing.s8) {
                Button("Test Connection") { testConnection() }
                    .disabled(trimmedKey.isEmpty || testState == .testing)
                if testState == .testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedKey.isEmpty || model.hasActiveDownloads)
            }
        }
        .padding(Spacing.s20)
        .frame(width: 420)
    }

    private var trimmedKey: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch testState {
        case .idle:
            if !kind.canReportCacheStatus {
                Text("\(kind.displayName) does not report which torrents it has "
                     + "cached, so results will not show a cache badge from it. "
                     + "Downloads work normally.")
                    .font(FetchFont.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .testing:
            Text("Testing…").font(FetchFont.callout).foregroundStyle(Palette.textSecondary)
        case .success(let plan, let expiresAt):
            Text(expiresAt.map {
                "Connected — \(plan), expires \($0.formatted(date: .abbreviated, time: .omitted))."
            } ?? "Connected — \(plan).")
                .font(FetchFont.callout)
                .foregroundStyle(Palette.cached)
        case .failure(let message):
            Text(message).font(FetchFont.callout).foregroundStyle(Palette.miss)
        }
    }

    /// A throwaway provider scoped to this call — validating a key the user is
    /// still typing must not touch the credential store or the app's engine
    /// until they explicitly hit Save.
    private func testConnection() {
        let key = trimmedKey
        guard !key.isEmpty else { return }
        testState = .testing
        Task {
            let provider = kind.makeProvider(Redacted(key), HTTPClient())
            do {
                let account = try await provider.validateCredentials()
                testState = .success(plan: account.plan ?? "unknown", expiresAt: account.expiresAt)
            } catch {
                testState = .failure(String(describing: error))
            }
        }
    }

    private func save() {
        do {
            try model.saveDebridKey(trimmedKey, for: kind.id)
            // Never let a secret linger in view state longer than necessary.
            apiKeyInput = ""
            dismiss()
        } catch {
            saveError = (error as? AppModelError)?.errorDescription ?? String(describing: error)
        }
    }
}


/// Settings § Transfers (§12.4).
///
/// Two dials that are easy to confuse, so the copy distinguishes them: one
/// controls how many *files* move at once, the other how many connections
/// carry a *single* file. For one movie only the second does anything.
struct TransferSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                VStack(alignment: .leading, spacing: Spacing.s4) {
                    Stepper(
                        "Connections per file: \(model.segmentsPerFile)",
                        value: $model.segmentsPerFile,
                        in: 1...SegmentedTransfer.maxSegmentsAllowed)
                    Text("A file is fetched over this many parallel byte ranges. "
                         + "It exists to saturate a link that one connection "
                         + "cannot fill on its own.")
                        .font(FetchFont.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // None of the three providers documents a limit, so saying
                    // "safe" would be inventing a fact.
                    // Reports what was measured rather than what accelerators
                    // happen to use — 8 was the original default on exactly
                    // that reasoning, and the numbers did not support it.
                    Text("Measured on this connection against TorBox and "
                         + "Archive.org: 1 was fastest both times, at 9.2 MB/s. "
                         + "Splitting was up to 37% slower — 3 connections to "
                         + "Archive.org managed only 5.8 MB/s. That is because "
                         + "one stream already fills this ~90 Mbps line; on a "
                         + "faster connection, raising this should win. Change "
                         + "it and watch the speed rather than trusting the "
                         + "default.")
                        .font(FetchFont.footnote)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, Spacing.s4)
            } header: {
                Text("Speed").font(FetchFont.headline)
            }

            Section {
                VStack(alignment: .leading, spacing: Spacing.s4) {
                    Stepper(
                        "Files at once: \(model.maxConcurrentDownloads)",
                        value: $model.maxConcurrentDownloads, in: 1...10)
                    Text("How many files from a torrent transfer simultaneously. "
                         + "Only affects multi-file torrents; the rest queue behind "
                         + "these and are shown as waiting, not stalled.")
                        .font(FetchFont.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, Spacing.s4)
            } header: {
                Text("Concurrency").font(FetchFont.headline)
            }

            Section {
                VStack(alignment: .leading, spacing: Spacing.s6) {
                    Picker("When the window closes", selection: $model.windowCloseBehaviour) {
                        ForEach(WindowCloseBehaviour.allCases, id: \.self) { behaviour in
                            Text(behaviour.title).tag(behaviour)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    Text(model.windowCloseBehaviour.detail)
                        .font(FetchFont.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // The one thing the dialog cannot say for itself, because
                    // by the time it appears the answer is already stored.
                    Text("Fetch stays in the menu bar while it is downloading, "
                         + "whichever of these you choose.")
                        .font(FetchFont.footnote)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, Spacing.s4)
            } header: {
                Text("Closing").font(FetchFont.headline)
            }
        }
        .formStyle(.grouped)
    }
}
