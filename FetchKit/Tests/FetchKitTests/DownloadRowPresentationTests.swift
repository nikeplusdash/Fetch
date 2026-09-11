import Foundation
import Testing
import FetchPluginAPI
@testable import FetchKit

@Suite("A row's one state")
struct DownloadRowStateTests {
    @Test("No files is not a state")
    func nothingIsNil() {
        #expect(DownloadRowState.of([]) == nil)
    }

    @Test("A transfer still moving outranks a file that already failed")
    func movementOutranksFailure() {
        #expect(DownloadRowState.of([.failed, .downloading]) == .downloading)
        #expect(DownloadRowState.of([.cancelled, .preparing]) == .preparing)
        #expect(DownloadRowState.of([.missing, .paused]) == .paused)
    }

    @Test("One file that did not land keeps the row out of Completed")
    func oneFailureIsNotCompleted() {
        #expect(DownloadRowState.of([.completed, .completed, .cancelled]) == .cancelled)
        #expect(DownloadRowState.of([.completed, .failed]) == .failed)
    }

    @Test("All landed is completed")
    func everythingLanded() {
        #expect(DownloadRowState.of([.completed, .completed]) == .completed)
    }

    @Test("An all-cloud group reads as cloud, not completed")
    func anAllCloudGroupIsNotCompleted() {
        #expect(DownloadRowState.of([.cloudQueued]) == .cloudQueued)
        #expect(DownloadRowState.of([.onCloud, .onCloud]) == .onCloud)
        #expect(DownloadRowState.of([.onCloud, .cloudQueued]) == .cloudQueued)
    }

    @Test("A real state alongside a cloud one is not collapsed to cloud")
    func aRealStateOutranksACloudOne() {
        #expect(DownloadRowState.of([.onCloud, .downloading]) == .downloading)
        #expect(DownloadRowState.of([.onCloud, .failed]) == .failed)
    }

    @Test("It agrees with the section the same files land in")
    func itAgreesWithGrouping() {
        let combinations: [[DownloadState]] = [
            [.downloading], [.queued], [.completed], [.failed], [.missing],
            [.cancelled], [.paused], [.preparing],
            [.downloading, .failed], [.completed, .cancelled],
            [.queued, .completed], [.paused, .queued], [.missing, .completed],
        ]
        for states in combinations {
            guard let row = DownloadRowState.of(states),
                  let section = DownloadGrouping.section(for: states)
            else { Issue.record("no answer for \(states)"); continue }
            let expected: DownloadSection = switch row {
            case .downloading, .preparing, .paused: .active
            case .queued: .queued
            case .failed, .missing, .cancelled: .failed
            case .completed, .cloudQueued, .onCloud: .completed
            }
            #expect(section == expected, "\(states)")
        }
    }
}

@Suite("A row's one sub-line")
struct DownloadSublineTests {
    private let locale = Locale(identifier: "en_US")

    @Test("Running says how far and how long, and nothing else")
    func runningSaysProgress() {
        let text = DownloadSubline.text(DownloadRowFacts(
            state: .downloading,
            bytesDownloaded: 3_328_599_654, totalBytes: 4_724_464_025,
            pinnedUnit: .useGB, etaText: "2m"), locale: locale)
        #expect(text == "3.1 of 4.4 GB, 2m left")
    }

    @Test("The shared unit appears once")
    func theUnitIsNotRepeated() {
        let text = DownloadSubline.text(DownloadRowFacts(
            state: .downloading,
            bytesDownloaded: 3_328_599_654, totalBytes: 4_724_464_025,
            pinnedUnit: .useGB), locale: locale)
        #expect(text == "3.1 of 4.4 GB")
    }

    @Test("A stalled transfer drops the ETA rather than inventing one")
    func noRateNoETA() {
        let text = DownloadSubline.text(DownloadRowFacts(
            state: .downloading, bytesDownloaded: 100, totalBytes: 200,
            pinnedUnit: .useBytes, etaText: nil), locale: locale)
        #expect(text?.contains("left") == false)
    }

