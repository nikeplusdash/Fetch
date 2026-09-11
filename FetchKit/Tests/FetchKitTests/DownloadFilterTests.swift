import Testing
@testable import FetchKit

@Suite("Download filters")
struct DownloadFilterTests {
    @Test("Downloads holds everything unfinished that is not on the cloud")
    func downloadsHoldsEverythingUnfinished() {
        for state in DownloadState.allCases where state != .completed && state != .onCloud {
            #expect(DownloadFilter.downloads.accepts(state), "\(state)")
        }
        #expect(!DownloadFilter.downloads.accepts(.completed))
        #expect(!DownloadFilter.downloads.accepts(.onCloud))
    }

    @Test("Library is what landed or lives on the cloud")
    func libraryIsWhatLanded() {
        #expect(DownloadFilter.library.accepts(.completed))
        #expect(DownloadFilter.library.accepts(.onCloud))
        for state in DownloadState.allCases where state != .completed && state != .onCloud {
            #expect(!DownloadFilter.library.accepts(state), "\(state)")
        }
    }

    @Test("Every state is in exactly one pill, and Cloud is in none of them")
    func eachStateHasOneHome() {
        for state in DownloadState.allCases {
            let homes = DownloadFilter.allCases.filter { $0.accepts(state) }
            #expect(homes == [DownloadFilter.downloads] || homes == [DownloadFilter.library],
                    "\(state) -> \(homes)")
        }
    }

    @Test("Clear takes the three dead ends and nothing else")
    func clearableIsTheDeadEnds() {
        #expect(DownloadFilter.isClearable(.failed))
        #expect(DownloadFilter.isClearable(.missing))
        #expect(DownloadFilter.isClearable(.cancelled))
        for state in [DownloadState.queued, .preparing, .downloading, .paused, .completed] {
            #expect(!DownloadFilter.isClearable(state), "\(state)")
        }
    }

    @Test("Cancel takes the four states still in flight and nothing else")
    func cancellableIsWhatIsStillMoving() {
        for state in [DownloadState.queued, .preparing, .downloading, .paused] {
            #expect(DownloadFilter.isCancellable(state), "\(state)")
        }
        for state in [DownloadState.failed, .missing, .cancelled, .completed] {
            #expect(!DownloadFilter.isCancellable(state), "\(state)")
        }
    }

    @Test("Cancel and Clear never both offer to act on the same row")
    func theTwoToolbarButtonsDoNotOverlap() {
        for state in DownloadState.allCases {
            #expect(!(DownloadFilter.isCancellable(state)
                      && DownloadFilter.isClearable(state)), "\(state)")
        }
    }

    @Test("A failed row is Clear's, not Cancel's, even though it can be restarted")
    func failedBelongsToClear() {
        #expect(DownloadFilter.isClearable(.failed))
        #expect(!DownloadFilter.isCancellable(.failed))
        #expect(DownloadState.failed.canBeStarted)
    }

    @Test("Cloud is a category-showing filter that accepts no download state")
    func cloudFilterShape() {
        #expect(DownloadFilter.cloud.title == "Cloud")
        #expect(DownloadFilter.cloud.showsCategories)
        for state in DownloadState.allCases {
            #expect(!DownloadFilter.cloud.accepts(state), "\(state)")
        }
    }

    @Test("the three pills are downloads, library, cloud in that order")
    func pillOrder() {
        #expect(DownloadFilter.allCases.map(\.rawValue) == ["downloads", "library", "cloud"])
    }

    @Test("Only the on-disk list hides categories")
    func onlyDownloadsHidesCategories() {
        #expect(DownloadFilter.library.showsCategories)
        #expect(DownloadFilter.cloud.showsCategories)
        #expect(!DownloadFilter.downloads.showsCategories)
    }
}

@Suite("Appearance themes")
struct AppearanceThemeTests {
    @Test("Only Glass follows the system")
    func onlyGlassFollowsTheSystem() {
        #expect(AppearanceTheme.glass.followsSystemAppearance)
        #expect(!AppearanceTheme.blizzard.followsSystemAppearance)
        #expect(!AppearanceTheme.midnight.followsSystemAppearance)
    }

    @Test("Every theme is named")
    func everyThemeIsNamed() {
        for theme in AppearanceTheme.allCases {
            #expect(!theme.title.isEmpty)
        }
    }
}
