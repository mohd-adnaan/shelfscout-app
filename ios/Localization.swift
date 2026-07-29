import Foundation

/// Language the native guidance layer speaks in.
///
/// Mirrors `AppLanguage` in `src/i18n/languages.ts`. React Native owns the
/// setting and passes it down with each navigation/reaching session config;
/// native never reads the system locale, because the app language is a user
/// choice that deliberately overrides it (a Quebec user may run an English
/// iPhone and still want French guidance).
enum AppLanguage: String {
    case en
    case fr

    /// Tolerant parse for the bridged value: accepts "fr", "fr-CA", "FR_ca".
    /// Anything unrecognised falls back to English rather than crashing a
    /// live navigation session.
    init(code: String?) {
        guard let code, !code.isEmpty else {
            self = .en
            return
        }
        let primary = code
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
        self = AppLanguage(rawValue: primary) ?? .en
    }

    /// BCP-47 tag for AVSpeechSynthesisVoice.
    var speechLocale: String {
        switch self {
        case .en: return "en-US"
        case .fr: return "fr-CA"
        }
    }
}

/// Process-wide current language for native speech.
///
/// Set from the bridge before a session starts. A global rather than an
/// injected dependency because the spoken-phrase helpers are `static` on
/// SemanticRouteNavigator and are called from deep inside geometry code;
/// threading a language parameter through every call site would be far more
/// invasive than this for no behavioural gain.
enum AppLocale {
    private static let queue = DispatchQueue(label: "com.shelfscout.applocale")
    private static var _current: AppLanguage = .en

    static var current: AppLanguage {
        get { queue.sync { _current } }
        set { queue.sync { _current = newValue } }
    }
}

/// Spoken guidance strings, per language.
///
/// Every entry returns a COMPLETE phrase. Do not build sentences by
/// concatenating fragments across languages: English composes
/// "Turn right" + " to face the route", but French needs
/// « Tournez à droite pour faire face au trajet », where the verb and the
/// preposition are bound together. Fragment-splicing is exactly how machine
/// translation of navigation apps ends up unintelligible.
///
/// Keep in sync with `src/i18n/strings/*.ts` when a phrase is shared.
enum NavLoc {
    private static var lang: AppLanguage { AppLocale.current }

    // ── Turn hints (recorded during capture) ────────────────────────────────

    static func turnLeft() -> String {
        switch lang {
        case .en: return "turn left"
        case .fr: return "tournez à gauche"
        }
    }

    static func turnRight() -> String {
        switch lang {
        case .en: return "turn right"
        case .fr: return "tournez à droite"
        }
    }

    static func continueStraight() -> String {
        switch lang {
        case .en: return "continue straight"
        case .fr: return "continuez tout droit"
        }
    }

    static func followCorner() -> String {
        switch lang {
        case .en: return "follow the corner"
        case .fr: return "suivez le coin"
        }
    }

    static func slightLeftAtCorner() -> String {
        switch lang {
        case .en: return "take a slight left at the corner"
        case .fr: return "prenez légèrement à gauche au coin"
        }
    }

    static func slightRightAtCorner() -> String {
        switch lang {
        case .en: return "take a slight right at the corner"
        case .fr: return "prenez légèrement à droite au coin"
        }
    }

    static func slightLeft() -> String {
        switch lang {
        case .en: return "take a slight left"
        case .fr: return "prenez légèrement à gauche"
        }
    }

    static func slightRight() -> String {
        switch lang {
        case .en: return "take a slight right"
        case .fr: return "prenez légèrement à droite"
        }
    }

    static func turnSharpLeft() -> String {
        switch lang {
        case .en: return "turn sharp left"
        case .fr: return "tournez franchement à gauche"
        }
    }

    static func turnSharpRight() -> String {
        switch lang {
        case .en: return "turn sharp right"
        case .fr: return "tournez franchement à droite"
        }
    }

    static func turnAroundFragment() -> String {
        switch lang {
        case .en: return "turn around"
        case .fr: return "faites demi-tour"
        }
    }

    static func clockFragment(hour: Int) -> String {
        switch lang {
        case .en: return "turn to \(hour) o'clock"
        // "heures" is plural for every hour except 1 in this construction.
        case .fr: return "tournez vers \(hour) heure\(hour == 1 ? "" : "s")"
        }
    }

    // ── Turn commands (complete sentences) ──────────────────────────────────