    @Test("Queued says where in the line, or says it does not know")
    func queuedSaysPosition() {
        #expect(DownloadSubline.text(
            DownloadRowFacts(state: .queued, queuePosition: 3), locale: locale)
            == "3rd in line")
        #expect(DownloadSubline.text(
            DownloadRowFacts(state: .queued, queuePosition: nil), locale: locale)
            == "Waiting for a free slot.")
        #expect(DownloadSubline.text(
            DownloadRowFacts(state: .queued, queuePosition: 0), locale: locale)
            == "Waiting for a free slot.")
    }

    @Test("Failed says the reason and the way out")
    func failedSaysWhyAndWhatNext() {
        let text = DownloadSubline.text(DownloadRowFacts(
            state: .failed, failureReason: "Gutenberg stopped responding"),
            locale: locale)
        #expect(text == "Gutenberg stopped responding. Try again")
    }

    @Test("A punctuated reason keeps its punctuation")
    func punctuationIsNotDoubled() {
        let text = DownloadSubline.text(DownloadRowFacts(
            state: .failed, failureReason: "The link expired."), locale: locale)
        #expect(text == "The link expired. Try again")
    }

    @Test("A failure with no recorded reason still says what to do")
    func failedWithoutAReason() {
        let text = DownloadSubline.text(
            DownloadRowFacts(state: .failed, failureReason: ""), locale: locale)
        #expect(text == "It did not finish. Try again.")
    }

    @Test("Finished says nothing, whatever it knows")
    func completedSaysNothing() {
        #expect(DownloadSubline.text(
            DownloadRowFacts(state: .completed, destination: "Movies/Nosferatu (1922)"),
            locale: locale) == nil)
        #expect(DownloadSubline.text(
            DownloadRowFacts(state: .completed), locale: locale) == nil)
    }

    @Test("Missing says the one thing that is true about it")
    func missingIsShort() {
        #expect(DownloadSubline.text(DownloadRowFacts(state: .missing), locale: locale)
                == "Not where Fetch saved it.")
    }

    @Test("Stopped says how far it got, and does not divide by zero")
    func cancelledSaysHowFar() {
        #expect(DownloadSubline.text(DownloadRowFacts(
            state: .cancelled, bytesDownloaded: 12, totalBytes: 100), locale: locale)
            == "Stopped at 12%")
        #expect(DownloadSubline.text(DownloadRowFacts(
            state: .cancelled, bytesDownloaded: 12, totalBytes: 0), locale: locale)
            == "You stopped this.")
    }

    @Test("Preparing prefers the service's own words")
    func preparingQuotesTheService() {
        #expect(DownloadSubline.text(DownloadRowFacts(
            state: .preparing, preparingStatus: "TorBox is fetching it. 22%"),
            locale: locale) == "TorBox is fetching it. 22%")
        #expect(DownloadSubline.text(DownloadRowFacts(state: .preparing), locale: locale)
                == "Your debrid service is fetching it.")
    }

    @Test("A ready cloud row has no second line")
    func onCloudSaysNothing() {
        #expect(DownloadSubline.text(DownloadRowFacts(state: .onCloud), locale: locale) == nil)
    }

    @Test("A queued cloud row says the service is fetching it")
    func cloudQueuedSaysTheServiceIsFetching() {
        #expect(DownloadSubline.text(DownloadRowFacts(state: .cloudQueued), locale: locale)
                == "Your debrid service is fetching this.")
    }

    @Test("A volunteered diagnosis wins over the waiting sentence")
    func cloudQueuedPrefersTheDiagnosis() {
        #expect(DownloadSubline.text(DownloadRowFacts(
            state: .cloudQueued,
            cloudDiagnosis: "Nobody is seeding this torrent, so your service could not fetch it."),
            locale: locale)
            == "Nobody is seeding this torrent, so your service could not fetch it.")
    }

    @Test("Every state has an answer, even if it is deliberately nothing")
    func everyStateIsHandled() {
        for state in DownloadState.allCases {
            _ = DownloadSubline.text(DownloadRowFacts(state: state), locale: locale)
        }
    }
}

@Suite("The rail")
struct DownloadRailTests {
    @Test("It names the mix, in a fixed order")
    func activityNamesTheMix() {
        let text = DownloadRail.activity(
            [.downloading, .preparing, .failed, .completed, .completed])
        #expect(text == "1 downloading, 1 preparing, 1 need attention")
    }

