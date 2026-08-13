import SwiftUI
import FetchKit

/// Settings § Search — one row per **server**, not per indexer.
///
/// A Prowlarr with eight indexers used to occupy eight top-level rows, each
/// holding its own copy of one API key. Now it is one row; the indexers live
/// inside its edit sheet with individual toggles and measured latency.
struct SearchSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var showingAddSheet = false
    @State private var editingServer: IndexerServerConfig?
    @State private var didRemoveUnused = false

    var body: some View {
        @Bindable var model = model

        // A `Form`, like every other settings pane. This one was hand-built
        // as a `VStack`, which is why it alone looked right while the others
        // used macOS's column-aligned default — and then why it alone looked
        // wrong once they were given the grouped style. One container for all
        // seven is what makes the header's width match theirs.
        Form {
            Section {
                Toggle("Start searches with “Cached only” on", isOn: $model.cachedOnlyDefault)
                Text("The filters panel can turn it off for a single search.")
                    .font(FetchFont.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                if model.indexerServers.isEmpty {
                    EmptyStateView(
                        symbol: "magnifyingglass",
                        title: "No indexers configured",
                        message: "Add a Torznab server (Jackett or Prowlarr) to enable search.",
                        actionTitle: "Add Server…",
                        action: { showingAddSheet = true }
                    )
                    // Enough to read as a state rather than a gap, without
                    // the fixed 220 that used to stop the pane scrolling.
                    .frame(minHeight: 160)
                } else {
                    ForEach(model.indexerServers) { server in
                        ServerRow(
                            server: server,
                            onToggle: { model.setServerEnabled(id: server.id, isEnabled: $0) },
                            onEdit: { editingServer = server },
                            onDelete: { model.removeIndexerServer(id: server.id) }
                        )
                    }

                    HStack {
                        unusedKeysControl
                        Spacer()
                        Button("Add Server…") { showingAddSheet = true }
                    }
                }
            } header: {
                Text("Indexers").font(FetchFont.headline)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAddSheet) { ServerEditSheet(existing: nil) }
        .sheet(item: $editingServer) { ServerEditSheet(existing: $0) }
    }

    /// Migration copies each server's key forward without deleting the
    /// per-indexer originals, so they linger. Removing them is an explicit
    /// action, not an invisible side effect of launching.
    @ViewBuilder
    private var unusedKeysControl: some View {
        let count = model.unusedCredentialCount
        if didRemoveUnused {
            Text("Removed.")
                .font(FetchFont.footnote)
                .foregroundStyle(Palette.textSecondary)
        } else if count > 0 {
            Button("Remove \(count) unused key\(count == 1 ? "" : "s")") {
                model.removeUnusedCredentials()
                didRemoveUnused = true
            }
            .buttonStyle(.borderless)
            .font(FetchFont.footnote)
            .help("Stored API keys that no configured server refers to any more.")
        }
    }
}

private struct ServerRow: View {
    let server: IndexerServerConfig
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s12) {
            Toggle("", isOn: Binding(get: { server.isEnabled }, set: onToggle))
                .labelsHidden()

            VStack(alignment: .leading, spacing: Spacing.s2) {
                Text(server.displayName)
                    .font(FetchFont.body)
                Text(server.rootURL.host ?? server.rootURL.absoluteString)
                    .font(FetchFont.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(summary)
                .font(FetchFont.footnote)
                .foregroundStyle(Palette.textSecondary)

            Button("Edit…", action: onEdit)
                .buttonStyle(.borderless)
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(server.displayName)")
        }
        .padding(.vertical, Spacing.s4)
        .opacity(server.isEnabled ? 1 : 0.5)
    }

    /// A single-indexer server is a standalone endpoint; "1 of 1 indexers"
    /// would be noise.
    private var summary: String {
        server.indexers.count == 1
            ? "1 indexer"
            : "\(server.enabledCount) of \(server.indexers.count) indexers"
    }
}

/// Add/edit sheet.
///
/// The URL field accepts whatever the user has in their browser's address bar.
/// Both Test and Save run it through `IndexerSetup`, which probes the candidate
/// API paths under it and keeps the one that actually answers `t=caps` —
/// pasting `http://10.0.0.181:9696` used to save a URL that only ever
/// redirected to a login page.
private struct ServerEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let existing: IndexerServerConfig?

    @State private var displayName = ""
    @State private var baseURLText = ""
    @State private var apiKeyInput = ""
    @State private var testState: TestState = .idle
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var plan: IndexerSetup.Plan?

    /// Probe results for this sheet's table, keyed by sub-indexer.
    @State private var probes: [SearchProviderID: ProbeOutcome] = [:]
    @State private var isProbing = false

    private struct ProbeOutcome: Equatable {
        let latency: TimeInterval
        let failure: String?
    }

    private enum TestState: Equatable {
        case idle
        case testing
        case success(url: String, categoryCount: Int, modes: [String])
        case discovered(names: [String])
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s12) {
            Text(existing == nil ? "Add Indexer Server" : "Edit \(existing?.displayName ?? "")")
                .font(FetchFont.title3)

            TextField("Display Name (e.g. Prowlarr)", text: $displayName)
                .textFieldStyle(.roundedBorder)

            TextField("Server URL (e.g. http://10.0.0.181:9696)", text: $baseURLText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: baseURLText) {
                    plan = nil
                    testState = .idle
                }
                .help("Your Jackett or Prowlarr address. The Torznab API path is "
                    + "found for you; a full endpoint URL also works as-is.")

            SecureField(
                existing == nil ? "API Key" : "API Key (leave blank to keep current)",
                text: $apiKeyInput
            )
            .textFieldStyle(.roundedBorder)

            statusLine

            if let existing, !existing.indexers.isEmpty {
                indexerTable(existing)
            }

            HStack(spacing: Spacing.s8) {
                Button(existing == nil ? "Test" : "Test Connection") { Task { await test() } }
                    .disabled(parsedURL == nil || effectiveAPIKey.isEmpty || isBusy)
                if existing != nil {
                    Button("Test All Indexers") { Task { await probeAll() } }
                        .disabled(effectiveAPIKey.isEmpty || isBusy)
                }
                if isBusy { ProgressView().controlSize(.small) }
            }

            if let saveError {
                Text(saveError)
                    .font(FetchFont.callout)
                    .foregroundStyle(Palette.miss)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || isBusy)
            }
        }
        .padding(Spacing.s20)
        .frame(width: 520)
        .onAppear {
            if let existing {
                displayName = existing.displayName
                baseURLText = existing.rootURL.absoluteString
            }
        }
    }

    // MARK: - Indexer table

    private func indexerTable(_ server: IndexerServerConfig) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            Text("Indexers")
                .font(FetchFont.headline)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(server.indexers) { indexer in
                        indexerRow(server: server, indexer: indexer)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }

    private func indexerRow(server: IndexerServerConfig, indexer: SubIndexer) -> some View {
        HStack(spacing: Spacing.s8) {
            Toggle("", isOn: Binding(
                get: { indexer.isEnabled },
                set: { model.setIndexerEnabled(server: server.id, indexer: indexer.id, isEnabled: $0) }
            ))
            .labelsHidden()

            Text(indexer.name)
                .font(FetchFont.callout)
                .lineLimit(1)

            if indexer.isMissingFromServer {
                Text("no longer on this server")
                    .font(FetchFont.caption2)
                    .foregroundStyle(Palette.attention)
            }

            Spacer()

            latencyLabel(for: indexer)
        }
        .padding(.vertical, Spacing.s2)
        .opacity(indexer.isEnabled ? 1 : 0.5)
    }

    /// Latency, or the reason there was no answer. Never a result count: the
    /// probe uses one arbitrary term, and counts are not comparable between
    /// indexers of different scope — a count told the user nothing, and a
    /// failure rendered as `0` looked identical to a working indexer that
    /// found nothing.
    ///
    /// Prefers a probe from this sheet session over the persisted value, so
    /// pressing Test All updates rows as they land.
    @ViewBuilder
    private func latencyLabel(for indexer: SubIndexer) -> some View {
        if let probe = probes[indexer.id] {
            if let failure = probe.failure {
                failureText(failure)
            } else {
                Text("\(Int((probe.latency * 1000).rounded())) ms")
                    .font(FetchFont.calloutMono)
                    .foregroundStyle(Palette.textSecondary)
            }
        } else if isProbing {
            ProgressView().controlSize(.mini)
        } else if let summary = indexer.probeSummary {
            Group {
                if indexer.lastProbeFailure != nil {
                    failureText(summary)
                } else {
                    Text(summary)
                        .font(FetchFont.calloutMono)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .help(indexer.lastTestedAt.map {
                "Last tested \($0.formatted(date: .abbreviated, time: .shortened))"
            } ?? "")
        } else {
            Text("—")
                .font(FetchFont.calloutMono)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private func failureText(_ message: String) -> some View {
        Text(message)
            .font(FetchFont.caption2)
            .foregroundStyle(Palette.miss)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(message)
    }

    // MARK: - Derived state

    private var parsedURL: URL? {
        let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return url
    }

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAPIKeyInput: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectiveAPIKey: String {
        if !trimmedAPIKeyInput.isEmpty { return trimmedAPIKeyInput }
        if let existing { return model.indexerServerAPIKey(for: existing.id) ?? "" }
        return ""
    }

    private var canSave: Bool {
        guard !trimmedName.isEmpty, parsedURL != nil else { return false }
        return existing != nil || !trimmedAPIKeyInput.isEmpty
    }

    private var isBusy: Bool { testState == .testing || isSaving || isProbing }

    @ViewBuilder
    private var statusLine: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            Text("Finding the Torznab endpoint…")
                .font(FetchFont.callout)
                .foregroundStyle(Palette.textSecondary)
        case .success(let url, let categoryCount, let modes):
            VStack(alignment: .leading, spacing: Spacing.s2) {
                Text(
                    "Connected — \(categoryCount) categories, modes: "
                    + (modes.isEmpty ? "none advertised" : modes.joined(separator: ", "))
                )
                .foregroundStyle(Palette.cached)
                Text(url)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .font(FetchFont.callout)
        case .discovered(let names):
            VStack(alignment: .leading, spacing: Spacing.s2) {
                Text("Found \(names.count) \(names.count == 1 ? "indexer" : "indexers")")
                    .foregroundStyle(Palette.cached)
                Text(names.joined(separator: ", "))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(FetchFont.callout)
        case .failure(let message):
            Text(message)
                .font(FetchFont.callout)
                .foregroundStyle(Palette.miss)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Probing

    /// Times a small real query against every indexer concurrently. Wall-clock
    /// around the request, because that is what the user waits through.
    private func probeAll() async {
        guard let existing else { return }
        let key = effectiveAPIKey
        guard !key.isEmpty else { return }

        isProbing = true
        probes = [:]
        defer { isProbing = false }

        await withTaskGroup(of: (SearchProviderID, ProbeOutcome).self) { group in
            for indexer in existing.indexers where !indexer.isMissingFromServer {
                group.addTask {
                    let provider = TorznabProvider(
                        id: indexer.id, displayName: indexer.name,
                        baseURL: indexer.torznabURL, apiKey: Redacted(key), client: HTTPClient())
                    let started = Date()
                    do {
                        // A real search rather than `t=caps`: caps can answer
                        // fine on an indexer whose search path is broken, and
                        // search is what the user is actually going to do. The
                        // term is arbitrary and the result count is discarded —
                        // only reachability and the wait matter here.
                        _ = try await provider.search(
                            SearchQuery(text: "the", mode: .general, categories: [], limit: 5, offset: 0))
                        return (indexer.id, ProbeOutcome(
                            latency: Date().timeIntervalSince(started), failure: nil))
                    } catch {
                        return (indexer.id, ProbeOutcome(
                            latency: Date().timeIntervalSince(started),
                            failure: (error as? SearchError)?.errorDescription
                                ?? error.localizedDescription))
                    }
                }
            }
            for await (id, outcome) in group {
                probes[id] = outcome
                model.recordProbe(
                    server: existing.id, indexer: id,
                    latency: outcome.latency, failure: outcome.failure)
            }
        }
    }

    // MARK: - Test and save

    @discardableResult
    private func probe() async -> IndexerSetup.Plan? {
        guard let url = parsedURL else {
            testState = .failure("Enter a server URL, e.g. http://10.0.0.181:9117")
            return nil
        }
        let key = effectiveAPIKey
        guard !key.isEmpty else {
            testState = .failure("Enter the server's API key.")
            return nil
        }

        do {
            let found = try await IndexerSetup.plan(
                url: url, apiKey: Redacted(key), client: HTTPClient())
            plan = found
            switch found {
            case .single(let resolvedURL, let caps):
                testState = .success(
                    url: resolvedURL.absoluteString,
                    categoryCount: caps.categories.count,
                    modes: caps.supportedModes.map(\.rawValue).sorted())
            case .prowlarr(_, let indexers):
                testState = .discovered(names: indexers.map(\.name))
            }
            return found
        } catch {
            plan = nil
            testState = .failure(error.localizedDescription)
            return nil
        }
    }

    private func test() async {
        testState = .testing
        await probe()
    }

    /// Save probes too, rather than trusting the raw field: a user who never
    /// presses Test must not end up with the unreachable URL that endpoint
    /// resolution exists to prevent.
    private func save() async {
        guard parsedURL != nil else { return }
        saveError = nil

        var resolved = plan
        if resolved == nil {
            isSaving = true
            testState = .testing
            resolved = await probe()
            isSaving = false
        }
        guard let resolved else { return }

        do {
            let indexers = subIndexers(from: resolved)
            if let existing {
                try model.updateIndexerServer(
                    id: existing.id, displayName: trimmedName,
                    rootURL: rootURL(from: resolved),
                    apiKey: trimmedAPIKeyInput.isEmpty ? nil : trimmedAPIKeyInput)
                // Reconcile rather than replace, so toggles and measured
                // latency survive a Save that re-ran discovery.
                model.reconcileIndexers(id: existing.id, discovered: indexers)
            } else {
                try model.addIndexerServer(
                    displayName: trimmedName, rootURL: rootURL(from: resolved),
                    indexers: indexers, apiKey: effectiveAPIKey)
            }
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// A standalone endpoint becomes a one-indexer server named after the
    /// server itself — there is no separate indexer name to use.
    private func subIndexers(from plan: IndexerSetup.Plan) -> [SubIndexer] {
        switch plan {
        case .single(let url, _):
            [SubIndexer(
                id: SearchProviderID(rawValue: UUID().uuidString),
                name: trimmedName, torznabURL: url)]
        case .prowlarr(let root, let indexers):
            indexers.map { indexer in
                SubIndexer(
                    id: SearchProviderID(rawValue: UUID().uuidString),
                    name: indexer.name, torznabURL: indexer.torznabURL(root: root))
            }
        }
    }

    private func rootURL(from plan: IndexerSetup.Plan) -> URL {
        switch plan {
        case .single(let url, _): url
        case .prowlarr(let root, _): root
        }
    }
}