    static func goStraight() -> String {
        switch lang {
        case .en: return "Go straight."
        case .fr: return "Allez tout droit."
        }
    }

    static func turnLeftCommand() -> String {
        switch lang {
        case .en: return "Turn left."
        case .fr: return "Tournez à gauche."
        }
    }

    static func turnRightCommand() -> String {
        switch lang {
        case .en: return "Turn right."
        case .fr: return "Tournez à droite."
        }
    }

    static func turnSharpLeftCommand() -> String {
        switch lang {
        case .en: return "Turn sharp left."
        case .fr: return "Tournez franchement à gauche."
        }
    }

    static func turnSharpRightCommand() -> String {
        switch lang {
        case .en: return "Turn sharp right."
        case .fr: return "Tournez franchement à droite."
        }
    }

    static func turnAroundCommand() -> String {
        switch lang {
        case .en: return "Turn around."
        case .fr: return "Faites demi-tour."
        }
    }

    static func clockCommand(hour: Int) -> String {
        switch lang {
        case .en: return "Turn to \(hour) o'clock."
        case .fr: return "Tournez vers \(hour) heure\(hour == 1 ? "" : "s")."
        }
    }

    // ── Recovery nudges ─────────────────────────────────────────────────────

    static func forward() -> String {
        switch lang {
        case .en: return "Forward"
        case .fr: return "Avancez"
        }
    }

    static func stepLeft() -> String {
        switch lang {
        case .en: return "Step left"
        case .fr: return "Décalez-vous à gauche"
        }
    }

    static func stepRight() -> String {
        switch lang {
        case .en: return "Step right"
        case .fr: return "Décalez-vous à droite"
        }
    }

    static func turnLeftNudge() -> String {
        switch lang {
        case .en: return "Turn left"
        case .fr: return "Tournez à gauche"
        }
    }

    static func turnRightNudge() -> String {
        switch lang {
        case .en: return "Turn right"
        case .fr: return "Tournez à droite"
        }
    }

    static func turnAroundNudge() -> String {
        switch lang {
        case .en: return "Turn around"
        case .fr: return "Faites demi-tour"
        }
    }

    static func clockNudge(hour: Int) -> String {
        switch lang {
        case .en: return "Head to \(hour) o'clock"
        case .fr: return "Dirigez-vous vers \(hour) heure\(hour == 1 ? "" : "s")"
        }
    }

    /// Nudge with an optional trailing distance: "Step right, 2 meters."
    static func nudgeWithDistance(_ nudge: String, distance: String?) -> String {
        guard let distance else { return "\(nudge)." }
        switch lang {
        case .en: return "\(nudge), \(distance)."
        case .fr: return "\(nudge), \(distance)."
        }
    }

    static func wrongDirection() -> String {
        switch lang {
        case .en: return "Wrong direction."
        case .fr: return "Mauvaise direction."
        }
    }

    static func offRoute() -> String {
        switch lang {
        case .en: return "Off route."
        case .fr: return "Vous avez quitté le trajet."
        }
    }

    static func scanSlowly() -> String {
        switch lang {
        case .en: return "Scan slowly."
        case .fr: return "Balayez lentement avec la caméra."
        }
    }

    static func slowDown() -> String {
        switch lang {
        case .en: return "Slow down."
        case .fr: return "Ralentissez."
        }
    }

    // ── Route alignment ─────────────────────────────────────────────────────

    static func faceTheRoute() -> String {
        switch lang {
        case .en: return "Face the route."
        case .fr: return "Placez-vous face au trajet."
        }
    }

    static func turnAroundToFaceRoute() -> String {
        switch lang {
        case .en: return "Turn around to face the route."
        case .fr: return "Faites demi-tour pour faire face au trajet."
        }
    }

    /// "Turn right to face the route." — `turn` is a fragment from the
    /// turn-command family with its trailing period already removed.
    static func alignToRoute(turn: String) -> String {
        switch lang {
        case .en: return "\(turn) to face the route."
        case .fr: return "\(turn) pour faire face au trajet."
        }
    }

    // ── Progress and arrival ────────────────────────────────────────────────

