import Testing
@testable import FetchKit

/**
 Which player one click means.

 **The interesting case is the player that is not there.** A stored choice
 has to survive its app being uninstalled — moved to an external disk, or
 gone for the twenty minutes an update takes — because rewriting the
 preference the first time Launch Services fails to find a bundle means the
 user's choice is destroyed by an event they did not make and will not see.
 */
@Suite struct DefaultPlayerTests {

    @Test func theStoredChoiceWinsWhenItIsInstalled() {
        #expect(
            DefaultPlayer.resolve(stored: "vlc", installed: [.iina, .vlc, .mpv])
                == .vlc)
    }

    /**
     Nothing has been chosen yet. The first installed player is a better
     answer than refusing to play, and it is the same one the "Play in"
     menu's first item already was.
     */
    @Test func noChoiceYetTakesTheFirstInstalledPlayer() {
        #expect(DefaultPlayer.resolve(stored: nil, installed: [.vlc, .mpv]) == .vlc)
    }

    /**
     **The fallback stands in; it does not take over.** The stored string is
     an input here and never an output — this function cannot rewrite it,
     which is the whole reason the resolution is a function rather than a
     `didSet` that "repairs" the preference. And when IINA comes back, the
     stored choice is still the one used.
     */
    @Test func anUninstalledChoiceFallsBackWithoutBeingReplaced() {
        #expect(DefaultPlayer.resolve(stored: "iina", installed: [.vlc]) == .vlc)
        #expect(DefaultPlayer.resolve(stored: "iina", installed: [.vlc, .iina]) == .iina)
    }

    @Test func nothingInstalledPlaysNothing() {
        #expect(DefaultPlayer.resolve(stored: "vlc", installed: []) == nil)
        #expect(DefaultPlayer.resolve(stored: nil, installed: []) == nil)
    }

    /**
     A defaults key is a string anyone can write. An unreadable value is "no
     choice made", not a crash and not an empty menu.
     */
    @Test func anUnknownIdentifierIsNoChoiceAtAll() {
        #expect(DefaultPlayer.resolve(stored: "winamp", installed: [.mpv]) == .mpv)
        #expect(DefaultPlayer.resolve(stored: "", installed: [.mpv]) == .mpv)
    }

    @Test func theSettingOffersEveryInstalledPlayer() {
        let choices = DefaultPlayer.choices(stored: nil, installed: [.iina, .quickTime])
        #expect(choices.map(\.player) == [.iina, .quickTime])
        #expect(choices.filter(\.isInstalled).count == 2)
    }

    /**
     **The absent choice is still listed, and marked.** Dropping it would
     leave the picker showing a selection that is not among its options —
     which reads as blank, and the first click on a blank picker is what
     would silently overwrite the preference.
     */
    @Test func anUninstalledChoiceIsStillOfferedSoItCanBeKept() {
        let choices = DefaultPlayer.choices(stored: "iina", installed: [.vlc])
        #expect(choices.map(\.player) == [.vlc, .iina])
        #expect(choices.last?.isInstalled == false)
    }

    @Test func anInstalledChoiceIsNotListedTwice() {
        let choices = DefaultPlayer.choices(stored: "vlc", installed: [.vlc, .mpv])
        #expect(choices.map(\.player) == [.vlc, .mpv])
    }

    @Test func anUnknownIdentifierAddsNothingToTheList() {
        #expect(DefaultPlayer.choices(stored: "winamp", installed: [.vlc])
            .map(\.player) == [.vlc])
    }

    /**
     The picker shows the choice, even while it is the one that cannot run.
     Showing the stand-in would say the preference had changed, and the user
     would then set it again to the value it already holds.
     */
    @Test func thePickerShowsTheChoiceRatherThanTheStandIn() {
        #expect(DefaultPlayer.selection(stored: "iina", installed: [.vlc]) == .iina)
        #expect(DefaultPlayer.resolve(stored: "iina", installed: [.vlc]) == .vlc)
    }

    @Test func withNothingChosenThePickerShowsWhatAClickWouldUse() {
        #expect(DefaultPlayer.selection(stored: nil, installed: [.vlc, .mpv]) == .vlc)
        #expect(DefaultPlayer.selection(stored: "winamp", installed: [.vlc]) == .vlc)
        #expect(DefaultPlayer.selection(stored: nil, installed: []) == nil)
    }

    /**
     Said plainly, because a picker with nothing in it explains nothing.
     */
    @Test func theHelpNamesThePlayersToInstallWhenThereAreNone() {
        let help = DefaultPlayer.help(stored: nil, installed: [])
        #expect(help.contains("IINA"))
        #expect(help.contains("VLC"))
        #expect(help.contains("mpv"))
        #expect(help.contains("QuickTime"))
    }

    @Test func theHelpSaysWhichPlayerIsStandingIn() {
        let help = DefaultPlayer.help(stored: "iina", installed: [.vlc])
        #expect(help.contains("IINA"))
        #expect(help.contains("VLC"))
    }

    @Test func theHelpSaysWhatOneClickDoes() {
        let help = DefaultPlayer.help(stored: "vlc", installed: [.vlc])
        #expect(help.contains("VLC"))
        #expect(!help.contains("IINA"))
    }

    /**
     The key is read by the Settings row and by the one place that opens a
     stream, and they are in different files. A typo in either is a setting
     that appears to save and never applies.
     */
    @Test func thePreferenceHasOneKey() {
        #expect(DefaultPlayer.defaultsKey == "defaultExternalPlayer")
    }
}
