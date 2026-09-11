import Foundation

/**
 Which player a single click means.

 **One click has to have one meaning.** Playing something used to be
 right-click → "Play in ▸" → pick a player: buried, and it made the user
 answer a question before anything happened. A Play control on the row can
 only exist if "which player" already has an answer, and this is it.

 **The stored choice is an input and never an output.** Every case below is
 resolved on the way *out*; nothing here writes, and the preference is not
 rewritten because a player is missing right now. An app can be missing for
 twenty minutes while it updates, or because it lives on a disk that is not
 plugged in — a preference that repaired itself on the first failed lookup
 would destroy a choice the user made, in response to an event they never
 saw. The fallback stands in for the absent player; it does not take over.
 */
public enum DefaultPlayer {
    /**
     The one key. Read by the Settings row that writes it and by the single
     call site that opens a stream, which are in different files — a typo in
     either is a setting that appears to save and never applies.
     */
    public static let defaultsKey = "defaultExternalPlayer"

    /**
     The player a click should use, given what is stored and what is here.

     Not chosen, unreadable, or chosen and not here all fall back to the first
     installed player, which is what "Play in ▸" already put at the top of its
     menu.

     - Parameters:
       - stored: the raw value of the user's choice, as persisted. Nil, empty
         or unreadable all mean "not chosen", never a failure.
       - installed: the players actually on this Mac, in preference order.
         `AppModel.installedPlayers` asks Launch Services for this.
     - Returns: nil only when there is no player at all, which is a row that
       should not be offering Play.
     */
    public static func resolve(
        stored: String?, installed: [ExternalPlayer]
    ) -> ExternalPlayer? {
        if let stored, let chosen = ExternalPlayer(rawValue: stored),
           installed.contains(chosen) {
            return chosen
        }
        return installed.first
    }

    /**
     One line of the Settings picker.
     */
    public struct Choice: Equatable, Sendable, Identifiable {
        public let player: ExternalPlayer

        /**
         False for the stored choice while its app is not on this Mac.
         */
        public let isInstalled: Bool

        public var id: String { player.rawValue }

        public init(player: ExternalPlayer, isInstalled: Bool) {
            self.player = player
            self.isInstalled = isInstalled
        }

        /**
         What the picker shows. The absent one says so rather than sitting in
         the list looking like any other option.
         */
        public var title: String {
            isInstalled ? player.displayName : "\(player.displayName) (not installed)"
        }
    }

    /**
     What the setting offers: everything installed, plus the stored choice
     when it is not.

     **The absent choice is listed on purpose.** Omitting it would leave the
     picker bound to a selection that is not among its options — which draws
     blank, and the first click on a blank picker is exactly the silent
     overwrite this type exists to prevent.
     */
    public static func choices(
        stored: String?, installed: [ExternalPlayer]
    ) -> [Choice] {
        var choices = installed.map { Choice(player: $0, isInstalled: true) }
        if let stored, let chosen = ExternalPlayer(rawValue: stored),
           !installed.contains(chosen) {
            choices.append(Choice(player: chosen, isInstalled: false))
        }
        return choices
    }

    /**
     What the picker shows as chosen — which is **not** always what a click
     would use.

     A stored choice is shown even while its app is missing, beside the
     `(not installed)` option `choices` keeps for it, and the help line says
     which player is standing in meanwhile. Showing the stand-in instead
     would tell the user their preference had changed, and the next thing
     they do about that is set it again — to the value it already holds.
     */
    public static func selection(
        stored: String?, installed: [ExternalPlayer]
    ) -> ExternalPlayer? {
        if let stored, let chosen = ExternalPlayer(rawValue: stored) { return chosen }
        return resolve(stored: stored, installed: installed)
    }

    /**
     The sentence under the setting's label — three different facts, because
     the three situations are genuinely different and a single line would be
     wrong in two of them.

     With no player at all it is said plainly: an empty picker explains
     nothing, and "install a player" without naming one is advice you cannot
     act on.
     */
    public static func help(stored: String?, installed: [ExternalPlayer]) -> String {
        guard let using = resolve(stored: stored, installed: installed) else {
            return "No player found. Install IINA, VLC, mpv or QuickTime Player "
                + "and Play appears on your rows."
        }
        if let stored, let chosen = ExternalPlayer(rawValue: stored), chosen != using {
            return "\(chosen.displayName) is not on this Mac, so Play uses "
                + "\(using.displayName) meanwhile. Your choice is kept."
        }
        return "Play opens \(using.displayName) — the file on this Mac when it is "
            + "here, a stream from your service when it is not."
    }
}
