import Foundation

/**
 One thing a row can be asked to do.

 `.play`, `.open` and `.showInFinder` are produced for a cloud row but have
 no reader yet — they are the affordances a later streaming/local-file pass
 will render, declared here so that pass changes only its call sites (the
 same forward-declaration pattern as `ResultOrigin.targetPath`).
 */
public enum RowAction: String, Sendable, CaseIterable {
    case play, open, showInFinder, openOnService, download, skip, cancel, remove
}

/**
 Which of those a given row actually offers.

 A function, because the menu is a combination and combinations are where
 the wrong item appears. The view built this from three inline conditions;
 cloud rows take it to seven, and the failure mode — Show in Finder on a
 row with no file, Skip on a finished one — is the kind nobody reports
 because it looks deliberate. The app target has no test bundle, so left in
 the view this could not be asserted at all.
 */
public enum RowActions {
    public static func available(
        for state: DownloadState, hasLocalFile: Bool, isPlayable: Bool
    ) -> [RowAction] {
        var actions: [RowAction] = []

        if isPlayable, hasLocalFile || state.isCloudReady { actions.append(.play) }

        if hasLocalFile {
            actions.append(.open)
            actions.append(.showInFinder)
        }

        if state.isCloudOnly { actions.append(.openOnService) }

        switch state {
        case .completed where !hasLocalFile: actions.append(.download)
        case .onCloud, .failed, .cancelled, .missing: actions.append(.download)
        case .queued, .preparing, .downloading: actions.append(.skip)
        case .cloudQueued: actions.append(.cancel)
        case .paused: break
        case .completed: break
        }

        actions.append(.remove)
        return actions
    }
}
