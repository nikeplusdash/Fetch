import Testing
@testable import FetchKit

/// Relevance, as the coarse buckets the ranking sorts on first.
@Suite struct NameMatchTests {
    private func bucket(_ title: String, _ query: String) -> Int {
        NameMatch.bucket(title: title, query: query)
    }

    /// **The reported regression.** A search for "dua lipa" put an SNL episode
    /// she appeared on above her own records. Both titles contain both tokens,
    /// so both sat in one bucket, and the tie went to per-kind quality and
    /// popularity — where a 720p WEB-DL of a talk show beats a FLAC release
    /// comfortably. The ranking was working; it had been given no reason to
    /// prefer the record over the episode.
    @Test func aReleaseNamedAfterTheQueryBeatsOneThatMerelyMentionsIt() {
        let album = bucket("Dua Lipa - Dance The Night (2023) [24Bit-48kHz] FLAC", "Dua Lipa")
        let episode = bucket("Saturday.Night.Live.S49E18.Dua.Lipa.720p.WEB.h264-EDITH", "Dua Lipa")

        #expect(album > episode)
    }

    @Test func anExactTitleStillWinsOutright() {
        #expect(bucket("Dua Lipa", "dua lipa") > bucket("Dua Lipa - Radical Optimism", "dua lipa"))
    }

    /// Contiguous but not first still beats scattered: "Best of Dua Lipa" is
    /// about her, "Dua Something Lipa" is a coincidence.
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

    /// Dots, brackets and spaces tokenize alike — release names are
    /// dot-separated far more often than they are spaced.
    @Test func punctuationDoesNotChangeTheBucket() {
        #expect(bucket("Dune.2021.1080p.BluRay", "dune 2021")
                == bucket("Dune (2021) 1080p BluRay", "dune 2021"))
    }

    @Test func matchingIgnoresCaseAndAccents() {
        #expect(bucket("BEYONCÉ - Renaissance", "beyonce") >= 4)
    }

    /// An empty query is a browse, not a search: nothing to rank on, so the
    /// composite quality score becomes the effective key.
    @Test func anEmptyQueryFlattensEveryResultIntoOneBucket() {
        #expect(bucket("anything at all", "") == bucket("something else", ""))
    }

    /// The buckets stay discrete on purpose. A continuous relevance float
    /// never ties, so it would silently become the only sort key and every
    /// per-kind quality ranking under it would do nothing observable.
    @Test func titlesOfVeryDifferentLengthsShareABucketWhenTheyMatchAlike() {
        let short = bucket("Dua Lipa - Levitating", "dua lipa")
        let long = bucket(
            "Dua Lipa - Future Nostalgia (The Moonlight Edition) (2021) [FLAC 24-44]", "dua lipa")

        #expect(short == long, "quality must still have something left to decide")
    }
}
