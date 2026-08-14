import SwiftUI
import FetchKit

/// The three top-level sections in the sidebar. Settings sits below Downloads
/// rather than in a separate window: "Open Settings" from a banner used to
/// raise a window over the thing the banner was about, and every one of those
/// call sites landed on whichever tab was last open.
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
    /// **First, and added here rather than by plan 3.** It is the pane people
    /// open Settings to find; Debrid is the one they open once. It exists in
    /// the enum from the foundation commit with a placeholder body so that
    /// plan 1's rewrite of the pane row and plan 3's filling of this case never
    /// both edit the same declaration in two worktrees.
    case appearance
    case debrid, search, sources, quality, organization, transfers
    /// Last, because it is where you go *after* something has gone wrong —
    /// and because it reports on the panes before it rather than configuring
    /// anything of its own.
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
    /// One for the app, not one per screen: it hangs off whichever window is
    /// in front, and two of them could each be showing a different failure.
    @State private var errorPanel = ErrorPanel()
    /// A torrent dropped on the window, waiting for its sheet. Identity is the
    /// infohash, so dropping the same torrent twice re-opens one sheet rather
    /// than stacking two.
    @State private var droppedResult: SearchResult?
    /// **The menu keeps what the button had.** Add Link was a control on the
    /// Downloads bar, and ⌘N belonged to it — removing the button would have
    /// removed the only way to add a magnet by hand along with it. Dropping a
    /// torrent and pasting one into Search are the ordinary ways in now; this
    /// is the one for a link you have on your clipboard and nowhere to put.
    @State private var showingAddLink = false
    /// What a dropped web address put in the sheet, cleared on dismiss so ⌘N
    /// opens empty rather than repeating the last drop.
    @State private var droppedLinkText = ""

    var body: some Scene {
        WindowGroup {
            @Bindable var model = model
            // **Two columns, not a `NavigationSplitView`.** The split view
            // draws its content as a rounded glass surface inset a few points
            // inside the window frame, with a specular edge along it — so the
            // window read as a panel floating on a frame rather than as one
            // window, and no background could merge the two: the frame band
            // showed whatever we supplied *without* that overlay and the
            // content showed it *with*, so tinting moved both and the seam
            // survived. Painting the scrim into `containerBackground` did not
            // help, and neither did hiding the title bar; both were measured.
            // An `HStack` has no such surface. The cost is the split view's
            // column resizing and `List`'s selection, and the sidebar is
            // three fixed items that never needed either.
            HStack(spacing: 0) {
                SidebarColumn()
                Divider()
                Group {
                    switch model.sidebarSection {
                    // Search puts its own field up on the traffic lights'
                    // line; these two have nothing to put there, so they
                    // start below the strip instead of under it.
                    // Search builds the bar into its own header, above the
                    // field; these two have no header of their own, so it is
                    // inset over the top of them.
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
            // **Every screen, not just Downloads.** A torrent dropped while
            // the user is looking at Search used to land on nothing: the
            // handler was inside `DownloadsView`. One modifier at the root,
            // and the sheet it opens is the same sheet a search result opens.
            //
            // Nothing here contacts a peer: the file is parsed locally by
            // `TorrentFile` and only the infohash goes out, over HTTPS, to the
            // configured services.
            // **Every screen but Settings.** A torrent dropped on a preferences
            // pane is a drop with no meaning there, and lighting the whole
            // window for it would promise something the screen cannot do.
            .windowTorrentDrop(isEnabled: model.sidebarSection != .settings) { dropped in
                // A dropped web address is a question rather than a download,
                // and Add Link is the screen that answers it.
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
                // Started on the drop rather than when the sheet opens, so the
                // pill is usually resolved by the time it appears.
                model.beginAvailabilityCheck(for: result)
                droppedResult = result
            }
            .sheet(isPresented: $showingAddLink, onDismiss: { droppedLinkText = "" }) {
                AddLinkSheet(initialText: droppedLinkText)
            }
            .sheet(item: $droppedResult) { result in
                FilePickerSheet(
                    // Empty: there is no indexer behind a magnet the user
                    // dropped, and "Added by hand" was that slot telling them
                    // what they had just done.
                    result: result, indexerLabel: "")
            }
            // **Hiding the title bar does not hand its space back.** The
            // window still insets its content by the height of the bar it no
            // longer draws, so the sidebar's own clearance stacked on top of
            // that and the first nav item sat 50pt below the traffic lights.
            // Taking the top safe area is what closes it; each column then
            // pads itself by the one number they share.
            .ignoresSafeArea(.container, edges: .top)
            .environment(model)
            // **Errors leave the window.** `errorMessage` is an event, not a
            // state: it was written in five places and shown in none, then
            // shown in a banner that was part of the layout and moved every
            // screen it appeared on. It is handed to a panel outside the
            // window's frame and cleared immediately, so nothing below here
            // can lay itself out around a failure.
            //
            // App-level rather than per-screen: a download failing while the
            // user is on Search must still reach them.
            .environment(\.errorPresenter, errorPanel)
            // **And the same panel where there is no environment to read.**
            // The environment reaches views; some of these sentences are raised
            // by the model, from inside a file-dialog callback, where there is
            // none. Without this the model's route fell back to `errorMessage`,
            // which is a `String` — so the sentence arrived and the alert's
            // action ("Open Settings", on a folder outside the download root)
            // was silently dropped on the way. Two seams were built in parallel
            // worktrees; this is the line that makes them one.
            .task { ErrorPresenting.current = errorPanel }
            // **At launch, not only when Settings is opened.** Indexers are
            // added and removed in Jackett or Prowlarr, and until Fetch asks,
            // a new one is invisible and a deleted one keeps failing every
            // search. One cheap request per server; failures change nothing.
            .task { await model.refreshIndexerRosters() }
            // **Inside the window, and still in no layout.** An overlay cannot
            // push or resize anything above it, which was the whole objection
            // to the banner; being an overlay rather than a separate `NSPanel`
            // is what makes it read as this app speaking rather than as a
            // second window that appeared on the desktop.
            .overlay(alignment: .bottom) { ErrorPanelOverlay(panel: errorPanel) }
            // Above the error panel's edge and below nothing: a confirmation
            // that something worked must never cover a report that something
            // did not.
            .overlay(alignment: .bottom) { CopyToastOverlay(toast: model.copyToast) }
            .animation(.easeOut(duration: 0.18), value: model.copyToast.message)
            .animation(.snappy(duration: 0.24), value: errorPanel.current)
            .onChange(of: model.errorMessage) { _, message in
                guard let message else { return }
                errorPanel.present(AppAlert(message: message))
                model.errorMessage = nil
            }
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
            //
            // **Only Glass is a lens.** Blizzard and Midnight are materials,
            // and the point of them is that the window stops changing as the
            // desktop does — so they paint one opaque surface here instead, and
            // their scrim is clear because there is nothing left to steady.
            .containerBackground(windowSurface, for: .window)
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
                // The stored theme, the appearance it pins, and the key that
                // opens the app from any other one. Here rather than in
                // `AppModel.init` because both reach `NSApp`, which does not
                // exist yet while the model is being built.
                model.restoreAppearance()
            }
        }
        // The title bar would otherwise draw a strip above all of this and put
        // the traffic lights on a surface of its own, which is the same seam
        // one row further down. Hidden, the two columns own the window from
        // its top edge and the lights float over the sidebar.
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

    /// What the window is made of: a lens, or a material.
    ///
    /// Read through `ActiveTheme` rather than `model.appearanceTheme` so that
    /// the window's own surface is invalidated by the same observation every
    /// token in `Palette` is — one source, so the frost and the ink on it can
    /// never be a theme apart.
    private var windowSurface: AnyShapeStyle {
        ActiveTheme.shared.isTranslucent
            ? AnyShapeStyle(.ultraThinMaterial)
            // The whole window, sidebar included. The sidebar paints nothing of
            // its own — the frost was always the window's, once — so an opaque
            // theme has one surface here rather than a second one painted in a
            // column this plan is not allowed to open.
            : AnyShapeStyle(Palette.contentBackground)
    }
}

/// What the menu bar item opens: what is running, and the two things worth
/// doing without going back to the window.
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
