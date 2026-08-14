import Foundation
import Testing
import FetchPluginAPI
@testable import FetchKit

/// **No em-dash in a sentence the user reads.**
///
/// Forty-nine string literals carried one when the UI pass started, and every
/// one was a place a sentence had been extended instead of ended. The rule is
/// not punctuation for its own sake: splitting the clause is usually what
/// shortens it, and the app's copy is now short enough that a dash has nowhere
/// to hide.
///
/// It is a test rather than a note in a spec because a style rule that lives in
/// prose survives exactly until the first hurry.
///
/// **What is not in scope, and why.** A bare `—` standing alone in a column is
/// a typographic placeholder for a value that is absent, not a sentence — the
/// designs use one in the rate column themselves. `BookFilename` and
/// `IndexerServerMigration` use one inside a *filename* and a *stored* display
/// name, where changing it would rename files on disk and re-split saved
/// configuration. Those are data, and this is about interface.
@Suite("Microcopy")
struct MicrocopyTests {
    /// Every user-facing sentence this package can be asked for, in one place.
    /// Anything added to the app's vocabulary belongs here too; the point is
    /// that the list is enumerable at all, which it stopped being once the copy
    /// lived in seven views.
    private var everySentence: [String] {
        var strings: [String] = []

        strings += DownloadFilter.allCases.map(\.title)
        strings += DownloadSection.allCases.map(\.title)
        strings += DownloadLibrary.sectionOrder.map { DownloadLibrary.title(for: $0) }
        strings += DownloadLibrary.sectionOrder.flatMap {
            [DownloadRail.noun(for: $0, count: 1), DownloadRail.noun(for: $0, count: 4)]
        }
        strings += AppearanceTheme.allCases.map(\.title)
        strings += WindowCloseBehaviour.allCases.flatMap { [$0.title, $0.detail] }
        strings += SeederLevel.allCases.map(\.accessibilityDescription)
        strings += [CacheReadiness.ready, .noDebridProvider, .noCacheCapableProvider]
            .compactMap(\.searchBannerText)

        // Both branches of every state, so a sub-line that only appears when a
        // fact is missing is checked as well as the one that appears when it is
        // there.
        for state in DownloadState.allCases {
            strings += [
                DownloadSubline.text(DownloadRowFacts(
                    state: state, bytesDownloaded: 30, totalBytes: 100,
                    pinnedUnit: .useBytes, etaText: "2m",
                    failureReason: "The service stopped answering",
                    destination: "Movies/Something", queuePosition: 2,
                    preparingStatus: PreparationProgress(
                        fraction: 0.2, seeds: 3, bytesPerSecond: 100, eta: 60,
                        state: .stalled).statusText)),
                DownloadSubline.text(DownloadRowFacts(state: state)),
            ].compactMap { $0 }
        }

        for state: DebridTorrentState in [
            .queued, .checking, .downloading, .uploading, .stalled, .completed,
            .failed(reason: "the tracker refused it"), .unknown("something else"),
        ] {
            strings.append(PreparationProgress(
                fraction: 0.5, seeds: nil, bytesPerSecond: nil, eta: nil,
                state: state).statusText)
        }

        strings += [
            DownloadRail.activity([]),
            DownloadRail.nothingFailed,
            DownloadRail.activity([.completed]),
            DownloadRail.activity([.downloading, .preparing, .queued, .paused, .failed]),
            DownloadRail.library(count: 0, bytes: 0, kind: nil),
            DownloadRail.library(count: 2, bytes: 2048, kind: .book),
            ServiceRail.text(configured: 0, answering: 0, hasAsked: false),
            ServiceRail.text(configured: 3, answering: 0, hasAsked: false),
            ServiceRail.text(configured: 3, answering: 2, hasAsked: true),
            ServiceRail.text(configured: 3, answering: 3, hasAsked: true),
        ]

        for preferred in [true, false] {
            for reports in [true, false] {
                for enabled in [true, false] {
                    strings.append(DebridRowCopy.help(
                        isPreferred: preferred, reportsCacheStatus: reports,
                        isEnabled: enabled))
                }
            }
        }

        let errors: [DownloadError] = [
            .rangeNotSupported(status: 403), .destinationUnwritable(path: "/tmp/x"),
            .diskFull(needed: 10, available: 1), .sizeMismatch(expected: 2, actual: 1),
            .unsafePath("../x"), .linkExpired, .network("the connection dropped"),
        ]
        strings += errors.compactMap(\.errorDescription)

        let searchFailures: [SearchError] = [
            .unauthorized, .providerTimeout,
            .notATorznabEndpoint(tried: ["http://host/api"]),
        ]
        strings += searchFailures.compactMap(\.errorDescription)

        strings.append(RelativeDay.text(
            for: Date(timeIntervalSince1970: 0),
            now: Date(timeIntervalSince1970: 86_400 * 400)))

        return strings
    }

    @Test("No user-facing sentence contains an em-dash")
    func noEmDashes() {
        for sentence in everySentence {
            #expect(!sentence.contains("—"), "\(sentence)")
        }
    }

    /// The second half of the same rule. A dash was one symptom; the disease
    /// was a sentence that would not end, and the longest of them ran to
    /// ninety-one words in a settings pane.
    ///
    /// Measured per sentence rather than per string, because a few of these
    /// are two or three short ones — an error that names the cause and then the
    /// fix is doing its job, and joining them into one clause is exactly the
    /// move this rule exists to stop.
    @Test("No sentence runs past a readable line")
    func nothingIsAParagraph() {
        for text in everySentence {
            for sentence in text.components(separatedBy: ". ") {
                #expect(sentence.count <= 160, "\(sentence.count): \(sentence)")
            }
        }
    }

    /// The stricter rule, for the strings that end up in the pop-up outside
    /// the window.
    ///
    /// The panel holds **one** sentence and at most one action, and the reason
    /// is not the size of the box: anything needing a paragraph is a state
    /// rather than an event, and a state belongs on the screen it describes.
    /// `CacheReadiness` was shipping three sentences into it — the second and
    /// third explaining a consequence the results table already shows by
    /// dropping its cache column, and naming one of three services as though
    /// it were the reader's.
    ///
    /// Checked here rather than trusted, because the copy is far from the
    /// panel that constrains it and nothing else would notice it growing back.
    @Test("Every alert is one sentence")
    func alertsAreOneSentence() {
        let states: [CacheReadiness] = [.ready, .noDebridProvider, .noCacheCapableProvider]
        for readiness in states {
            guard let text = readiness.searchBannerText else { continue }
            let sentences = text
                .components(separatedBy: ". ")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            #expect(sentences.count == 1, "\(sentences.count) sentences: \(text)")
        }
    }

    /// Nothing here may be blank. An empty label renders as a gap, which reads
    /// as a layout bug rather than as missing copy.
    @Test("Nothing is empty")
    func nothingIsEmpty() {
        for sentence in everySentence {
            #expect(!sentence.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
