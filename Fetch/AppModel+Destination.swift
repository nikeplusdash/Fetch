import Foundation
import AppKit
import FetchKit
import FetchPluginAPI

/// Plan 2's additions — where a download lands, and the two new ways in.
///
/// See `AppModel+Library` for why these three files exist. Every decision here
/// defers to a pure function in `FetchKit`; what is left is the state and the
/// two things that genuinely need AppKit (a file dialog and a `.torrent` on
/// disk).
extension AppModel {
    // MARK: - Where it lands

    /// The one configured download folder. Everything a sheet offers is inside
    /// it, because everything the download layer can write is inside it.
    var destinationRoot: URL { downloadDirectory }

    /// What an override is filed under.
    ///
    /// The result's identity, which for a torrent is `btih:<hex>` — so opening
    /// the same torrent's sheet twice in one session remembers the folder the
    /// user chose the first time, and two different torrents never share one.
    func destinationKey(for result: SearchResult) -> String { result.id.rawValue }

    /// Where the organization rules would send this, with no override in play.
    func ruleSubfolder(for metadata: ReleaseMetadata) -> String {
        subfolder(for: metadata)
    }

    /// The subfolder the enqueue should actually be given.
    ///
    /// **A subfolder, not a root.** Every enqueue path takes
    /// `destinationRoot: downloadDirectory` and a `subfolder`, and
    /// `DestinationResolver.resolve` refuses anything that lands outside the
    /// root. So an override is a subfolder of the root; a folder outside it is
    /// not an override but a different download folder, which is a setting and
    /// is refused at the file dialog.
    func plannedSubfolder(key: String, metadata: ReleaseMetadata) -> String {
        guard let override = destinationOverrides[key],
              let subfolder = DownloadDestination.subfolder(
                forDestination: override, root: destinationRoot)
        else { return ruleSubfolder(for: metadata) }
        return subfolder
    }

    /// What the readout under the name says.
    func destinationReadout(key: String, metadata: ReleaseMetadata) -> DestinationReadout {
        DestinationReadout(
            root: destinationRoot,
            subfolder: plannedSubfolder(key: key, metadata: metadata))
    }

    /// Whether this download has been sent somewhere the rules did not choose.
    func hasDestinationOverride(key: String, metadata: ReleaseMetadata) -> Bool {
        plannedSubfolder(key: key, metadata: metadata) != ruleSubfolder(for: metadata)
    }

    /// The categories the rules can send things to, and Choose location.
    ///
    /// Built from the same `routingRules` Settings § Organization edits, so
    /// adding a rule there adds a destination here for free and the two can
    /// never describe different sets of folders.
    func destinationEntries(for metadata: ReleaseMetadata) -> [DestinationMenu.Entry] {
        DestinationMenu.entries(
            ruleSubfolder: ruleSubfolder(for: metadata),
            rules: routingRules)
    }

    /// Which entry carries the tick.
    ///
    /// Derived from the planned subfolder rather than stored, so it cannot come
    /// to disagree with the readout beside it.
    func selectedDestinationEntry(
        key: String, metadata: ReleaseMetadata
    ) -> DestinationMenu.Entry {
        .category(subfolder: plannedSubfolder(key: key, metadata: metadata))
    }

    /// Applies a menu choice. `.choose` opens the file dialog.
    ///
    /// **Per download, and not persisted.** `destinationOverrides` is memory
    /// only; the rules in Settings are untouched, because a sheet is not a
    /// place to edit preferences.
    func selectDestination(
        _ entry: DestinationMenu.Entry, key: String, metadata: ReleaseMetadata
    ) {
        switch entry {
        case .category(let subfolder):
            // Choosing the category the rules already chose clears the override
            // rather than storing one that happens to agree with them. Storing
            // it would freeze this download at today's rule while the sheet is
            // open, so editing the rule underneath would stop reaching it.
            guard subfolder != ruleSubfolder(for: metadata) else {
                destinationOverrides[key] = nil
                return
            }
            destinationOverrides[key] = DownloadDestination.destination(
                root: destinationRoot, subfolder: subfolder)
        case .choose:
            guard let chosen = chooseDestinationFolder() else { return }
            guard DownloadDestination.subfolder(
                forDestination: chosen, root: destinationRoot) != nil
            else {
                reportDestinationOutsideRoot(chosen)
                return
            }
            destinationOverrides[key] = chosen
        }
    }

    /// Clears an override once its sheet is done with it, so re-opening the
    /// same torrent tomorrow starts from the rules again.
    func forgetDestinationOverride(key: String) {
        destinationOverrides[key] = nil
    }

    // MARK: - The same four, said with a result

    // Three of the four sheets have a `SearchResult` and one does not, so the
    // decisions above take a key and metadata. These are the shorthand, in one
    // place rather than spelled out at every call site.

    func plannedSubfolder(for result: SearchResult) -> String {
        plannedSubfolder(key: destinationKey(for: result), metadata: result.metadata)
    }

    func destinationReadout(for result: SearchResult) -> DestinationReadout {
        destinationReadout(key: destinationKey(for: result), metadata: result.metadata)
    }

    func hasDestinationOverride(for result: SearchResult) -> Bool {
        hasDestinationOverride(key: destinationKey(for: result), metadata: result.metadata)
    }

