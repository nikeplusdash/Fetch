import Foundation
import AppKit
import FetchKit
import FetchPluginAPI

extension AppModel {

    var destinationRoot: URL { downloadDirectory }

    func destinationKey(for result: SearchResult) -> String { result.id.rawValue }

    func ruleSubfolder(for metadata: ReleaseMetadata) -> String {
        subfolder(for: metadata)
    }

    func plannedSubfolder(key: String, metadata: ReleaseMetadata) -> String {
        guard let override = destinationOverrides[key],
              let subfolder = DownloadDestination.subfolder(
                forDestination: override, root: destinationRoot)
        else { return ruleSubfolder(for: metadata) }
        return subfolder
    }

    func destinationReadout(key: String, metadata: ReleaseMetadata) -> DestinationReadout {
        DestinationReadout(
            root: destinationRoot,
            subfolder: plannedSubfolder(key: key, metadata: metadata))
    }

    func hasDestinationOverride(key: String, metadata: ReleaseMetadata) -> Bool {
        plannedSubfolder(key: key, metadata: metadata) != ruleSubfolder(for: metadata)
    }

    func destinationEntries(for metadata: ReleaseMetadata) -> [DestinationMenu.Entry] {
        DestinationMenu.entries(
            ruleSubfolder: ruleSubfolder(for: metadata),
            rules: routingRules)
    }

    func selectedDestinationEntry(
        key: String, metadata: ReleaseMetadata
    ) -> DestinationMenu.Entry {
        .category(subfolder: plannedSubfolder(key: key, metadata: metadata))
    }

    func selectDestination(
        _ entry: DestinationMenu.Entry, key: String, metadata: ReleaseMetadata
    ) {
        switch entry {
        case .category(let subfolder):
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

    func forgetDestinationOverride(key: String) {
        destinationOverrides[key] = nil
    }


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

    private func reportDestinationOutsideRoot(_ chosen: URL) {
        report(
            AppAlert(
                message: "“\(chosen.lastPathComponent)” is outside your download "
                    + "folder. Choose a folder inside it, or change the download "
                    + "folder in Settings.",
                actionTitle: "Open Settings…",
                action: { [weak self] in self?.navigate(to: .organization) }))
    }


    func result(fromDropped item: DroppedItem) -> SearchResult? {
        let magnet: MagnetLink?
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
            magnet = MagnetLink(raw)
        case .webLink:
            return nil
        }
        guard let magnet else { return nil }

        var result = SearchResult.pastedMagnet(magnet, source: Self.droppedSource)
        if let contentKind {
            var metadata = result.metadata
            metadata.mediaKind = contentKind
            metadata.provenance[.mediaKind] = .attribute
            result = result.withMetadata(metadata)
        }
        return result
    }

    static let droppedSource = SearchProviderID(rawValue: "manual")

    func beginAvailabilityCheck(for result: SearchResult) {
        guard let magnet = result.magnetURI else { return }
        Task { _ = await availability(forMagnet: magnet) }
    }


    func report(_ alert: AppAlert) {
        if let presenter = ErrorPresenting.current {
            presenter.present(alert)
            return
        }
        errorMessage = alert.message
    }
}
