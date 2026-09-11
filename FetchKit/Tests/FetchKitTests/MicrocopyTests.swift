import Foundation
import Testing
import FetchPluginAPI
@testable import FetchKit

@Suite("Microcopy")
struct MicrocopyTests {
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

    @Test("No sentence runs past a readable line")
    func nothingIsAParagraph() {
        for text in everySentence {
            for sentence in text.components(separatedBy: ". ") {
                #expect(sentence.count <= 160, "\(sentence.count): \(sentence)")
            }
        }
    }

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

    @Test("Nothing is empty")
    func nothingIsEmpty() {
        for sentence in everySentence {
            #expect(!sentence.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
