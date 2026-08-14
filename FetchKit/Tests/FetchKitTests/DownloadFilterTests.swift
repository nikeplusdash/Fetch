import Testing
@testable import FetchKit

@Suite("Download filters")
struct DownloadFilterTests {
    /// Two pills, not three. Failed was its own, which made the row a
    /// lifecycle diagram — and a failure is not a category of thing to browse,
    /// it is something in the way of what you asked for.
    @Test("Downloads holds everything that has not landed")
    func downloadsHoldsEverythingUnfinished() {
        for state in DownloadState.allCases where state != .completed {
            #expect(DownloadFilter.downloads.accepts(state), "\(state)")
        }
        #expect(!DownloadFilter.downloads.accepts(.completed))
    }

    @Test("Library is what landed, and only that")
    func libraryIsWhatLanded() {
        #expect(DownloadFilter.library.accepts(.completed))
        for state in DownloadState.allCases where state != .completed {
            #expect(!DownloadFilter.library.accepts(state), "\(state)")
        }
    }

    /// Every state reaches exactly one pill. A state in neither is a download
    /// that exists and cannot be seen; a state in both is a row shown twice.
    @Test("Every state is in exactly one pill")
    func eachStateHasOneHome() {
        for state in DownloadState.allCases {
            let homes = DownloadFilter.allCases.filter { $0.accepts(state) }
            #expect(homes.count == 1, "\(state) -> \(homes)")
        }
    }

    /// Clear acts on the three ways a download ends with no file to show for
    /// it. Paused is not one: it is stopped, not over.
    @Test("Clear takes the three dead ends and nothing else")
    func clearableIsTheDeadEnds() {
        #expect(DownloadFilter.isClearable(.failed))
        #expect(DownloadFilter.isClearable(.missing))
        #expect(DownloadFilter.isClearable(.cancelled))
        for state in [DownloadState.queued, .preparing, .downloading, .paused, .completed] {
            #expect(!DownloadFilter.isClearable(state), "\(state)")
        }
    }

    @Test("Only the Library shows categories")
    func onlyLibraryShowsCategories() {
        #expect(DownloadFilter.library.showsCategories)
        #expect(!DownloadFilter.downloads.showsCategories)
    }
}

@Suite("Appearance themes")
struct AppearanceThemeTests {
    /// Glass is a lens and defers; the other two are materials and state their
    /// own value. Plan 3 leans on this to decide whether to pin
    /// `NSApp.appearance`.
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
