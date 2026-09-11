import Testing
@testable import FetchKit

@Suite struct NameMatchTests {
    private func bucket(_ title: String, _ query: String) -> Int {
        NameMatch.bucket(title: title, query: query)
    }

    @Test func aReleaseNamedAfterTheQueryBeatsOneThatMerelyMentionsIt() {
        let album = bucket("Dua Lipa - Dance The Night (2023) [24Bit-48kHz] FLAC", "Dua Lipa")
        let episode = bucket("Saturday.Night.Live.S49E18.Dua.Lipa.720p.WEB.h264-EDITH", "Dua Lipa")

        #expect(album > episode)
    }

    @Test func anExactTitleStillWinsOutright() {
        #expect(bucket("Dua Lipa", "dua lipa") > bucket("Dua Lipa - Radical Optimism", "dua lipa"))
    }

    @Test func contiguousBeatsScattered() {
        let contiguous = bucket("The Best of Dua Lipa 2024", "dua lipa")
        let scattered = bucket("Dua Saldana in Lipa City 1080p", "dua lipa")

        #expect(contiguous > scattered)
    }

    @Test func openingWithTheQueryBeatsCarryingItLater() {
        #expect(bucket("Dua Lipa - Levitating", "dua lipa")
                > bucket("The Best of Dua Lipa 2024", "dua lipa"))
    }

    @Test func someTokensBeatsNone() {
        #expect(bucket("Lipa Live 2024", "dua lipa") > bucket("Taylor Swift - Midnights", "dua lipa"))
    }

    @Test func punctuationDoesNotChangeTheBucket() {
        #expect(bucket("Dune.2021.1080p.BluRay", "dune 2021")
                == bucket("Dune (2021) 1080p BluRay", "dune 2021"))
    }

    @Test func matchingIgnoresCaseAndAccents() {
        #expect(bucket("BEYONCÉ - Renaissance", "beyonce") >= 4)
    }

    @Test func anEmptyQueryFlattensEveryResultIntoOneBucket() {
        #expect(bucket("anything at all", "") == bucket("something else", ""))
    }

    @Test func titlesOfVeryDifferentLengthsShareABucketWhenTheyMatchAlike() {
        let short = bucket("Dua Lipa - Levitating", "dua lipa")
        let long = bucket(
            "Dua Lipa - Future Nostalgia (The Moonlight Edition) (2021) [FLAC 24-44]", "dua lipa")

        #expect(short == long, "quality must still have something left to decide")
    }
}
