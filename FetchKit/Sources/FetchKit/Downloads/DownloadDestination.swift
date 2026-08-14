import Foundation

/// Where one download is about to land, and the menu that changes it.
///
/// **Every decision here is a pure function.** The app target has no test
/// bundle, so a rule written in a sheet is a rule that stops being checked —
/// and the rule that matters most here ("never offer a folder the download
/// cannot actually be written to") is exactly the kind that fails silently.
public enum DownloadDestination {
    /// An override expressed the only way the download layer can take one.
    ///
    /// **Why a subfolder and not a root.** Every enqueue path — the magnet
    /// submit, the selective enqueue, the direct download — takes
    /// `destinationRoot: downloadDirectory` and a `subfolder`. The root is the
    /// app's single configured download folder and the containment check in
    /// `DestinationResolver.resolve` refuses anything that lands outside it.
    /// So a per-download destination is a *subfolder of the root*, and a
    /// destination outside the root is not an override the app can honour: it
    /// is a different download folder, which is a setting.
    ///
    /// Nil subfolder means the root itself.
    public static func subfolder(forDestination destination: URL, root: URL) -> String? {
        let rootComponents = pathComponents(root)
        let destinationComponents = pathComponents(destination)
        guard destinationComponents.count >= rootComponents.count,
              Array(destinationComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        return destinationComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// The folder a download with this subfolder lands in.
    public static func destination(root: URL, subfolder: String) -> URL {
        var url = root.standardizedFileURL
        for component in subfolder.split(separator: "/") where !component.isEmpty {
            url.appendPathComponent(String(component))
        }
        return url.standardizedFileURL
    }

    /// `standardizedFileURL` first, so `/Users/x/Downloads/./Fetch` and
    /// `/Users/x/Downloads/Fetch/` are one path rather than three. Empty
    /// components are dropped because a trailing slash otherwise makes a
    /// folder fail to contain itself.
    private static func pathComponents(_ url: URL) -> [String] {
        url.standardizedFileURL.path.split(separator: "/").map(String.init)
    }
}

/// What the destination readout says, split so the view can weight the leaf.
///
/// The path used to be a bare grey `/Users/nikeshkumar/Downloads/Fetch` — the
/// whole thing, untruncated, in a sheet 580 points wide. Nobody needs their own
/// home directory read back to them; what is load-bearing is the last folder,
/// which is the one the rules chose.
public struct DestinationReadout: Equatable, Sendable {
    /// Everything before the final folder, with its trailing slash: the
    /// context, in quieter ink.
    public let prefix: String
    /// The final folder. The only part that changes when the rules do.
    public let leaf: String

    public var full: String { prefix + leaf }

    /// Built from the last two components of the root plus the subfolder, so
    /// the readout reads `Downloads/Fetch/Movies` rather than four levels of
    /// somebody's home directory.
    public init(root: URL, subfolder: String) {
        let rootTail = root.standardizedFileURL.path
            .split(separator: "/").map(String.init).suffix(2)
        let components = Array(rootTail)
            + subfolder.split(separator: "/").map(String.init)
        guard let last = components.last else {
            self.prefix = ""
            self.leaf = "/"
            return
        }
        self.leaf = last
        self.prefix = components.dropLast().map { $0 + "/" }.joined()
    }
}

/// The menu behind the destination readout on a sheet's facts line.
///
/// It briefly hung off the Download button as well. One choice with two doors
/// reads as two settings until you have opened both and found the same list, so
/// the header owns it: that is where the destination is stated, and stating it
/// and changing it should be the same control.
public enum DestinationMenu {
    public enum Entry: Equatable, Sendable {
        /// One of the folders the organization rules can send things to:
        /// Movies, TV Shows, Anime, Music, Books, Other.
        case category(subfolder: String)
        /// Anywhere else, through a file dialog.
        case choose
    }

    /// The categories the rules know about, then Choose location.
    ///
    /// **Built from the routing rules rather than from a list of its own.**
    /// The first version of this menu offered the rule's own choice plus the
    /// last two folders anything had been sent to, which had two problems: the
    /// recents are a different folder set from the one the app organises into,
    /// so the menu and Settings § Organization described different worlds, and
    /// a menu whose entries depend on what you did earlier cannot be learned.
    /// The categories are stable, they are the same folders the rules use, and
    /// adding a rule adds an entry here for free.
    ///
    /// Order is the rules' own declared order, not the order of relevance to
    /// this item: a menu that reshuffles itself per download is one you have to
    /// read every time instead of reaching for the third row.
    ///
    /// `ruleSubfolder` is where this item is already headed. It is included
    /// even when no rule names it, because the menu must always be able to show
    /// the destination the item actually has.
    public static func entries(
        ruleSubfolder: String,
        rules: [RoutingRule]
    ) -> [Entry] {
        var seen: Set<String> = []
        var entries: [Entry] = []

        func offer(_ subfolder: String) {
            let key = normalise(subfolder)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            entries.append(.category(subfolder: key))
        }

        for rule in rules { offer(rule.subfolder) }
        // Where anything unmatched lands. Always offered, because "Other" is a
        // real destination and not having it in the list would make the one
        // folder every unclassified download goes to the only one you cannot
        // choose on purpose.
        offer(Routing.fallbackSubfolder)
        offer(ruleSubfolder)

        entries.append(.choose)
        return entries
    }

    /// What an entry is called in the menu.
    ///
    /// The leaf alone, not the full path: every category sits directly under
    /// the same root, so the prefix is identical on every row and repeating it
    /// six times says nothing.
    public static func title(for entry: Entry, root: URL) -> String {
        switch entry {
        case .category(let subfolder):
            DestinationReadout(root: root, subfolder: subfolder).leaf
        case .choose:
            "Choose location…"
        }
    }

    /// Which entry a subfolder corresponds to, for the tick in the menu.
    public static func entry(matching subfolder: String, in entries: [Entry]) -> Entry? {
        let key = normalise(subfolder)
        return entries.first { entry in
            if case .category(let candidate) = entry { return normalise(candidate) == key }
            return false
        }
    }

    private static func normalise(_ subfolder: String) -> String {
        subfolder.split(separator: "/").joined(separator: "/")
    }
}

