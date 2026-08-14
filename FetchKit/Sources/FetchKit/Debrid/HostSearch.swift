import Foundation
import FetchPluginAPI

/// Finding one host in a debrid's catalogue.
///
/// Premiumize and TorBox each report several hundred hosts. Settings used to
/// render all of them as sibling rows, which made the pane taller than the
/// window that contains it. The list was never the point: the question a user
/// arrives with is "is *this* host covered?", holding a link they want to
/// paste.
///
/// So the query is matched against the domains too, not just the display name.
/// The two differ often enough to matter — `alterupload.com` is served by the
/// host called "1fichier" — and the string a user has to hand is the one in
/// their clipboard, which may be a whole URL.
public enum HostSearch {
    public static func filter(_ hosts: [DebridHost], matching query: String) -> [DebridHost] {
        let needle = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !needle.isEmpty else { return hosts }

        // Order is the provider's own. Re-sorting on the query would move a
        // host around the list depending on what was typed, so the same
        // lookup twice would look like two different answers.
        return hosts.filter { host in
            if host.displayName.lowercased().contains(needle) { return true }
            if host.domains.contains(where: { $0.lowercased().contains(needle) }) { return true }
            // The needle may be a pasted URL rather than a fragment of one:
            // match the other way round so `https://rapidgator.net/file/abc`
            // still finds `rapidgator.net`. Substring is right here and only
            // here — this decides what a *search field* shows, never what a
            // link is routed to. Routing matches on label boundaries
            // (`DebridHost.serves(_:)`), because there an attacker-chosen
            // `evil-mediafire.com` must not resolve to `mediafire.com`.
            if host.domains.contains(where: { needle.contains($0.lowercased()) }) { return true }
            return false
        }
    }
}