    func destinationEntries(for result: SearchResult) -> [DestinationMenu.Entry] {
        destinationEntries(for: result.metadata)
    }

    func selectedDestinationEntry(for result: SearchResult) -> DestinationMenu.Entry {
        selectedDestinationEntry(key: destinationKey(for: result), metadata: result.metadata)
    }

    func selectDestination(_ entry: DestinationMenu.Entry, for result: SearchResult) {
        selectDestination(
            entry, key: destinationKey(for: result), metadata: result.metadata)
    }

    func forgetDestinationOverride(for result: SearchResult) {
        forgetDestinationOverride(key: destinationKey(for: result))
    }

    /// The file dialog, rooted at the download folder because that is the only
    /// place a choice can land.
    private func chooseDestinationFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destinationRoot
        panel.prompt = "Choose"
        panel.message = "Choose a folder inside your download folder."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Said once, where the user is looking, rather than swallowed.
    ///
    /// The alternative considered was silently clamping the choice back to the
    /// rules' folder, which is the failure mode this whole plan exists to
    /// remove: the download lands somewhere other than the place the readout
    /// names, and nothing anywhere says so.
    private func reportDestinationOutsideRoot(_ chosen: URL) {
        report(
            AppAlert(
                message: "“\(chosen.lastPathComponent)” is outside your download "
                    + "folder. Choose a folder inside it, or change the download "
                    + "folder in Settings.",
                actionTitle: "Open Settings…",
                action: { [weak self] in self?.navigate(to: .organization) }))
    }

    // MARK: - Dropping a torrent on the window

    /// Turns a drop into the thing every sheet takes, or nil if it is not
    /// something Fetch can act on.
    ///
    /// **No peer is contacted.** `TorrentFile` parses the file locally — plain
    /// bencode and a SHA-1 over the info dictionary — and only the infohash
    /// leaves the machine, over HTTPS, to the configured debrid services.
    /// Dropping a torrent joins no swarm, which is the constraint the whole app
    /// is built around.
    func result(fromDropped item: DroppedItem) -> SearchResult? {
        let magnet: MagnetLink?
        // **The file list decides the kind, where there is one.** A dropped
        // torrent has no indexer to ask, so without this the only signal is the
        // name — which is precisely the signal that filed an album under Movies
        // and three Adobe releases with it. `TorrentFile` has already parsed
        // the whole list locally to build the magnet; reading it costs nothing
        // and ninety FLACs is an album whatever the folder is called.
        var contentKind: MediaKind?
        switch item {
        case .torrentFile(let url):
            let parsed: TorrentFile? = self.torrent(fromFileAt: url)
            magnet = parsed?.magnet
            if let parsed {
                contentKind = TorrentContentKind.kind(
                    files: parsed.files.map(\.path), name: parsed.name)
            }
        case .magnet(let raw):
            // A magnet is a hash and a name. There are no files to look at
            // until the debrid has fetched it, so the name is all there is.
            magnet = MagnetLink(raw)
        case .webLink:
            // Not a download yet. Whether a debrid covers the host is a
            // question only Add Link can answer, so the drop opens that rather
            // than guessing here — the same route pasting the URL takes.
            return nil
        }
        guard let magnet else { return nil }

        var result = SearchResult.pastedMagnet(magnet, source: Self.droppedSource)
        if let contentKind {
            var metadata = result.metadata
            metadata.mediaKind = contentKind
            // `.attribute`, like a provider's own statement, because that is
            // what this is: the torrent said what it contains rather than what
            // it is called.
            metadata.provenance[.mediaKind] = .attribute
            result = result.withMetadata(metadata)
        }
        return result
    }

    /// The `sources` entry a hand-added magnet carries.
    ///
    /// **Not shown anywhere.** It used to be rendered on the sheet's facts
    /// line, in the slot an indexer name occupies — telling the user, about a
    /// magnet they had just dropped, that it had been added by hand. It stays
    /// as an id because `SearchResult.sources` is not optional and dedupe keys
    /// on it; `IndexerLabel` and the picker sheet both omit it.
    static let droppedSource = SearchProviderID(rawValue: "manual")

    /// Starts the availability check the pill is waiting on.
    ///
    /// **On the drop, not on the sheet.** The answer comes from the network, so
    /// starting it when the sheet opens means the pill resolves while the user
    /// is already reading the file list. Started here it is usually in by the
    /// time the sheet appears. `CacheStatusStore` dedupes by TTL, so the sheet
    /// asking again costs nothing.
    func beginAvailabilityCheck(for result: SearchResult) {
        guard let magnet = result.magnetURI else { return }
        Task { _ = await availability(forMagnet: magnet) }
    }

    // MARK: - Reporting

    /// One sentence, to whatever is presenting errors.
    ///
    /// `FetchApp` points `ErrorPresenting.current` at the window's `ErrorPanel`,
    /// so the whole alert arrives, action included. The `errorMessage` fallback
    /// stays for the window between launch and that `task` running: it reaches
    /// the same panel through `onChange`, losing only the action, which beats
    /// losing the sentence.
    func report(_ alert: AppAlert) {
        if let presenter = ErrorPresenting.current {
            presenter.present(alert)
            return
        }
        errorMessage = alert.message
    }
}