    /// Opening cue of a journey. States where the route ends and how far it is
    /// before the first leg, so the user can judge the guidance against what
    /// they expect instead of hearing one leg's countdown out of context.
    static func startingJourney(
        start: String,
        destination: String,
        distance: String,
        firstInstruction: String
    ) -> String {
        switch lang {
        case .en: return "Starting at \(start). \(destination) is \(distance) away. \(firstInstruction)"
        case .fr: return "Départ à \(start). \(destination) est à \(distance). \(firstInstruction)"
        }
    }

    // ── Walk-leg context ────────────────────────────────────────────────────

    static func towardTheCorner() -> String {
        switch lang {
        case .en: return "toward the corner"
        case .fr: return "vers le coin"
        }
    }

    static func towardTheNextTurn() -> String {
        switch lang {
        case .en: return "toward the next turn"
        case .fr: return "vers le prochain virage"
        }
    }

    static func towardPlace(_ place: String) -> String {
        switch lang {
        case .en: return "toward \(place)"
        case .fr: return "vers \(place)"
        }
    }

    /// Used where the route just continues: no turn, no place worth naming.
    static func straightAheadContext() -> String {
        switch lang {
        case .en: return "straight ahead"
        case .fr: return "tout droit"
        }
    }

    static func theNextPointLabel() -> String {
        switch lang {
        case .en: return "the next point"
        case .fr: return "le point suivant"
        }
    }

    static func inDistanceTurn(distance: String, turn: String) -> String {
        switch lang {
        case .en: return "In \(distance), \(turn)."
        case .fr: return "Dans \(distance), \(turn)."
        }
    }

    static func walkDistance(distance: String, context: String) -> String {
        switch lang {
        case .en: return "Walk \(distance), \(context)."
        case .fr: return "Marchez \(distance), \(context)."
        }
    }

    static func walkDistancePassing(
        distance: String,
        context: String,
        landmark: String
    ) -> String {
        switch lang {
        case .en: return "Walk \(distance), \(context). Passing \(landmark)."
        case .fr: return "Marchez \(distance), \(context). Vous passez \(landmark)."
        }
    }

    static func turnThenWalk(
        prefix: String,
        turn: String,
        distance: String,
        context: String
    ) -> String {
        switch lang {
        case .en: return "\(prefix)\(turn). Walk \(distance), \(context)."
        case .fr: return "\(prefix)\(turn). Marchez \(distance), \(context)."
        }
    }

    static func atTheTurn(_ turn: String) -> String {
        switch lang {
        case .en: return "At the turn, \(turn)."
        case .fr: return "Au virage, \(turn)."
        }
    }

    static func defaultRouteLabel() -> String {
        switch lang {
        case .en: return "the route"
        case .fr: return "le trajet"
        }
    }

    /// Off-route rejoin, straight ahead: "Off route. Walk 4 meters to aisle 3."
    static func rejoinStraight(distance: String, node: String) -> String {
        switch lang {
        case .en: return "Off route. Walk \(distance) to \(node)."
        case .fr: return "Vous avez quitté le trajet. Marchez \(distance) jusqu’à \(node)."
        }
    }

    /// Off-route rejoin with a turn first. `turn` is a complete sentence.
    static func rejoinWithTurn(turn: String, distance: String, node: String) -> String {
        switch lang {
        case .en:
            return "Off route. \(turn) Then walk \(distance) to \(node)."
        case .fr:
            return "Vous avez quitté le trajet. \(turn) Puis marchez \(distance) jusqu’à \(node)."
        }
    }

    static func destinationJustAhead(_ destination: String) -> String {
        switch lang {
        case .en: return "\(destination) is just ahead."
        case .fr: return "\(destination) est juste devant."
        }
    }

    /// Final-leg approach cue, the destination's counterpart to
    /// `inDistanceTurn` — spoken once as the destination comes up, not
    /// repeated every meter.
    static func destinationInDistance(_ destination: String, distance: String) -> String {
        switch lang {
        case .en: return "\(destination) in \(distance)."
        case .fr: return "\(destination) dans \(distance)."
        }
    }

    static func defaultDestinationLabel() -> String {
        switch lang {
        case .en: return "The destination"
        case .fr: return "La destination"
        }
    }

    static func arrivedAt(_ target: String) -> String {
        switch lang {
        case .en: return "Arrived at \(target)."
        case .fr: return "Vous êtes arrivé à \(target)."
        }
    }

    static func switchingToReaching(object: String) -> String {
        switch lang {
        case .en: return "Switching to reaching guidance for \(object)."
        case .fr: return "Je passe au guidage vers \(object)."
        }
    }