    @Test("Failed, missing and cancelled are one phrase")
    func theUnhappyEndingsAreOnePhrase() {
        #expect(DownloadRail.activity([.failed, .missing, .cancelled])
                == "3 need attention")
    }

    @Test("An empty Failed pill has its own line")
    func nothingFailedIsNotNothingAtAll() {
        #expect(DownloadRail.nothingFailed != DownloadRail.activity([]))
    }

    @Test("A shelf of finished downloads is not running anything")
    func nothingRunning() {
        #expect(DownloadRail.activity([.completed, .completed]) == "Nothing running")
        #expect(DownloadRail.activity([]) == "No downloads queued")
    }

    @Test("The library says how much of what")
    func librarySaysWhatIsThere() {
        #expect(DownloadRail.library(count: 2, bytes: 1_019_904, kind: .book)
                == "2 books, 996 KB")
        #expect(DownloadRail.library(count: 1, bytes: 1_019_904, kind: .book)
                == "1 book, 996 KB")
        #expect(DownloadRail.library(count: 0, bytes: 0, kind: nil) == "Nothing here yet")
    }

    @Test("Kinds with no plural keep their spelling")
    func awkwardPluralsAreSpelledOut() {
        #expect(DownloadRail.noun(for: .anime, count: 1) == "anime")
        #expect(DownloadRail.noun(for: .anime, count: 4) == "anime")
        #expect(DownloadRail.noun(for: .software, count: 3) == "software")
        #expect(DownloadRail.noun(for: .tv, count: 2) == "TV shows")
    }
}

@Suite("Settings' rail")
struct ServiceRailTests {
    @Test("It does not report an answer before anything has asked")
    func silenceBeforeTheAsk() {
        #expect(ServiceRail.text(configured: 3, answering: 0, hasAsked: false)
                == "Checking your services")
    }

    @Test("It counts what answered")
    func itCountsAnswers() {
        #expect(ServiceRail.text(configured: 3, answering: 2, hasAsked: true)
                == "2 of 3 services answering")
        #expect(ServiceRail.text(configured: 3, answering: 3, hasAsked: true)
                == "3 services answering")
        #expect(ServiceRail.text(configured: 1, answering: 1, hasAsked: true)
                == "1 service answering")
    }

    @Test("With nothing configured it says so, asked or not")
    func nothingConfigured() {
        #expect(ServiceRail.text(configured: 0, answering: 0, hasAsked: true)
                == "No debrid service yet")
        #expect(ServiceRail.text(configured: 0, answering: 0, hasAsked: false)
                == "No debrid service yet")
    }
}

@Suite("Where a download landed")
struct RelativeFolderTests {
    @Test("It says the folders between the root and the file")
    func itSaysTheFolders() {
        let root = URL(fileURLWithPath: "/Users/someone/Downloads")
        let file = URL(fileURLWithPath:
            "/Users/someone/Downloads/Movies/Nosferatu (1922)/nosferatu.mkv")
        #expect(RelativeFolder.text(of: file, under: root) == "Movies/Nosferatu (1922)")
    }

    @Test("A file sitting in the root has nothing worth saying")
    func directlyInTheRoot() {
        let root = URL(fileURLWithPath: "/Users/someone/Downloads")
        #expect(RelativeFolder.text(
            of: root.appendingPathComponent("loose.mkv"), under: root) == nil)
    }

    @Test("A sibling folder with the same prefix is not inside the root")
    func aPrefixIsNotAParent() {
        let root = URL(fileURLWithPath: "/Users/someone/Downloads")
        let file = URL(fileURLWithPath: "/Users/someone/Downloads2/Movies/x.mkv")
        #expect(RelativeFolder.text(of: file, under: root) == "Movies")
    }
}

@Suite("Debrid row copy")
struct DebridRowCopyTests {
    @Test("The top row explains that it is the top row")
    func preferenceIsExplained() {
        #expect(DebridRowCopy.help(
            isPreferred: true, reportsCacheStatus: true, isEnabled: true)
            .hasPrefix("Preferred."))
    }

    @Test("A service that cannot report cache status always says so")
    func cacheSilenceIsAlwaysStated() {
        for preferred in [true, false] {
            let help = DebridRowCopy.help(
                isPreferred: preferred, reportsCacheStatus: false, isEnabled: true)
            #expect(help.contains("cached status"))
        }
    }

    @Test("A disabled service says that first, whatever else is true of it")
    func offOutranksEverything() {
        for preferred in [true, false] {
            for reports in [true, false] {
                #expect(DebridRowCopy.help(
                    isPreferred: preferred, reportsCacheStatus: reports, isEnabled: false)
                    .hasPrefix("Off."))
            }
        }
    }
}

