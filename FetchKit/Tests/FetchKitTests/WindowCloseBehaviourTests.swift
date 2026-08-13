import Testing
@testable import FetchKit

@Suite struct WindowCloseBehaviourTests {
    /// Only one of them ends the app. `.ask` in particular must not: the
    /// question is put to the user *instead* of closing, and terminating
    /// would answer it for them.
    @Test func onlyQuitTerminates() {
        let terminating = WindowCloseBehaviour.allCases.filter(\.terminatesOnLastWindowClose)
        #expect(terminating == [.quit])
    }

    /// Raw values are persisted; renaming one silently resets the choice.
    @Test func rawValuesArePersistedAndStable() {
        #expect(WindowCloseBehaviour(rawValue: "ask") == .ask)
        #expect(WindowCloseBehaviour(rawValue: "minimise") == .minimise)
        #expect(WindowCloseBehaviour(rawValue: "background") == .background)
        #expect(WindowCloseBehaviour(rawValue: "quit") == .quit)
    }

    @Test func everyOptionExplainsItself() {
        #expect(WindowCloseBehaviour.allCases.allSatisfy { !$0.detail.isEmpty })
    }
}

@Suite struct ActiveProgressTests {
    private func item(
        _ state: DownloadState, _ downloaded: Int64, _ total: Int64
    ) -> (state: DownloadState, downloaded: Int64, total: Int64) {
        (state: state, downloaded: downloaded, total: total)
    }

    /// Nothing running shows the plain icon. "0%" reads as a stalled
    /// download, which is a different and alarming thing.
    @Test func nothingRunningIsNilRatherThanZero() {
        #expect(ActiveProgress.of([item(.completed, 10, 10)]) == nil)
        #expect(ActiveProgress.of([]) == nil)
    }

    /// By bytes, not by file: a 4 GB remux and a 2 MB cover are not half the
    /// work each.
    @Test func progressIsWeightedByBytes() {
        let progress = ActiveProgress.of([
            item(.downloading, 0, 4_000_000_000),
            item(.downloading, 2_000_000, 2_000_000),
        ])
        #expect((progress?.fraction ?? 1) < 0.01)
    }

    @Test func queuedFilesCountAsWorkStillToDo() {
        let progress = ActiveProgress.of([
            item(.downloading, 50, 100), item(.queued, 0, 100),
        ])
        #expect(progress?.count == 2)
        #expect(progress?.fraction == 0.25)
    }

    /// An unknown total is not zero progress — with nothing to divide by,
    /// "running" is the honest answer.
    @Test func anUnknownTotalDoesNotInventAPercentage() {
        let progress = ActiveProgress.of([item(.downloading, 0, 0)])
        #expect(progress?.count == 1)
        #expect(progress?.fraction == 0)
    }

    @Test func finishedWorkIsNotCountedAsRunning() {
        let progress = ActiveProgress.of([
            item(.downloading, 5, 10), item(.completed, 10, 10), item(.failed, 0, 10),
        ])
        #expect(progress?.count == 1)
    }
}
