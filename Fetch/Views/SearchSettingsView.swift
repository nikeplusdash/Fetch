import SwiftUI
import FetchKit

/**
 Settings § Search — one row per **server**, not per indexer.

 A Prowlarr with eight indexers used to occupy eight top-level rows, each
 holding its own copy of one API key. Now it is one row; the indexers live
 inside its edit sheet with individual toggles and measured latency.
 */
struct SearchSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var showingAddSheet = false
    @State private var editingServer: IndexerServerConfig?
    @State private var didRemoveUnused = false

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            SettingsGroup(title: "Results") {
                SettingRow(
                    label: "Start with cached only",
                    help: "The filters panel can turn it off for one search."
                ) {
                    Toggle("", isOn: $model.cachedOnlyDefault).labelsHidden()
                }
            }

            SettingsGroup(title: "Indexers") {
                if model.indexerServers.isEmpty {
                    SettingRow(
                        label: "No indexer yet",
                        help: "Search needs a Torznab server: Jackett or Prowlarr."
                    ) {
                        Button("Add Server…") { showingAddSheet = true }
                    }
                } else {
                    ForEach(model.indexerServers) { server in
                        serverRow(server)
                    }
                    SettingRow(label: "Another server", help: unusedKeysHelp) {
                        HStack(spacing: Spacing.s8) {
                            unusedKeysButton
                            Button("Add Server…") { showingAddSheet = true }
                        }
                    }
                }

                SettingRow(
                    label: "Give up after",
                    help: "A self-hosted server asking a dozen trackers can be "
                        + "slow. Raise this if searches end before they answer."
                ) {
                    Stepper(
                        value: $model.indexerTimeout,
                        in: 10...HTTPClient.maximumRequestTimeout,
                        step: 10
                    ) {
                        Text("\(Int(model.indexerTimeout))s")
                            .font(FetchFont.bodyMono)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .fixedSize()
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) { ServerEditSheet(existing: nil) }
        .sheet(item: $editingServer) { ServerEditSheet(existing: $0) }
        .task { await model.refreshIndexerRosters() }
    }

    private func serverRow(_ server: IndexerServerConfig) -> some View {
        SettingRow(
            label: server.displayName,
            help: "\(server.rootURL.host ?? server.rootURL.absoluteString). "
                + summary(server),
            leadingAccessory: {
                StatusDot(state: server.isEnabled ? .up : .off)
            }
        ) {
            HStack(spacing: Spacing.s8) {
                Toggle("", isOn: Binding(
                    get: { server.isEnabled },
                    set: { model.setServerEnabled(id: server.id, isEnabled: $0) }))
                    .labelsHidden()
                Menu {
                    Button("Edit…") { editingServer = server }
                    Button("Remove \(server.displayName)", role: .destructive) {
                        model.removeIndexerServer(id: server.id)
                    }
                } label: {
                    Image(systemName: "pencil")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Edit \(server.displayName)")
            }
        }
        .opacity(server.isEnabled ? 1 : 0.6)
    }

    private func summary(_ server: IndexerServerConfig) -> String {
        server.indexers.count == 1
            ? "1 indexer."
            : "\(server.enabledCount) of \(server.indexers.count) indexers."
    }

    private var unusedKeysHelp: String {
        let count = model.unusedCredentialCount
        if didRemoveUnused { return "The unused keys are gone." }
        guard count > 0 else { return "Jackett and Prowlarr both work." }
        return "\(count) stored key\(count == 1 ? "" : "s") no server refers to any more."
    }

    @ViewBuilder
    private var unusedKeysButton: some View {
        let count = model.unusedCredentialCount
        if !didRemoveUnused, count > 0 {
            Button("Remove \(count) Unused Key\(count == 1 ? "" : "s")") {
                model.removeUnusedCredentials()
                didRemoveUnused = true
            }
        }
    }
}

private struct ServerEditSheet: View {
    private static let latencyColumn: CGFloat = 72
    private static let sheetWidth: CGFloat = 520
    private static let areaPopoverWidth: CGFloat = 246
    private static let areaPopoverTextColumn: CGFloat = 220

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

    @State private var probes: [SearchProviderID: ProbeOutcome] = [:]
    @State private var isProbing = false
    @State private var isDiscovering = false
    @State private var editingAreasFor: SearchProviderID?

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

            if let live = existing.flatMap(currentServer), !live.indexers.isEmpty {
                indexerTable(live)
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
        .frame(width: Self.sheetWidth)
        .onAppear {
            if let existing {
                displayName = existing.displayName
                baseURLText = existing.rootURL.absoluteString
            }
        }
        .task { await refreshRoster() }
    }

    private func currentServer(_ server: IndexerServerConfig) -> IndexerServerConfig? {
        model.indexerServers.first { $0.id == server.id }
    }

    private func refreshRoster() async {
        guard let existing, !effectiveAPIKey.isEmpty, !isBusy else { return }
        isDiscovering = true
        defer { isDiscovering = false }
        guard let plan = try? await IndexerSetup.plan(
            url: existing.rootURL, apiKey: Redacted(effectiveAPIKey), client: HTTPClient())
        else { return }
        guard case .single = plan else {
            model.reconcileIndexers(id: existing.id, discovered: subIndexers(from: plan))
            return
        }
    }


    private func indexerTable(_ server: IndexerServerConfig) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            HStack(spacing: Spacing.s8) {
                Text("Indexers")
                    .font(FetchFont.headline)
                if isDiscovering { ProgressView().controlSize(.mini) }
            }
            Text("Reserve an indexer for the pills it is actually good for and "
                + "it stops being asked — and waited for — everywhere else. "
                + "All still asks every indexer.")
                .font(FetchFont.caption2)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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

            capabilityInfo(for: indexer)

            if indexer.isMissingFromServer {
                Text("no longer on this server")
                    .font(FetchFont.caption2)
                    .foregroundStyle(Palette.attention)
            }

            Spacer()

            areaMenu(server: server, indexer: indexer)

            latencyLabel(for: indexer)
                .frame(width: Self.latencyColumn, alignment: .trailing)
        }
        .padding(.vertical, Spacing.s2)
        .opacity(indexer.isEnabled ? 1 : 0.5)
    }

    @ViewBuilder
    private func capabilityInfo(for indexer: SubIndexer) -> some View {
        if let summary = indexer.advertisedCategorySummary {
            Image(systemName: "info.circle")
                .font(.system(size: IconSize.sm))
                .foregroundStyle(Palette.textTertiary)
                .help("\(indexer.name) advertises:\n\(summary)")
                .accessibilityLabel("\(indexer.name) categories: \(summary)")
        }
    }

    private func areaMenu(server: IndexerServerConfig, indexer: SubIndexer) -> some View {
        Button {
            editingAreasFor = editingAreasFor == indexer.id ? nil : indexer.id
        } label: {
            HStack(spacing: Spacing.s2) {
                Text(indexer.areaSummary)
                    .font(FetchFont.caption2)
                Image(systemName: "chevron.down")
                    .font(.system(size: IconSize.xs))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.textSecondary)
        .help("Which category pills ask this indexer. All asks every indexer.")
        .popover(
            isPresented: Binding(
                get: { editingAreasFor == indexer.id },
                set: { if !$0 { editingAreasFor = nil } }),
            arrowEdge: .bottom
        ) {
            areaPicker(server: server, indexer: indexer)
        }
    }

    private var selectableAreas: [SearchCategory] {
        SearchCategory.offered(safeSearch: model.safeSearch).filter { $0 != .all }
    }

    private func areaPicker(
        server: IndexerServerConfig, indexer: SubIndexer
    ) -> some View {
        let live = model.indexerServers
            .first { $0.id == server.id }?
            .indexers.first { $0.id == indexer.id } ?? indexer

        return VStack(alignment: .leading, spacing: Spacing.s4) {
            Text(live.name)
                .font(FetchFont.headline)
            Text("Asked only for the areas ticked here. Untick Every area to "
                + "start from all of them and take a few away.")
                .font(FetchFont.caption2)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: Self.areaPopoverTextColumn, alignment: .leading)

            Divider().padding(.vertical, Spacing.s4)

            Toggle("Every area", isOn: Binding(
                get: { live.servesEveryArea },
                set: { isOn in
                    model.setIndexerAreas(
                        server: server.id, indexer: live.id,
                        areas: isOn ? nil : Set(selectableAreas))
                }))

            ForEach(selectableAreas) { area in
                Toggle(area.title, isOn: Binding(
                    get: { !live.servesEveryArea && live.areas?.contains(area) == true },
                    set: { isOn in
                        var next = live.servesEveryArea ? [] : (live.areas ?? [])
                        if isOn { next.insert(area) } else { next.remove(area) }
                        model.setIndexerAreas(
                            server: server.id, indexer: live.id,
                            areas: next.isEmpty ? nil : next)
                    }))
            }

            if let summary = live.advertisedCategorySummary {
                Divider().padding(.vertical, Spacing.s4)
                Text("This indexer carries")
                    .font(FetchFont.caption2)
                    .foregroundStyle(Palette.textSecondary)
                Text(summary)
                    .font(FetchFont.caption2)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: Self.areaPopoverTextColumn, alignment: .leading)
            }

            Divider().padding(.vertical, Spacing.s4)
            HStack {
                Spacer()
                Button("Done") { editingAreasFor = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.s12)
        .frame(width: Self.areaPopoverWidth)
    }

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

    private var isBusy: Bool {
        testState == .testing || isSaving || isProbing || isDiscovering
    }

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
                    "Connected. \(categoryCount) categories, modes: "
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
            case .jackett(_, let indexers):
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

    private func subIndexers(from plan: IndexerSetup.Plan) -> [SubIndexer] {
        AppModel.subIndexers(from: plan, serverName: trimmedName)
    }

    private func rootURL(from plan: IndexerSetup.Plan) -> URL {
        switch plan {
        case .single(let url, _): url
        case .prowlarr(let root, _): root
        case .jackett(let root, _): root
        }
    }
}
