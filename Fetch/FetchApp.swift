import SwiftUI

/// The three top-level sections in the sidebar. Settings sits below Downloads
/// rather than in a separate window: "Open Settings" from a banner used to
/// raise a window over the thing the banner was about, and every one of those
/// call sites landed on whichever tab was last open.
enum SidebarSection: String, Hashable, CaseIterable {
    case search, downloads, settings
}

/// Which pane Settings shows. Named so a deep link can state its destination
/// instead of inheriting whatever `TabView` last displayed.
///
/// **Plugins is deliberately absent.** M5's runtime is intact — `PluginLoader`
/// and `PluginRegistry` still load manifests in `AppModel.init` and still
/// resolve routing and naming — but the pane is gone. Restoring it means
/// restoring `PluginSettingsView`, `AppModel.pluginFailures`, `reloadPlugins`
/// and `disablePlugin` from history as well as this case; nothing persists a
/// tab by raw value, so there is no stored `"plugins"` to migrate either way.
enum SettingsTab: String, Hashable, CaseIterable, Identifiable {
    case debrid, search, sources, quality, organization, transfers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .debrid: "Debrid"
        case .search: "Search"
        case .sources: "Sources"
        case .quality: "Quality"
        case .organization: "Organization"
        case .transfers: "Transfers"
        }
    }
}

@main
struct FetchApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(FetchAppDelegate.self) private var delegate
    @State private var closeCoordinator: WindowCloseCoordinator?

    var body: some Scene {
        WindowGroup {
            @Bindable var model = model
            NavigationSplitView {
                List(selection: $model.sidebarSection) {
                    Label("Search", systemImage: "magnifyingglass")
                        .tag(SidebarSection.search)
                    Label("Downloads", systemImage: "arrow.down.circle")
                        .tag(SidebarSection.downloads)
                    Label("Settings", systemImage: "gearshape")
                        .tag(SidebarSection.settings)
                }
                .navigationSplitViewColumnWidth(min: 160, ideal: 200)
            } detail: {
                Group {
                    switch model.sidebarSection {
                    case .downloads: DownloadsView()
                    case .settings: SettingsView()
                    case .search: SearchView()
                    }
                }
                // Bottom, like the search screen's own banners: a card
                // arriving over the toolbar covers the controls someone is
                // most likely reaching for, and two of them stacked pushed
                // the first out of reach.
                //
                // **Over the content, not above it.** As a row in a `VStack`
                // this pushed the entire screen down the moment a download
                // failed — the search field, the category pills and every
                // result moved, which is a jarring thing for a *notification*
                // to do, and worse when two of them stack. A failure is
                // transient and the layout should not remember it happened.
                //
                // App-level rather than per-screen: a download failing while
                // the user is on Search must still reach them. `errorMessage`
                // was written in five places and shown in none, so failures
                // were recorded and silently discarded.
                .overlay(alignment: .bottom) {
                    if let message = model.errorMessage {
                        InlineBannerView(
                            message: message,
                            onDismiss: { model.errorMessage = nil })
                            .padding(Spacing.s12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.25), value: model.errorMessage)
            }
            .environment(model)
            .frame(minWidth: 900, minHeight: 560)
            // **The frost lives on the window, once.** Painting it per view
            // stacks material on material — two 40%-opaque layers are 64%, and
            // a third is 78%, which is a grey box with extra steps. One
            // container background means everything above it can simply not
            // paint, and the depth comes from the window rather than from
            // accumulating haze.
            //
            // The scrim on top of it is what makes the frost usable: over a
            // bright wallpaper, small secondary text on bare material falls
            // under the contrast this design system asks for, and it *changes
            // as the desktop does*. See `Palette.windowScrim`.
            .containerBackground(.ultraThinMaterial, for: .window)
            .background(Palette.windowScrim)
            // The toolbar was painting its own opaque bar over all of this — a
            // black slab across the top that ignored the window's rounded
            // corners and overhung them. Hiding its background lets the same
            // frost run from the title bar to the bottom of the window, which
            // is the point of frosting it at all.
            .toolbarBackground(.hidden, for: .windowToolbar)
            // Closing a download manager's window is not the same as finishing
            // with it — transfers outlive the window by design. The
            // coordinator asks once and remembers.
            .onAppear {
                delegate.model = model
                let coordinator = WindowCloseCoordinator(model: model)
                closeCoordinator = coordinator
                coordinator.attach()
            }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.sidebarSection = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        // A menu bar item, so an app that keeps downloading with its window
        // closed is still visible and still reachable. Without one, "keep
        // downloading in the background" would mean an app with no interface
        // at all.
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            // A ring that fills, rather than a number that ticks. The count
            // still appears in the menu; up here what is wanted is "is it
            // going, and roughly how far", which a shape answers at a glance
            // and a changing digit does not.
            Image(nsImage: MenuBarProgressIcon.image(
                fraction: model.activeProgress?.fraction))
        }
    }
}

/// What the menu bar item opens: what is running, and the two things worth
/// doing without going back to the window.
private struct MenuBarContent: View {
    @Bindable var model: AppModel

    var body: some View {
        if let progress = model.activeProgress {
            Text("\(progress.count) downloading — \(Int(progress.fraction * 100))%")
            Divider()
        } else {
            Text("Nothing downloading")
            Divider()
        }

        Button("Open Fetch") {
            NSApp.activate(ignoringOtherApps: true)
            // A window that was closed rather than minimised has to be
            // recreated, which is what `reopen` does.
            NSApp.sendAction(
                #selector(NSApplication.arrangeInFront(_:)), to: nil, from: nil)
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        Button("Quit Fetch") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
