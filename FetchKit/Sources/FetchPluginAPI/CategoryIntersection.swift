import Foundation

/**
 Reconciles the categories a search asks for with the ones an indexer says
 it carries.

 Sending a category an indexer does not have returns an empty answer, which
 the user reads as the indexer having failed. Skipping it instead is honest,
 and — because the skipped provider never joins the fan-out — keeps
 "3 of 3 indexers" from reading as though four were asked and one died.
 */
public enum CategoryIntersection {
    public enum Resolution: Equatable, Sendable {
        case sendVerbatim
        case send([Int])
        case skip
    }

    public static func resolve(
        requested: [TorznabCategory], advertised: [TorznabCategory]
    ) -> Resolution {
        guard !requested.isEmpty, !advertised.isEmpty else { return .sendVerbatim }

        let wanted = requested.map(\.id)
        let covered = Set(advertised.map(\.id).filter { advertisedID in
            wanted.contains { covers(advertised: advertisedID, requested: $0) }
        })
        return covered.isEmpty ? .skip : .send(covered.sorted())
    }

    static func covers(advertised: Int, requested: Int) -> Bool {
        if advertised == requested { return true }
        guard requested % 1000 == 0 else { return false }
        return advertised / 1000 == requested / 1000
    }
}