    /// Arrival where the target sits beside the last walked node rather than at
    /// the end of the route: `side` comes from the directional-context family
    /// ("on your left"). The user turns, they do not keep walking.
    static func destinationOnSide(_ side: String) -> String {
        switch lang {
        case .en: return "It is \(side)."
        case .fr: return "C’est \(side)."
        }
    }

    static func destinationAheadOnSide(_ destination: String, side: String) -> String {
        switch lang {
        case .en: return "\(destination) is just ahead, \(side)."
        case .fr: return "\(destination) est juste devant, \(side)."
        }
    }

    static func nearTargetConfirm(_ target: String) -> String {
        switch lang {
        case .en:
            return "Near \(target). Look toward the target to confirm arrival."
        case .fr:
            return "Vous approchez de \(target). Tournez-vous vers la cible pour confirmer l’arrivée."
        }
    }

    static func alreadyAt(_ target: String) -> String {
        switch lang {
        case .en: return "You are already at \(target)."
        case .fr: return "Vous êtes déjà à \(target)."
        }
    }

    static func cannotConfirmAt(_ target: String) -> String {
        switch lang {
        case .en:
            return "I can't confirm you are at \(target) yet. Walk a few steps along the route and ask again."
        case .fr:
            return "Je ne peux pas encore confirmer que vous êtes à \(target). Faites quelques pas sur le trajet et redemandez."
        }
    }

    // ── Relocalization and map improvement ──────────────────────────────────

    static func relocLoadingCue() -> String {
        switch lang {
        case .en: return "Loading the saved route. Hold the phone at chest height and slowly pan left and right."
        case .fr: return "Chargement du trajet enregistré. Tenez le téléphone à hauteur de poitrine et balayez lentement de gauche à droite."
        }
    }

    /// Second relocalization cue. A full in-place turn is the cue that
    /// actually works when the user faces opposite to the capture direction:
    /// panning left and right never brings a mapped viewpoint into frame,
    /// turning around does.
    static func relocTurnFullCircleCue() -> String {
        switch lang {
        case .en: return "Still matching the map. Turn slowly in a full circle, keeping the phone at chest height."
        case .fr: return "Je cherche encore la carte. Tournez lentement sur vous-même, un tour complet, en gardant le téléphone à hauteur de poitrine."
        }
    }

    static func relocStepAndTurnCue() -> String {
        switch lang {
        case .en: return "Still searching. Take a small step forward, then turn slowly in a circle again."
        case .fr: return "Je cherche toujours. Faites un petit pas en avant, puis tournez lentement sur vous-même encore une fois."
        }
    }

    /// Spoken when an attempt times out but the AR session is left searching,
    /// so asking again continues the same attempt rather than restarting it.
    static func relocStillSearchingMessage() -> String {
        switch lang {
        case .en: return "I have not found your position yet, but I am still looking. Keep walking along the mapped route and ask me again — I will pick up where I left off."
        case .fr: return "Je n’ai pas encore trouvé votre position, mais je continue de chercher. Continuez le long du trajet cartographié et redemandez-moi — je reprendrai où j’en étais."
        }
    }

    static func relocFailedMessage() -> String {
        switch lang {
        case .en: return "I could not match the saved route map from here. Walk to a spot on the mapped route, hold the phone at chest height, and try again."
        case .fr: return "Je n’ai pas pu reconnaître la carte du trajet d’ici. Placez-vous sur le trajet cartographié, tenez le téléphone à hauteur de poitrine, et réessayez."
        }
    }

    static func enrichmentStarted(_ mapName: String) -> String {
        switch lang {
        case .en: return "Improving \(mapName). Walk the route in the opposite direction. At each destination, stop and turn a slow full circle."
        case .fr: return "Amélioration de \(mapName). Parcourez le trajet en sens inverse. À chaque destination, arrêtez-vous et faites lentement un tour complet."
        }
    }

    static func enrichmentDwellPrompt(_ nodeName: String) -> String {
        switch lang {
        case .en: return "At \(nodeName). Stand still and turn a slow full circle so I can capture this spot from every direction."
        case .fr: return "Vous êtes à \(nodeName). Restez sur place et tournez lentement sur vous-même pour que je capture cet endroit dans toutes les directions."
        }
    }

