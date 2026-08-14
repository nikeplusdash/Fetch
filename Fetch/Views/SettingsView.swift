import SwiftUI
import AppKit
import FetchKit

/// The Settings screen, reached as the third sidebar destination rather than
/// the standard ⌘,-opens-a-window Settings scene: "Open Settings" from a banner
/// used to raise a window over the thing the banner was about, landing on
/// whichever tab was last open.
///
/// **The panes are pills and the settings are rows.** It was a `Form` holding a
/// segmented picker, above panes that were `Form`s of cards — two container
/// styles agreeing about nothing, and a header whose width had to be guessed
/// twice before it matched the content under it. The pane row is now the same
/// `FilterPillBar` the Downloads filters use, and every setting in every pane is
/// one `SettingRow`: a label, one line of help beneath it, and the control
/// trailing. No cards, no boxed groups, no column-aligned form.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    // **No measure, and the rows span the column.** Every pane used to be
    // centred in 720 points, on the reasoning that a form line running the full
    // width of a widened window is unreadable. That is true of a *line of
    // prose* and false of these rows, which are a label at one edge and a
    // control at the other: centring them left the pills floating in the middle
    // of the window with a margin nothing else on any screen had, and put the
    // controls a long way from the right edge every other screen ends at. The
    // help text under each label keeps its own measure, which is where the
    // readable-line argument actually applies.

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // On the column's left edge, like every other bar in the app.
            FilterPillBar(
                items: SettingsTab.allCases,
                title: \.title,
                isSelected: { $0 == model.settingsTab },
                select: { model.settingsTab = $0 },
                height: WindowMetrics.barHeight,
                // The height of Search's field and Downloads' pills — this row
                // is what Settings has in that slot.
                pillHeight: RowHeight.searchField,
                // **Eight panes do not fit.** The row has always scrolled; at
                // this height it overflows on any window worth using, so the
                // trailing edge needs to say so rather than ending mid-word.
                fadesOverflow: true)
                // The same pair Downloads uses, from one place — see
                // `pillBarLift`. Typed separately, they drifted 2pt apart.
                .padding(.top, -WindowMetrics.pillBarLift)
                .padding(.bottom, WindowMetrics.pillBarGap)
            // Full width, because a rule that stops short of the window edge
            // reads as a box the pills are in rather than as the line that
            // closes the bar.
            ThemedDivider()

            ScrollView {
                pane
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, Spacing.s24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            RailBar(
                leading: ServiceRail.text(
                    configured: model.providers.count,
                    answering: model.answeringServiceCount,
                    hasAsked: model.hasAskedServices),
                trailing: model.configuredServicesText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Settings")
        // Asked here rather than inside the Debrid pane, because the rail is on
        // every pane and a number that only becomes true after you visit one
        // tab is a number that reads as wrong on the other six.
        .task {
            // Health first: it is what the dots and the rail read, and it is
            // the faster of the two.
            await model.refreshServiceHealth()
            await model.refreshHostCoverage()
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch model.settingsTab {
        case .appearance: AppearanceSettingsView()
        case .debrid: DebridSettingsView()
        case .search: SearchSettingsView()
        case .sources: SourcesSettingsView()
        case .quality: QualitySettingsView()
        case .organization: OrganizationSettingsView()
        case .transfers: TransferSettingsView()
        case .health: HealthSettingsView()
        }
    }
}

/// Settings § Debrid — the configured services, in preference order.
///
/// **A provider is a row, not a card.** `ProviderCardView` boxed three of them
/// and said they were a different kind of thing from every other setting; they
/// are not. The status dot carries what the box was there to carry, and the
/// order of the rows is the preference order, which is what the star was
/// explaining and never managed to.
struct DebridSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var addingKind: DebridKind?
    @State private var removeError: String?
    @State private var showingCoverage = false

    var body: some View {
        VStack(spacing: 0) {
            SettingsGroup(title: "Services") {
                if model.debridConfigs.isEmpty {
                    SettingRow(
                        label: "No service yet",
                        help: "Fetch downloads through a debrid service, so it "
                            + "needs one before anything can start."
                    ) { addMenu }
                } else {
                    // Drag still reorders, and the order still *is* the
                    // preference — that has not changed, only the star that
                    // used to be the only hint of it.
                    ReorderableRows(
                        model.debridConfigs,
                        onMove: { model.moveDebrid(from: $0, to: $1) }
                    ) { index, config in
                        providerRow(config, isPreferred: index == 0)
                    }
                    SettingRow(
                        label: "Order",
                        help: "A download goes to whichever service already has "
                            + "it. Ties go to the top of this list."
                    ) { addMenu }
                }

                if let removeError {
                    SettingRow(label: "That did not work", help: removeError) {
                        Button("OK") { self.removeError = nil }
                    }
                }
            }

            if !model.providers.isEmpty {
                SettingsGroup(title: "File hosts") {
                    SettingRow(
                        label: "Coverage",
                        help: "Which hosts each service can unrestrict. "
                            + "Refreshed every six hours."
                    ) {
                        Button {
                            showingCoverage = true
                        } label: {
                            HStack(spacing: Spacing.s6) {
                                Text(coverageSummary)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: IconSize.xs, weight: .semibold))
                                    .foregroundStyle(Palette.textTertiary)
                            }
                        }
                    }
                }
            }

        }
        .sheet(item: $addingKind) { DebridKeySheet(kind: $0) }
        .sheet(isPresented: $showingCoverage) { HostCoverageSheet() }
    }

    /// One service. The dot says whether it answered, the help says what its
    /// position in this list means, and the trailing menu is the key.
    @ViewBuilder
    private func providerRow(_ config: DebridConfig, isPreferred: Bool) -> some View {
        // The config is handed in rather than looked up. Looking it up by index
        // is what crashed the app when the last provider was removed.
        if let kind = DebridKind.kind(for: config.id) {
            SettingRow(
                label: kind.displayName,
                help: DebridRowCopy.help(
                    isPreferred: isPreferred,
                    reportsCacheStatus: kind.canReportCacheStatus,
                    isEnabled: config.isEnabled),
                leadingAccessory: AnyView(StatusDot(state: dotState(config)))
            ) {
                HStack(spacing: Spacing.s8) {
                    Toggle("", isOn: Binding(
                        get: { config.isEnabled },
                        set: { model.setDebridEnabled(config.id, isEnabled: $0) }))
                        .labelsHidden()
                        .help("Use \(kind.displayName) for downloads")
                    Menu {
                        Button(model.hasStoredKey(for: kind.id) ? "Change Key…" : "Add Key…") {
                            addingKind = kind
                        }
                        Button("Remove \(kind.displayName)", role: .destructive) {
                            do { try model.removeDebrid(config.id) }
                            catch {
                                removeError = (error as? AppModelError)?.errorDescription
                                    ?? String(describing: error)
                            }
                        }
                    } label: {
                        // The key itself is never read back — nothing can show
                        // its last four digits, because nothing keeps it in a
                        // form this view could ask for.
                        Text(model.hasStoredKey(for: kind.id) ? "••••••••" : "No key")
                            .font(FetchFont.calloutMono)
                    }
                    .fixedSize()
                    .accessibilityLabel("\(kind.displayName) key")
                }
            }
            .opacity(config.isEnabled ? 1 : 0.6)
        }
    }

    /// **Answering, not configured.** Nothing runs a health check against a
    /// saved provider, so "up" would be a claim with no evidence behind it. A
    /// successful host-coverage call is real evidence, and it is the one call
    /// this screen already makes.
    private func dotState(_ config: DebridConfig) -> StatusDot.State {
        switch model.healthDot(for: config) {
        case .up: .up
        case .down: .down
        // Not asked yet is not a failure, and drawing it as one makes every
        // launch look broken for as long as the network takes.
        case .waiting: .waiting
        case .off: .off
        }
    }

    private var coverageSummary: String {
        let total = model.hostCoverage.values.reduce(0) { $0 + $1.count }
        guard total > 0 else { return "Not loaded yet" }
        return total == 1 ? "1 host" : "\(total.formatted()) hosts"
    }

    private var addMenu: some View {
        Menu("Add…") {
            ForEach(unconfiguredKinds) { kind in
                Button(kind.displayName) { addingKind = kind }
            }
        }
        .fixedSize()
        .disabled(unconfiguredKinds.isEmpty)
        .help("TorBox, Real-Debrid or Premiumize")
    }

    private var unconfiguredKinds: [DebridKind] {
        DebridKind.all.filter { kind in
            !model.debridConfigs.contains { $0.id == kind.id }
        }
    }
}

