import Foundation

/**
 A media player already on the user's Mac, and how to hand it a URL.

 **Streaming is not a download.** The debrid already serves the file over
 HTTPS — `DebridProvider.downloadURL(torrent:file:)` returns exactly that —
 so playing it needs no local copy at all, only a player pointed at the URL.

 Fetch bundles no player, installs none, and scans for none. This is a list
 of things to *ask* the system about by bundle identifier; whether any of
 them is present is the app target's question, because it is `NSWorkspace`'s.
 */
public enum ExternalPlayer: String, CaseIterable, Sendable, Hashable {
    case iina, vlc, mpv, quickTime

    public var displayName: String {
        switch self {
        case .iina: "IINA"
        case .vlc: "VLC"
        case .mpv: "mpv"
        case .quickTime: "QuickTime Player"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .iina: "com.colliderli.iina"
        case .vlc: "org.videolan.vlc"
        case .mpv: "io.mpv"
        case .quickTime: "com.apple.QuickTimePlayerX"
        }
    }

    /**
     What to actually open for a piece of media.

     **IINA is the reason this is a function.** Every other player here is
     opened *with* the media URL — the system hands the app the URL and it
     plays it. IINA instead takes the URL as a query parameter of its own
     `iina://weblink` scheme, which means the media URL has to survive being
     embedded in another URL: its `://`, its slashes, and any `%20` already
     in the filename all have to be escaped, or IINA receives a truncated
     address and opens a player on nothing.

     **Encoded against `.alphanumerics`, not by `URLComponents`.** Setting
     `queryItems` was the obvious spelling and is not enough: `:` and `/` are
     legal inside a query component, so Foundation leaves them alone and the
     media URL sits in IINA's URL with its `https://` intact. That happens to
     round-trip — until the media URL carries a `&`, which every debrid link
     with a signed query does, and everything past it is read as a second
     parameter of IINA's URL rather than as part of the address. Escaping
     everything that is not a letter or a digit cannot be misread.
     */
    public func openTarget(for media: URL) -> URL? {
        switch self {
        case .vlc, .mpv, .quickTime:
            return media
        case .iina:
            guard let encoded = media.absoluteString
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            else { return nil }
            return URL(string: "iina://weblink?url=\(encoded)")
        }
    }

    /**
     Whether this player can be handed a **whole playlist in one open**.

     The route is `NSWorkspace.open(_:withApplicationAt:configuration:)` with
     every URL at once, which is the same thing as dropping twenty files onto
     an app's icon — VLC and mpv both take that as a playlist, wherever the
     URLs point.

     **IINA is the reason this takes a parameter.** Handed files it behaves
     like the others, but a *remote* URL reaches IINA through
     `iina://weblink?url=` — see `openTarget(for:)` — and that scheme carries
     exactly one address. Twenty of them is twenty opens, which is twenty
     windows and no playlist at all. So IINA gets a playlist only when every
     item is already on this Mac.

     **QuickTime never.** It opens a document window per file and has no
     playlist; twenty windows is not the thing the user asked for, so the
     action is not offered for it rather than offered and disappointing.
     */
    public func acceptsPlaylist(allLocalFiles: Bool) -> Bool {
        switch self {
        case .vlc, .mpv: true
        case .iina: allLocalFiles
        case .quickTime: false
        }
    }

    /**
     Whether opening this file in a player is a sensible offer.

     Deliberately narrower than "a debrid can serve it": a Stream button on a
     `.rar` or an `.epub` is a button whose only outcome is a player showing
     an error. The video and audio sets are `SmartFileSelection`'s, which is
     where this app already decides what counts as watchable or listenable —
     one answer, not a second list to keep in step.
     */
    public static func canPlay(fileNamed name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return SmartFileSelection.videoExtensions.contains(ext)
            || SmartFileSelection.audioExtensions.contains(ext)
    }
}