    static func enrichmentSaved(keyframeCount: Int) -> String {
        switch lang {
        case .en: return "Map improved with \(keyframeCount) new keyframes."
        case .fr: return "Carte améliorée avec \(keyframeCount) nouvelles images clés."
        }
    }

    /// Spoken while ARKit is still matching the saved map but the camera has
    /// already visually recognized a mapped place — tells the waiting user the
    /// app knows roughly where they are instead of coaching a blind pan.
    static func relocRecognizedPlaceCue(_ placeName: String) -> String {
        switch lang {
        case .en: return "I can see \(placeName). Keep turning slowly, lining up the map."
        case .fr: return "Je reconnais \(placeName). Continuez à tourner lentement, alignement de la carte en cours."
        }
    }

    static func anchorEndpointPrompt(_ nodeName: String) -> String {
        switch lang {
        case .en: return "You're at \(nodeName). Anchor it — hold the phone up and turn a slow full circle so this spot can be found again from any direction."
        case .fr: return "Vous êtes à \(nodeName). Ancrez ce point : tenez le téléphone levé et faites lentement un tour complet pour que cet endroit soit reconnu depuis n'importe quelle direction."
        }
    }

    static func anchorEndpointProgress(_ nodeName: String, covered: Int, required: Int) -> String {
        switch lang {
        case .en: return "Anchoring \(nodeName): keep turning (\(covered) of \(required))."
        case .fr: return "Ancrage de \(nodeName) : continuez à tourner (\(covered) sur \(required))."
        }
    }

    static func anchorEndpointComplete(_ nodeName: String) -> String {
        switch lang {
        case .en: return "\(nodeName) anchored."
        case .fr: return "\(nodeName) ancré."
        }
    }

    // ── Status prefixes ─────────────────────────────────────────────────────

    static func trackingLimitedPrefix() -> String {
        switch lang {
        case .en: return "Tracking limited, walk slowly. "
        case .fr: return "Suivi limité, marchez lentement. "
        }
    }

    static func backOnRoutePrefix() -> String {
        switch lang {
        case .en: return "Back on route. "
        case .fr: return "De retour sur le trajet. "
        }
    }

    static func goodPrefix() -> String {
        switch lang {
        case .en: return "Good. "
        case .fr: return "Bien. "
        }
    }

    static func routeRealignedPrefix() -> String {
        switch lang {
        case .en: return "Route realigned from your position. "
        case .fr: return "Trajet réaligné depuis votre position. "
        }
    }

    static func guidanceRealigned() -> String {
        switch lang {
        case .en: return "Guidance realigned. Continue."
        case .fr: return "Guidage réaligné. Continuez."
        }
    }

    static func notInMap(_ target: String) -> String {
        switch lang {
        case .en: return "\(target) is not in this semantic map."
        case .fr: return "\(target) n’est pas dans cette carte."
        }
    }

    static func noWalkableRoute(_ target: String) -> String {
        switch lang {
        case .en: return "No walkable route to \(target)."
        case .fr: return "Aucun trajet praticable vers \(target)."
        }
    }

    // ── Distances ───────────────────────────────────────────────────────────

    static func lessThanOneMeter() -> String {
        switch lang {
        case .en: return "less than one meter"
        case .fr: return "moins d’un mètre"
        }
    }

    static func aboutOneMeter() -> String {
        switch lang {
        case .en: return "about 1 meter"
        case .fr: return "environ un mètre"
        }
    }

    static func oneMeter() -> String {
        switch lang {
        case .en: return "1 meter"
        case .fr: return "1 mètre"
        }
    }

    static func meters(_ count: Int) -> String {
        switch lang {
        case .en: return "\(count) meters"
        case .fr: return "\(count) mètres"
        }
    }

    // ── Directional context ─────────────────────────────────────────────────

    static func onYourLeft() -> String {
        switch lang {
        case .en: return "on your left"
        case .fr: return "à votre gauche"
        }
    }

    static func onYourRight() -> String {
        switch lang {
        case .en: return "on your right"
        case .fr: return "à votre droite"
        }
    }

    static func nearTheCenter() -> String {
        switch lang {
        case .en: return "near the center"
        case .fr: return "vers le centre"
        }
    }

    static func ahead() -> String {
        switch lang {
        case .en: return "ahead"
        case .fr: return "devant vous"
        }
    }

    static func behindYou() -> String {
        switch lang {
        case .en: return "behind you"
        case .fr: return "derrière vous"
        }
    }
}
