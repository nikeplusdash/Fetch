/**
 Which pill the window opens on.

 Nothing downloading means the useful thing to show is what the user
 already has — the Library — not an empty in-flight list. Something
 downloading means the opposite, and it is the thing they opened the app
 to look at.

 Never Cloud: that pill fetches from every configured service when it is
 first shown, and opening there would put three network calls in front of
 a launch nobody asked to spend them on.

 The section is always Downloads; only the pill turns, which is why this
 returns a `DownloadFilter` and the app supplies the section — the app's
 `SidebarSection` is not FetchKit's to know.
 */
public enum LaunchLanding {
    public static func filter(hasActiveDownloads: Bool) -> DownloadFilter {
        hasActiveDownloads ? .downloads : .library
    }
}
