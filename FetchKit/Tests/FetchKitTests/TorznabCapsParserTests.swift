import Testing
import Foundation
@testable import FetchKit

@Suite struct TorznabCapsParserTests {
    static let fullCaps = """
    <?xml version="1.0" encoding="UTF-8"?>
    <caps>
      <server version="1.1" title="Jackett" strapline="API endpoint"/>
      <limits max="100" default="50"/>
      <searching>
        <search available="yes" supportedParams="q"/>
        <tv-search available="yes" supportedParams="q,season,ep,tvdbid,rid"/>
        <movie-search available="yes" supportedParams="q,imdbid,genre"/>
        <music-search available="no" supportedParams="q"/>
        <book-search available="no" supportedParams="q"/>
      </searching>
      <categories>
        <category id="2000" name="Movies">
          <subcat id="2010" name="Movies/Foreign"/>
          <subcat id="2040" name="Movies/HD"/>
        </category>
        <category id="5000" name="TV">
          <subcat id="5040" name="TV/HD"/>
        </category>
      </categories>
    </caps>
    """

    static let searchOnlyCaps = """
    <?xml version="1.0" encoding="UTF-8"?>
    <caps>
      <limits max="50"/>
      <searching>
        <search available="yes" supportedParams="q"/>
        <tv-search available="no" supportedParams="q,season,ep"/>
        <movie-search available="no" supportedParams="q,imdbid"/>
      </searching>
      <categories>
        <category id="8000" name="Other"/>
      </categories>
    </caps>
    """

    @Test func parsesSupportedModes() throws {
        let caps = try TorznabCapsParser.parse(Data(Self.fullCaps.utf8))
        #expect(caps.supportedModes == [.search, .tvsearch, .movie])
        #expect(!caps.supportedModes.contains(.music))
        #expect(!caps.supportedModes.contains(.book))
    }

    @Test func indexerAdvertisingOnlySearch() throws {
        let caps = try TorznabCapsParser.parse(Data(Self.searchOnlyCaps.utf8))
        #expect(caps.supportedModes == [.search])
    }

    @Test func parsesMaxLimit() throws {
        let caps = try TorznabCapsParser.parse(Data(Self.fullCaps.utf8))
        #expect(caps.maxLimit == 100)
    }

    @Test func flattensCategoriesIncludingSubcats() throws {
        let caps = try TorznabCapsParser.parse(Data(Self.fullCaps.utf8))
        let ids = Set(caps.categories.map(\.id))
        #expect(ids.isSuperset(of: [2000, 2010, 2040, 5000, 5040]))
        #expect(caps.categories.first(where: { $0.id == 2010 })?.name == "Movies/Foreign")
    }

    @Test func unionsSupportedParamsAcrossModesAsSupportedAttributes() throws {
        let caps = try TorznabCapsParser.parse(Data(Self.fullCaps.utf8))
        #expect(caps.supportedAttributes.isSuperset(of: ["q", "season", "ep", "tvdbid", "rid", "imdbid", "genre"]))
    }

    @Test func malformedXMLSurfacesAsMalformedFeed() {
        let malformed = Data("<caps><categories>".utf8)   // truncated, unclosed
        #expect(throws: SearchError.self) {
            _ = try TorznabCapsParser.parse(malformed)
        }
    }

    @Test func missingLimitsMeansNilMaxLimit() throws {
        let noLimits = """
        <?xml version="1.0"?>
        <caps>
          <searching><search available="yes" supportedParams="q"/></searching>
          <categories><category id="2000" name="Movies"/></categories>
        </caps>
        """
        let caps = try TorznabCapsParser.parse(Data(noLimits.utf8))
        #expect(caps.maxLimit == nil)
    }
}
