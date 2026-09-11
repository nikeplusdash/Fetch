import SwiftUI
import FetchKit

enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case search, downloads, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: "Search"
        case .downloads: "Downloads"
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .search: "magnifyingglass"
        case .downloads: "arrow.down.circle"
        case .settings: "gearshape"
        }
    }
}

enum SettingsTab: String, Hashable, CaseIterable, Identifiable {
    case appearance
    case debrid, search, sources, quality, organization, transfers
    case health

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .debrid: "Debrid"
        case .search: "Search"
        case .sources: "Sources"
        case .quality: "Quality"
        case .organization: "Organization"
        case .transfers: "Transfers"
        case .health: "Health"
        }
    }
}

@main
struct FetchApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(FetchAppDelegate.self) private var delegate
    @State private var closeCoordinator: WindowCloseCoordinator?
    @State private var errorPanel = ErrorPanel()
    @State private var droppedResult: SearchResult?
    @State private var showingAddLink = false
    @State private var droppedLinkText = ""

    var body: some Scene {
        WindowGroup {
            @Bindable var model = model
            HStack(spacing: 0) {
                SidebarColumn()
                Divider()
                Group {
                    switch model.sidebarSection {
                    case .downloads:
                        DownloadsView()
                            .safeAreaInset(edge: .top) { ScreenTitleBar() }
                    case .settings:
                        SettingsView()
                            .safeAreaInset(edge: .top) { ScreenTitleBar() }
                    case .search: SearchView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .windowTorrentDrop(isEnabled: model.sidebarSection != .settings) { dropped in
                if case .webLink(let url) = dropped {
                    droppedLinkText = url.absoluteString
                    showingAddLink = true
                    return
                }
                guard model.isConfigured else {
                    fetchLog(.warn, "drop", "refused: no debrid configured")
                    return
                }
                guard let result = model.result(fromDropped: dropped) else {
                    fetchLog(.warn, "drop", "refused: could not read \(dropped.displayName)")
                    return
                }
                model.beginAvailabilityCheck(for: result)
                droppedResult = result
            }
            .sheet(isPresented: $showingAddLink, onDismiss: { droppedLinkText = "" }) {
                AddLinkSheet(initialText: droppedLinkText)
            }
            .sheet(item: $droppedResult) { result in
                FilePickerSheet(
                    result: result, indexerLabel: "")
            }
            .ignoresSafeArea(.container, edges: .top)
            .environment(model)
            .environment(\.errorPresenter, errorPanel)
            .task { ErrorPresenting.current = errorPanel }
            .task { await model.refreshIndexerRosters() }
            .overlay(alignment: .bottom) { ErrorPanelOverlay(panel: errorPanel) }
            .overlay(alignment: .bottom) { CopyToastOverlay(toast: model.copyToast) }
            .animation(.easeOut(duration: 0.18), value: model.copyToast.message)
            .animation(.snappy(duration: 0.24), value: errorPanel.current)
            .onChange(of: model.errorMessage) { _, message in
                guard let message else { return }
                errorPanel.present(AppAlert(message: message))
                model.errorMessage = nil
            }
            .frame(minWidth: 900, minHeight: 560)
            .containerBackground(windowSurface, for: .window)
            .background(Palette.windowScrim)
            .toolbarBackground(.hidden, for: .windowToolbar)
            .onAppear {
                delegate.model = model
                let coordinator = WindowCloseCoordinator(model: model)
                closeCoordinator = coordinator
                coordinator.attach()
                model.restoreAppearance()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.sidebarSection = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Link…") { showingAddLink = true }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!model.isConfigured)
            }
        }

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(nsImage: MenuBarProgressIcon.image(
                fraction: model.activeProgress?.fraction))
        }
    }

    private var windowSurface: AnyShapeStyle {
        ActiveTheme.shared.isTranslucent
            ? AnyShapeStyle(.ultraThinMaterial)
            : AnyShapeStyle(Palette.contentBackground)
    }
}

private struct MenuBarContent: View {
    @Bindable var model: AppModel

    var body: some View {
        if let progress = model.activeProgress {
            Text("\(progress.count) downloading, \(Int(progress.fraction * 100))%")
            Divider()
        } else {
            Text("Nothing downloading")
            Divider()
        }

        Button("Open Fetch") { WindowPresenter.showMainWindow() }
        Button("Quit Fetch") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