/// Which file hosts each debrid can unrestrict (7e §5.3).
///
/// A sheet rather than a run of rows in the pane: a debrid reports several
/// hundred hosts, and rendering them as siblings made this pane taller than the
/// window. Nobody reads the catalogue — they arrive holding a link and want to
/// know whether it is covered, which is a search box, not a list.
private struct HostCoverageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Shared across providers on purpose: the question is "who covers this
    /// host?", so typing it once and reading down the services answers it.
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s12) {
            Text("File hosts").font(FetchFont.sheetTitle)

            TextField("Search hosts", text: $query)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.s16) {
                    ForEach(model.providers, id: \.id) { provider in
                        section(for: provider)
                    }
                }
            }
            .frame(height: 320)

            HStack {
                Button("Refresh") {
                    Task { await model.refreshHostCoverage(force: true) }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(WindowMetrics.sheetInset)
        .frame(width: 460)
    }

    @ViewBuilder
    private func section(for provider: any DebridProvider) -> some View {
        let hosts = model.hostCoverage[provider.id]
        VStack(alignment: .leading, spacing: Spacing.s4) {
            Text(provider.displayName).sectionLabel()

            if let hosts, !hosts.isEmpty {
                let matches = HostSearch.filter(hosts, matching: query)
                if matches.isEmpty {
                    Text("No host here matches that.")
                        .font(FetchFont.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                } else {
                    ForEach(matches, id: \.id) { host in
                        HStack(spacing: Spacing.s6) {
                            StatusDot(state: host.isActive ? .up : .down)
                            Text(host.displayName).font(FetchFont.callout)
                            if !host.isActive {
                                Text("reported down")
                                    .font(FetchFont.subheadline)
                                    .foregroundStyle(Palette.textTertiary)
                            }
                            Spacer()
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if matches.count < hosts.count {
                        Text("\(matches.count) of \(hosts.count)")
                            .font(FetchFont.subheadline)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
            } else if hosts != nil {
                // Answered, and the answer was none, which is what a debrid
                // without web downloads reports.
                Text("This service does not offer web downloads.")
                    .font(FetchFont.subheadline)
                    .foregroundStyle(Palette.textSecondary)
            } else {
                Text("Not loaded yet.")
                    .font(FetchFont.subheadline)
                    .foregroundStyle(Palette.textSecondary)
            }
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
            Text(kind.displayName).font(FetchFont.sheetTitle)

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
                Text("\(kind.displayName) cannot report which torrents it has "
                     + "cached, so results will carry no badge from it. "
                     + "Downloads work normally.")
                    .font(FetchFont.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .testing:
            Text("Testing…").font(FetchFont.callout).foregroundStyle(Palette.textSecondary)
        case .success(let plan, let expiresAt):
            Text(expiresAt.map {
                "Connected. \(plan), expires \($0.formatted(date: .abbreviated, time: .omitted))."
            } ?? "Connected. \(plan).")
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

/// Settings § Transfers.
///
/// Two dials that are easy to confuse, so the copy distinguishes them: one
/// controls how many *files* move at once, the other how many connections carry
/// a *single* file. For one movie only the second does anything.
///
/// **This is where the verbosity was worst.** Ninety-one words of benchmark sat
/// under the first stepper. The measurement is real and worth keeping, so it is
/// behind a disclosure whose summary is its finding: someone tuning this opens
/// it, and everyone else reads six words and moves on.
struct TransferSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            SettingsGroup(title: "Speed") {
                SettingRow(
                    label: "Connections per file",
                    help: "Splits one file across parallel byte ranges.",
                    detail: (
                        summary: "Measured here: 1 was fastest",
                        body: "Against TorBox and Archive.org, one connection "
                            + "reached 9.2 MB/s both times. Splitting was up to "
                            + "37% slower: three connections to Archive.org "
                            + "managed 5.8 MB/s. One stream already fills this "
                            + "90 Mbps line, so on a faster connection raising "
                            + "this should win. Change it and watch the speed "
                            + "rather than trusting the default.")
                ) {
                    Stepper(
                        "\(model.segmentsPerFile)",
                        value: $model.segmentsPerFile,
                        in: 1...SegmentedTransfer.maxSegmentsAllowed)
                        .fixedSize()
                }

                SettingRow(
                    label: "Files at once",
                    help: "How many files from one torrent transfer together. "
                        + "The rest wait."
                ) {
                    Stepper(
                        "\(model.maxConcurrentDownloads)",
                        value: $model.maxConcurrentDownloads, in: 1...10)
                        .fixedSize()
                }
            }

            SettingsGroup(title: "Closing the window") {
                // **A binary wearing a picker.** Three of the four cases keep
                // the app running and differ only in what happens to the
                // window, which the yellow button already decides. See
                // `WindowCloseBehaviour.keepsDownloading`.
                SettingRow(
                    label: "Keep downloading",
                    help: "Fetch stays in the menu bar. Quit from there to stop."
                ) {
                    Toggle("", isOn: Binding(
                        get: { model.windowCloseBehaviour.keepsDownloading },
                        set: {
                            model.windowCloseBehaviour =
                                WindowCloseBehaviour(keepsDownloading: $0)
                        }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel("Keep downloading when the window closes")
                }
            }
        }
    }
}