@Suite("Closing the window")
struct WindowCloseBinaryTests {
    @Test("Only Quit stops the downloads")
    func onlyQuitStops() {
        #expect(!WindowCloseBehaviour.quit.keepsDownloading)
        for behaviour in WindowCloseBehaviour.allCases where behaviour != .quit {
            #expect(behaviour.keepsDownloading)
        }
    }

    @Test("The switch writes a case that means what it says")
    func theSwitchRoundTrips() {
        #expect(WindowCloseBehaviour(keepsDownloading: true) == .background)
        #expect(WindowCloseBehaviour(keepsDownloading: false) == .quit)
        #expect(WindowCloseBehaviour(keepsDownloading: true).keepsDownloading)
        #expect(!WindowCloseBehaviour(keepsDownloading: false).keepsDownloading)
    }


    @Test("A finished row has no sub-line at all")
    func aFinishedRowIsOneLine() {
        #expect(DownloadSubline.text(
            DownloadRowFacts(state: .completed, destination: "Movies/Nosferatu (1922)")) == nil)
        #expect(DownloadSubline.text(DownloadRowFacts(state: .completed)) == nil)
    }

    @Test("Every other state still has its one fact")
    func otherStatesKeepTheirSubline() {
        #expect(DownloadSubline.text(DownloadRowFacts(state: .queued)) != nil)
        #expect(DownloadSubline.text(DownloadRowFacts(state: .missing)) != nil)
        #expect(DownloadSubline.text(DownloadRowFacts(state: .failed)) != nil)
    }


    @Test("More answers than services is clamped, not printed")
    func moreAnswersThanServicesIsClamped() {
        #expect(ServiceRail.text(configured: 1, answering: 3, hasAsked: true)
                == "1 service answering")
    }

    @Test("A partial answer still reads as partial")
    func aPartialAnswerSurvives() {
        #expect(ServiceRail.text(configured: 3, answering: 1, hasAsked: true)
                == "1 of 3 services answering")
    }

    @Test("No service is said before anything is counted")
    func noServiceComesFirst() {
        #expect(ServiceRail.text(configured: 0, answering: 3, hasAsked: true)
                == "No debrid service yet")
    }


    @Test("A service that said no is down, not up")
    func aRefusedServiceIsDown() {
        #expect(ServiceHealth.failed(reason: "Unauthorized").dot(isEnabled: true) == .down)
        #expect(!ServiceHealth.failed(reason: "Unauthorized").isOK)
    }

    @Test("Not yet asked is neither up nor down")
    func unaskedIsWaiting() {
        #expect(ServiceHealth.unknown.dot(isEnabled: true) == .waiting)
        #expect(ServiceHealth.checking.dot(isEnabled: true) == .waiting)
        #expect(!ServiceHealth.unknown.hasAnswered)
        #expect(!ServiceHealth.checking.hasAnswered)
    }

    @Test("A service that answered is up, whatever its plan says")
    func anAnsweringServiceIsUp() {
        #expect(ServiceHealth.ok(plan: nil).dot(isEnabled: true) == .up)
        #expect(ServiceHealth.ok(plan: "Pro").isOK)
        #expect(ServiceHealth.ok(plan: nil).hasAnswered)
    }

    @Test("Disabled is off however it last answered")
    func disabledIsOff() {
        #expect(ServiceHealth.ok(plan: "Pro").dot(isEnabled: false) == .off)
        #expect(ServiceHealth.failed(reason: "no").dot(isEnabled: false) == .off)
    }

    @Test("A failure keeps its reason for the row to say")
    func aFailureKeepsItsReason() {
        #expect(ServiceHealth.failed(reason: "Unauthorized").failureText == "Unauthorized")
        #expect(ServiceHealth.ok(plan: "Pro").failureText == nil)
    }
}
