import AppKit
import SwiftUI
import FetchKit

/// Settings § Health — what the parts of this app have actually been doing,
/// and what to do about the ones misbehaving.
///
/// **Every number here is measured by using the app, not by probing.** Each
/// search already records how long every indexer took and whether it answered;
/// every cache badge already asks each debrid whether it holds a hash. All of
/// it was thrown away one row at a time. This adds it up.
///
/// **It is a pane you can act from.** A health screen that reports a failing
/// indexer and makes you go and find it somewhere else is a screen that gets
/// read once. Every row carries the switch for the thing it is describing.
struct HealthSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var didCopyLog = false
    @State private var showingResetConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            SettingsGroup(title: "Summary") {
                SettingRow(
                    label: HealthReport.headline(model.indexerHealthRows),
                    help: "Fastest, slowest and average response, per indexer.",
                    leadingAccessory: AnyView(StatusDot(state: summaryDot))
                ) {
                    Button("Reset") { showingResetConfirmation = true }
                        .disabled(!hasMeasurements)
                        .help("Forget every measurement and start again")
                }
            }

            SettingsGroup(title: "Indexers") {
                if model.indexerHealthRows.isEmpty {
                    SettingRow(
                        label: "No indexers",
                        help: "Add a Torznab server in Settings → Search."
                    ) {
                        Button("Open Search") { model.settingsTab = .search }
                    }
                } else {
                    ForEach(model.indexerHealthRows) { row in
                        indexerRow(row)
                    }
                }
            }

            SettingsGroup(title: "Debrid services") {
                if model.debridHealthRows.isEmpty {
                    SettingRow(
                        label: "No services",
                        help: "Add one in Settings → Debrid."
                    ) {
                        Button("Open Debrid") { model.settingsTab = .debrid }
                    }
                } else {
                    ForEach(model.debridHealthRows) { row in
                        debridRow(row)
                    }
                }
            }

            // **Moved here from Debrid.** The log is not a debrid setting; it
            // is what you reach for when something has gone wrong, which is
            // the question this whole pane answers.
            SettingsGroup(title: "Diagnostics") {
                SettingRow(
                    label: "Log",
                    help: didCopyLog
                        ? "Copied. Filenames, paths and links were replaced before "
                            + "they were written."
                        : "Filenames, paths and links are replaced before they "
                            + "are written."
                ) {
                    HStack(spacing: Spacing.s8) {
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [FetchLog.shared.fileURL])
                        }
                        Button("Copy") {
                            Task {
                                let contents = await FetchLog.shared.contents()
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(contents, forType: .string)
                                didCopyLog = true
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Forget every measurement?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { model.resetHealthStatistics() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Speeds, failure rates and cache hits all go back to zero. "
                + "Nothing is switched off and no key is touched.")
        }
    }

    // MARK: - Indexers

    private func indexerRow(_ row: HealthReport.IndexerRow) -> some View {
        SettingRow(
            label: row.name,
            help: indexerHelp(row),
            leadingAccessory: AnyView(StatusDot(state: dot(for: row.verdict, isEnabled: row.isEnabled)))
        ) {
            HStack(spacing: Spacing.s8) {
                measurement(row)
                // The switch for the thing the row is describing, right next to
                // the sentence advising you to use it.
                Toggle("", isOn: Binding(
                    get: { row.isEnabled },
                    set: {
                        model.setIndexerEnabled(
                            server: row.serverID, indexer: row.id, isEnabled: $0)
                    }))
                    .labelsHidden()
                    .help("Ask \(row.name) when searching")
            }
        }
        .opacity(row.isEnabled ? 1 : 0.6)
    }

    /// Fastest, slowest, average.
    ///
    /// **Three numbers instead of a sentence.** The prose version said things
    /// like "every search waits about 13.1s for this one", which is one number
    /// in eleven words and reads as nagging by the third row. The spread also
    /// carries something the sentence could not: an indexer answering between
    /// 0.2s and 27s is a different problem from one that always takes 13s.
    ///
    /// Empty when nothing has been measured. A blank cell is honest; zeroes
    /// are not.
    @ViewBuilder
    private func measurement(_ row: HealthReport.IndexerRow) -> some View {
        if let timings = row.timings {
            HStack(spacing: Spacing.s4) {
                timing("fastest", timings.fastest)
                separator
                timing("slowest", timings.slowest)
                separator
                timing("average", timings.average)
            }
            .foregroundStyle(pillInk(row.verdict))
            .padding(.horizontal, Spacing.s8)
            .padding(.vertical, Spacing.s2)
            .background(pillFill(row.verdict), in: Capsule())
            .fixedSize()
            .help("Fastest, slowest, average over \(row.health.answered) of "
                + "\(row.health.attempts) searches")
        }
    }

    /// **Labelled, because three bare numbers are a puzzle.** Read cold,
    /// `200 ms | 27.0s | 13.6s` gives no clue which is which, and the two
    /// plausible orders (fastest-first, slowest-first) disagree about the
    /// worst case.
    private func timing(_ label: String, _ value: String) -> some View {
        HStack(spacing: Spacing.s2) {
            Text("\(label):")
                .font(FetchFont.caption2)
                .foregroundStyle(Palette.textTertiary)
            Text(value)
                .font(FetchFont.calloutMono)
        }
    }

    private var separator: some View {
        Text("/")
            .font(FetchFont.calloutMono)
            .foregroundStyle(Palette.textTertiary)
    }

    /// Colour carries the verdict, so the row needs no adjective.
    private func pillFill(_ verdict: HealthReport.Verdict) -> Color {
        switch verdict {
        case .failing, .unreliable: Palette.miss.opacity(0.16)
        case .slow: Palette.attention.opacity(0.18)
        case .healthy: Palette.cached.opacity(0.16)
        case .untested: Palette.rowAlternate
        }
    }

    private func pillInk(_ verdict: HealthReport.Verdict) -> Color {
        switch verdict {
        case .failing, .unreliable: Palette.miss
        case .slow: Palette.attention
        case .healthy: Palette.cached
        case .untested: Palette.textSecondary
        }
    }

    /// Facts, not advice.
    private func indexerHelp(_ row: HealthReport.IndexerRow) -> String {
        if row.isMissingFromServer { return "No longer on this server." }
        if !row.isEnabled { return "Off. Not queried." }
        guard row.health.attempts > 0 else { return row.areaSummary }
        return "\(row.verdict.title). Answered \(row.health.answered) of "
            + "\(row.health.attempts). \(row.areaSummary)."
    }

    // MARK: - Debrid

    private func debridRow(_ row: HealthReport.DebridRow) -> some View {
        SettingRow(
            label: row.name,
            help: debridHelp(row),
            leadingAccessory: AnyView(StatusDot(
                state: row.isEnabled ? (row.canReportCacheStatus ? .up : .waiting) : .off))
        ) {
            HStack(spacing: Spacing.s8) {
                if !row.hitRateText.isEmpty {
                    Text(row.hitRateText)
                        .font(FetchFont.calloutMono)
                        .foregroundStyle(row.canReportCacheStatus
                            ? Palette.textSecondary : Palette.textTertiary)
                        .fixedSize()
                }
                Toggle("", isOn: Binding(
                    get: { row.isEnabled },
                    set: { model.setDebridEnabled(row.id, isEnabled: $0) }))
                    .labelsHidden()
                    .help("Use \(row.name) for downloads")
            }
        }
        .opacity(row.isEnabled ? 1 : 0.6)
    }

    private func debridHelp(_ row: HealthReport.DebridRow) -> String {
        if !row.isEnabled { return "Off. Not used." }
        // Real-Debrid's availability endpoint is disabled at the service's
        // end, so there is no rate to report and no point describing one.
        guard row.canReportCacheStatus else { return "Cache status unsupported." }
        guard row.stats.checked > 0 else { return "No results checked yet." }
        let errors = row.stats.errors > 0 ? " \(row.stats.errors) failed." : ""
        return "\(row.stats.hits) of \(row.stats.checked) cached.\(errors)"
    }

    // MARK: - Derived

    private var hasMeasurements: Bool {
        model.indexerHealthRows.contains { $0.health.attempts > 0 }
            || model.debridHealthRows.contains { $0.stats.checked > 0 }
    }

    /// The summary dot takes the worst verdict on the pane, so the colour and
    /// the sentence beside it cannot disagree.
    private var summaryDot: StatusDot.State {
        let live = model.indexerHealthRows.filter(\.isEnabled)
        guard !live.isEmpty else { return .off }
        let worst = live.map(\.verdict).max() ?? .untested
        return dot(for: worst, isEnabled: true)
    }

    private func dot(for verdict: HealthReport.Verdict, isEnabled: Bool) -> StatusDot.State {
        guard isEnabled else { return .off }
        switch verdict {
        case .failing, .unreliable: return .down
        case .slow: return .waiting
        case .healthy: return .up
        case .untested: return .waiting
        }
    }
}
