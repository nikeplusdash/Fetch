import Foundation

enum NameMatch {
    static func bucket(title: String, query: String) -> Int {
        let queryTokens = tokens(query)
        guard !queryTokens.isEmpty else { return 0 }

        let titleTokens = tokens(title)
        if titleTokens == queryTokens { return 5 }

        switch firstRun(of: queryTokens, in: titleTokens) {
        case 0: return 4
        case .some: return 3
        case nil: break
        }

        let titleSet = Set(titleTokens)
        let present = queryTokens.filter(titleSet.contains).count
        if present == queryTokens.count { return 2 }
        return present > 0 ? 1 : 0
    }

    private static func firstRun(of needle: [String], in haystack: [String]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return start }
        }
        return nil
    }

    private static func tokens(_ string: String) -> [String] {
        string
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
