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

/// How spoken route distances are measured.
///
/// Mirrors `navigationDistanceUnit` in `src/context/SettingsContext.tsx`.
/// Several pilot participants could not act on metres — a distance you have
/// never had to estimate without sight is not a distance you can walk. Steps
/// are a unit the user carries with them.
enum NavigationDistanceUnit: String {
    case meters
    case steps

    /// Tolerant parse for the bridged value. Anything unrecognised falls back
    /// to metres rather than changing a live session's unit to a guess.
    init(code: String?) {
        guard let code, !code.isEmpty else {
            self = .meters
            return
        }
        self = NavigationDistanceUnit(rawValue: code.lowercased()) ?? .meters
    }

    /// Metres covered by one walking step.
    ///
    /// Matches `IMUSensorManager`'s own step model (0.65 m default, 0.67 m
    /// typical calibrated value), so a spoken step count agrees with the
    /// odometry the same guidance is built on. Deliberately shorter than the
    /// reaching pipeline's 0.75 m: that measures an arm's-length approach,
    /// this measures a walking gait. Erring short overstates the count a
    /// little, which stops a user short of an obstacle rather than past it.
    static let metersPerStep = 0.65
}

/// Process-wide distance unit for native spoken guidance.
///
/// A global for the same reason `AppLocale` is: the distance formatters are
/// `static` on SemanticRouteNavigator and are reached from static phrase
/// builders deep inside the geometry code.
enum NavigationUnits {
    private static let queue = DispatchQueue(label: "com.shelfscout.navunits")
    private static var _current: NavigationDistanceUnit = .meters

    static var current: NavigationDistanceUnit {
        get { queue.sync { _current } }
        set { queue.sync { _current = newValue } }
    }
}

/// Spoken guidance strings, per language.
///
/// Every entry returns a COMPLETE phrase. Do not build sentences by
/// concatenating fragments across languages: English composes
/// "Off route." + "Walk 4 meters to aisle 3.", but French binds the verb to
/// its preposition — « Marchez sur 4 mètres pour rejoindre l'allée 3 » —
/// so the seam falls in a different place. Fragment-splicing is exactly how
/// machine translation of navigation apps ends up unintelligible.
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
        // "suivez le coin" is not an instruction in French. "virage" is the
        // word the rest of this catalog already uses for a turn.
        case .fr: return "suivez le virage"
        }
    }

    // The slight-turn family drops its verb ("take a slight left" → "slight
    // left"). These fire while the user is already walking a leg and only
    // need the correction named; the verb was a syllable of latency before
    // the part that carries the direction.
    static func slightLeftAtCorner() -> String {
        switch lang {
        case .en: return "slight left at the corner"
        case .fr: return "légèrement à gauche au coin"
        }
    }

    static func slightRightAtCorner() -> String {
        switch lang {
        case .en: return "slight right at the corner"
        case .fr: return "légèrement à droite au coin"
        }
    }

    static func slightLeft() -> String {
        switch lang {
        case .en: return "slight left"
        case .fr: return "légèrement à gauche"
        }
    }

    static func slightRight() -> String {
        switch lang {
        case .en: return "slight right"
        case .fr: return "légèrement à droite"
        }
    }

    // "franchement" reads as "frankly" as readily as "sharply"; "brusquement"
    // is unambiguous about the magnitude of the turn.
    static func turnSharpLeft() -> String {
        switch lang {
        case .en: return "turn sharp left"
        case .fr: return "tournez brusquement à gauche"
        }
    }

    static func turnSharpRight() -> String {
        switch lang {
        case .en: return "turn sharp right"
        case .fr: return "tournez brusquement à droite"
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
        case .fr: return "Tournez brusquement à gauche."
        }
    }

    static func turnSharpRightCommand() -> String {
        switch lang {
        case .en: return "Turn sharp right."
        case .fr: return "Tournez brusquement à droite."
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

    // "se tasser" is the everyday Quebec verb for moving over a step; the
    // European "se décaler" is understood here but is not what a Montreal
    // speaker would say.
    static func stepLeft() -> String {
        switch lang {
        case .en: return "Step left"
        case .fr: return "Tassez-vous à gauche"
        }
    }

    static func stepRight() -> String {
        switch lang {
        case .en: return "Step right"
        case .fr: return "Tassez-vous à droite"
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

    // ── Course correction (staying centred in the aisle) ────────────────────
    //
    // Deliberately different wording from the recovery nudges above. These are
    // small adjustments spoken while the user is walking a leg correctly, and
    // must not sound like "you are off route" — a pilot participant who heard
    // alarm-toned corrections started stopping and re-orienting each time.

    /// Clock-face course correction, always one or two hours either side of
    /// straight ahead: "Ease to 11 o'clock."
    static func easeToClock(hour: Int) -> String {
        switch lang {
        case .en: return "Ease to \(hour) o'clock."
        // "ajuster" is transitive in French — "Ajustez vers…" has no object and
        // lands as a fragment. "Orientez-vous" carries the same soft register.
        case .fr: return "Orientez-vous vers \(hour) heure\(hour == 1 ? "" : "s")."
        }
    }

    static func bearLeftSlightly() -> String {
        switch lang {
        case .en: return "Bear slightly left."
        case .fr: return "Serrez légèrement à gauche."
        }
    }

    static func bearRightSlightly() -> String {
        switch lang {
        case .en: return "Bear slightly right."
        case .fr: return "Serrez légèrement à droite."
        }
    }

    /// A recovery nudge, as a sentence of its own.
    ///
    /// It used to carry a trailing distance — "Head to 2 o'clock, 3 meters." —
    /// and that second clause is what a reviewer called clearly broken on 15
    /// Aug 2026. A correction is one action: which way. The distance turned it
    /// into a two-number instruction delivered at the moment the user is least
    /// able to hold numbers, and the number itself described a diagonal to a
    /// pursuit point rather than anything the user could pace out.
    static func recoveryNudge(_ nudge: String) -> String {
        "\(nudge)."
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
    //
    // There is no phrasing here any more, on purpose. Alignment cues used to
    // append "to face the route" to the turn command — "Turn to 6 o'clock to
    // face the route." — and a reviewer asked on 15 Aug 2026 for the clause to
    // be removed outright. It named the goal rather than the action, arrived
    // after the part the user has to act on, and made an alignment nudge sound
    // like a different kind of instruction from the identical turn command the
    // recovery path speaks. `routeAlignmentInstruction` now returns the bare
    // turn command from the `turn*Command` family above.

    // ── Progress and arrival ────────────────────────────────────────────────

    /// Opening cue of a journey. States where the route ends and how far it is
    /// before the first leg, so the user can judge the guidance against what
    /// they expect instead of hearing one leg's countdown out of context.
    ///
    /// The start node is deliberately NOT named. "Starting at Left turn 4" is
    /// a capture label, not a place the user recognises, and it delayed the
    /// only two facts that matter — where they are going and how far it is.
    static func startingJourney(
        destination: String,
        distance: String,
        firstInstruction: String
    ) -> String {
        switch lang {
        case .en: return "\(destination) is \(distance) away. \(firstInstruction)"
        case .fr: return "\(destination) est à \(distance). \(firstInstruction)"
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

    // ── Structural node labels ──────────────────────────────────────────────
    //
    // "Left turn 2" is a CAPTURE label: the ordinal exists so the mapper can
    // tell two turns apart in the route inspector. Spoken to a walking user it
    // is noise at best — "ten meters toward Left turn 2" invites them to look
    // for a thing called "left turn two" — and pilot feedback on 11 Aug 2026
    // asked for the numbers to go. The turn itself is the whole message.

    static func theLeftTurn() -> String {
        switch lang {
        case .en: return "the left turn"
        case .fr: return "le virage à gauche"
        }
    }

    static func theRightTurn() -> String {
        switch lang {
        case .en: return "the right turn"
        case .fr: return "le virage à droite"
        }
    }

    static func theCornerLabel() -> String {
        switch lang {
        case .en: return "the corner"
        case .fr: return "le coin"
        }
    }

    static func theNextTurnLabel() -> String {
        switch lang {
        case .en: return "the next turn"
        case .fr: return "le prochain virage"
        }
    }

    // ── Landmarks passed along a leg ────────────────────────────────────────
    //
    // These were built inline in SemanticRouteNavigator until the French pilot
    // prep: the name and the side phrase were already localized, but the
    // connective words around them were not, so a French session spoke
    // « Fromages à votre gauche in 3 mètres ». Everything a landmark cue says
    // now goes through here.

    /// "cheese counter on your left in 3 meters" — a fragment. Callers add the
    /// sentence punctuation, because it is used both standalone and embedded.
    static func landmarkAhead(name: String, side: String, distance: String) -> String {
        switch lang {
        case .en: return "\(name) \(side) in \(distance)"
        case .fr: return "\(name) \(side) dans \(distance)"
        }
    }

    /// "Passing the cheese counter on your left" — a fragment, as above.
    static func passingLandmark(name: String, side: String) -> String {
        switch lang {
        case .en: return "Passing \(name) \(side)"
        case .fr: return "Vous passez \(name) \(side)"
        }
    }

    /// The maneuver first, the distance second: "Turn right in 3 meters."
    ///
    /// Fronting the maneuver means the user knows WHAT is coming while the
    /// distance is still being spoken. The old order ("In 3 meters, turn
    /// right") made them hold a number for a sentence before learning what it
    /// was a number of. `turn` arrives sentence-cased from the caller.
    static func turnInDistance(turn: String, distance: String) -> String {
        switch lang {
        case .en: return "\(turn) in \(distance)."
        case .fr: return "\(turn) dans \(distance)."
        }
    }

    /// A leg stated as distance plus what it runs toward: "12 meters straight
    /// ahead."
    ///
    /// The verb is gone on purpose. "Walk" opened every routine cue on the
    /// route and carried no information — the user is already walking, and by
    /// the third leg the word is pure latency in front of the number.
    ///
    /// No comma either. The synthesizer honours it as a real pause, so "2
    /// meters, toward the next turn" reached a reviewer on 15 Aug 2026 as a
    /// number, a silence, and then a fragment — the break landing in the one
    /// place the sentence has no seam. The pause the listener actually needs is
    /// the one BEFORE the distance, which is a sentence boundary and is now
    /// spoken as one; see `TTSManager`.
    static func legDistance(distance: String, context: String) -> String {
        switch lang {
        case .en: return "\(distance) \(context)."
        case .fr: return "\(distance) \(context)."
        }
    }

    /// Re-announcing a leg the user is already walking: "Walk 8 meters."
    ///
    /// Every path that re-states an in-progress leg — the stillness reprompt,
    /// the resumption after a corrective turn, the exit from recovery — used to
    /// re-speak `legDistance` verbatim. A reviewer heard the same sentence
    /// twice in five seconds ("2 meters toward the next turn"), and heard the
    /// leg's context repeated at 8, 7, 6 and 3 metres on legs where nothing had
    /// changed. The distance is the only part that is new, and the verb is what
    /// makes it a resumption rather than a countdown beat.
    static func walkDistance(_ distance: String) -> String {
        switch lang {
        case .en: return "Walk \(distance)."
        case .fr: return "Marchez \(distance)."
        }
    }

    /// Two maneuvers one after the other, where the leg between them is too
    /// short to walk as its own instruction: "Turn right, then turn left."
    ///
    /// `first` arrives sentence-cased with its trailing period removed;
    /// `second` is a bare turn fragment. Both come from `turnInstruction`.
    static func turnThenTurn(first: String, second: String) -> String {
        switch lang {
        case .en: return "\(first), then \(second)."
        case .fr: return "\(first), puis \(second)."
        }
    }

    /// A turn that lands the user at the destination without a walk between:
    /// "Turn right. Beer is just ahead."
    static func turnThenDestination(turn: String, destination: String) -> String {
        switch lang {
        case .en: return "\(turn). \(destination)"
        case .fr: return "\(turn). \(destination)"
        }
    }

    /// The first cue of a new leg, spoken the moment the turn is called:
    /// "Turn right. Walk 11 meters toward the next turn."
    ///
    /// The verb is back, and ONLY here. `legDistance` above dropped it because
    /// it opened every routine cue on a leg the user was already walking; at a
    /// turn the opposite is true — pilot participants completed the turn and
    /// then stood still, because nothing in "Turn right. 11 meters, toward the
    /// next turn." told them the turn was over and walking had resumed. It is
    /// the transition that needs the verb, not the repetition.
    static func turnThenWalkLeg(
        prefix: String,
        turn: String,
        distance: String,
        context: String
    ) -> String {
        switch lang {
        case .en: return "\(prefix)\(turn). Walk \(distance) \(context)."
        case .fr: return "\(prefix)\(turn). Marchez \(distance) \(context)."
        }
    }

    /// A bare distance, spoken as its own cue: "3 meters." Used for the
    /// countdown between the maneuver announcement and the maneuver itself,
    /// where the context has already been established and repeating it is
    /// what made the guidance feel like chatter.
    static func distanceOnly(_ distance: String) -> String {
        "\(distance)."
    }

    static func defaultRouteLabel() -> String {
        switch lang {
        case .en: return "the route"
        case .fr: return "le trajet"
        }
    }

    /// Off-route rejoin, straight ahead: "Off route. Walk 4 meters to aisle 3."
    ///
    /// French uses "pour rejoindre X" rather than "jusqu'à X" on purpose: the
    /// node label is interpolated raw, and "jusqu'à" would have to contract
    /// with a label that carries its own article. `defaultRouteLabel` is
    /// exactly that case — "jusqu'à le trajet" is ungrammatical, while "pour
    /// rejoindre le trajet" is correct and also reads better as a rejoin.
    static func rejoinStraight(distance: String, node: String) -> String {
        switch lang {
        case .en: return "Off route. Walk \(distance) to \(node)."
        case .fr: return "Vous avez quitté le trajet. Marchez sur \(distance) pour rejoindre \(node)."
        }
    }

    /// Off-route rejoin with a turn first. `turn` is a complete sentence.
    static func rejoinWithTurn(turn: String, distance: String, node: String) -> String {
        switch lang {
        case .en:
            return "Off route. \(turn) Then walk \(distance) to \(node)."
        case .fr:
            return "Vous avez quitté le trajet. \(turn) Puis marchez sur \(distance) pour rejoindre \(node)."
        }
    }

    static func destinationJustAhead(_ destination: String) -> String {
        switch lang {
        case .en: return "\(destination) is just ahead."
        case .fr: return "\(destination) est juste devant."
        }
    }

    /// Final-leg approach cue, the destination's counterpart to
    /// `turnInDistance` — spoken once as the destination comes up, not
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

    /// French must not use "Vous êtes arrivé" here: the participle agrees with
    /// the listener, so every woman in the study would hear a masculine form
    /// (and "arrivé(e)" is unspeakable). "Arrivée à X" is the noun — the same
    /// phrasing transit announcements use — and carries no listener gender.
    static func arrivedAt(_ target: String) -> String {
        switch lang {
        case .en: return "Arrived at \(target)."
        case .fr: return "Arrivée à \(target)."
        }
    }

    /// Arrival where the target sits beside the last walked node rather than at
    /// the end of the route: `side` comes from the directional-context family
    /// ("on your left"). The user turns, they do not keep walking.
    ///
    /// One sentence, not three. Arrival used to chain "Arrived at X." + "It is
    /// on your left." + "Switching to reaching guidance for X." — and the
    /// reaching handoff cut the tail off mid-word every time, so the side (the
    /// one part that tells the user where to turn) was the part they lost. The
    /// handoff sentence is gone because reaching announces itself anyway.
    static func arrivedAtOnSide(_ target: String, side: String) -> String {
        switch lang {
        case .en: return "Arrived at \(target), \(side)."
        case .fr: return "Arrivée à \(target), \(side)."
        }
    }

    static func destinationAheadOnSide(_ destination: String, side: String) -> String {
        switch lang {
        case .en: return "\(destination) is just ahead, \(side)."
        case .fr: return "\(destination) est juste devant, \(side)."
        }
    }

    /// The user has walked past the destination and is still going.
    ///
    /// There was nothing for this on 11 Aug 2026: a pilot participant walked
    /// past Onions and heard "about 1 meter, toward Onions" on repeat, because
    /// the route's own progress model saturates at the end of the leg and
    /// cannot express "behind you". They recovered by themselves.
    static func passedDestinationTurnAround(_ destination: String) -> String {
        switch lang {
        case .en: return "You've passed \(destination). Turn around."
        case .fr: return "Vous avez dépassé \(destination). Faites demi-tour."
        }
    }

    /// The same, once they are facing back: how far to walk to return.
    static func passedDestinationWalkBack(_ destination: String, distance: String) -> String {
        switch lang {
        case .en: return "\(destination) is \(distance) behind you."
        case .fr: return "\(destination) est à \(distance) derrière vous."
        }
    }

    /// "Look toward the target to confirm arrival" used to follow this. It
    /// asked a blind user to aim a camera at something they cannot see in
    /// order to satisfy the app's own confirmation step — work for the user
    /// that arrival detection does on its own a moment later.
    static func nearTargetConfirm(_ target: String) -> String {
        switch lang {
        case .en:
            return "Near \(target)."
        case .fr:
            // Apposition after "la cible", never "de \(target)": "de" would
            // have to contract with an article the label may carry ("de le" →
            // "du"), which the interpolation cannot do.
            return "Vous approchez de la cible : \(target)."
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

    /// First relocalization cue. Opens on the instruction, not on a status
    /// report: "Loading the saved route" told the user what the app was doing
    /// while they stood waiting to be told what to do.
    static func relocLoadingCue() -> String {
        switch lang {
        case .en: return "Hold the phone at chest height and slowly pan left and right."
        case .fr: return "Tenez le téléphone à hauteur de poitrine et balayez lentement de gauche à droite."
        }
    }

    /// Shorter opener for a relocalization AFTER the first one in this app
    /// run: the full posture-and-pan coaching has already been heard, and on a
    /// multi-destination map the user hears it at every hop.
    static func relocPanBriefCue() -> String {
        switch lang {
        case .en: return "Pan slowly left and right."
        case .fr: return "Balayez lentement de gauche à droite."
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
        case .fr: return "Je reconnais \(placeName). Continuez à tourner lentement, j’aligne la carte."
        }
    }

    static func anchorEndpointPrompt(_ nodeName: String) -> String {
        switch lang {
        case .en: return "You're at \(nodeName). Anchor it — hold the phone up and turn a slow full circle so this spot can be found again from any direction."
        case .fr: return "Vous êtes à \(nodeName). Ancrez ce point : tenez le téléphone levé et faites lentement un tour complet pour que cet endroit soit reconnu depuis n’importe quelle direction."
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
        // "\(nodeName) ancré" would have to agree with the label's gender,
        // which the interpolation cannot know. Fronting the noun avoids it.
        case .fr: return "Ancrage terminé : \(nodeName)."
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

    /// The AR screen's exit control, for VoiceOver. The whole screen carries
    /// it now, so the label describes the screen rather than the toolbar
    /// button it is also attached to.
    static func stopGuidanceButton() -> String {
        switch lang {
        case .en: return "Stop guidance"
        case .fr: return "Arrêter le guidage"
        }
    }

    static func stopGuidanceButtonHint() -> String {
        switch lang {
        case .en: return "Double tap anywhere on the screen to end navigation"
        case .fr: return "Touchez deux fois n’importe où sur l’écran pour terminer la navigation"
        }
    }

    static func guidanceRealigned() -> String {
        switch lang {
        case .en: return "Guidance realigned. Continue."
        case .fr: return "Guidage réaligné. Continuez."
        }
    }

    /// Spoken only once a belief hold has outlasted the window it normally
    /// resolves in. Apologetic and self-directed on purpose: pilot feedback on
    /// 11 Aug 2026 was that "Hold on. Pan the phone slowly." and "Route lost.
    /// Stop and slowly look around." both hand the user a job to do, which
    /// reads as the route having failed. The system is the one recovering, so
    /// it says so and the user keeps walking.
    static func realigningApology() -> String {
        switch lang {
        case .en: return "Sorry, let me realign."
        case .fr: return "Désolé, je me réaligne."
        }
    }

    /// The banner text for the same state. Not spoken.
    static func realigningStatus() -> String {
        switch lang {
        case .en: return "Realigning…"
        case .fr: return "Réalignement en cours…"
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

    /// Both of these are SPOKEN on the guidance-start path, so they have to be
    /// localized even though the rest of the map-loading errors around them are
    /// display-only operator text.
    static func loadMatchingARMap() -> String {
        switch lang {
        case .en: return "Load the matching AR map for this route before guiding."
        case .fr: return "Chargez la carte AR correspondant à ce trajet avant de lancer le guidage."
        }
    }

    static func startARMapFirst() -> String {
        switch lang {
        case .en: return "Load or start the AR map first so I can localize on the captured route."
        case .fr: return "Chargez ou démarrez d’abord la carte AR pour que je puisse vous situer sur le trajet enregistré."
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

    static func oneStep() -> String {
        switch lang {
        case .en: return "1 step"
        case .fr: return "1 pas"
        }
    }

    static func steps(_ count: Int) -> String {
        switch lang {
        case .en: return "\(count) steps"
        case .fr: return "\(count) pas"
        }
    }

    /// Long counts are rounded before they are spoken: "about 30 steps" is a
    /// number a walking user can hold on to, "32 steps" is not.
    static func aboutSteps(_ count: Int) -> String {
        switch lang {
        case .en: return "about \(count) steps"
        case .fr: return "environ \(count) pas"
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

/// Spoken reaching-guidance strings, per language.
///
/// Same contract as `NavLoc`: every entry returns a COMPLETE phrase, never a
/// fragment to be concatenated across languages.
///
/// Two rules this catalog exists to enforce, both of which the previous inline
/// English violated by construction:
///
///  1. NOTHING here may agree with the listener's gender. The pilot has mixed-
///     gender participants and the app has no way to know which, so
///     "vous vous êtes éloigné" and "vous êtes prêt" are out — every phrase is
///     written so no participle agrees with "vous".
///  2. NOTHING here may agree with the target's gender or number either. The
///     object name arrives from the intent LLM with its article already
///     stripped, so "la bouteille atteinte" / "les céréales atteintes" cannot
///     be produced. Constructions with "avoir" and with the name after a
///     preposition are safe; a predicate adjective on the name is not.
enum ReachLoc {
    private static var lang: AppLanguage { AppLocale.current }

    // ── Object out of view ──────────────────────────────────────────────────

    static func objectBehindTurnAround() -> String {
        switch lang {
        case .en: return "Turn around. Object is behind you."
        case .fr: return "Faites demi-tour. L’objet est derrière vous."
        }
    }

    static func objectBehindTurnBack() -> String {
        switch lang {
        case .en: return "Object is behind you. Turn back."
        case .fr: return "L’objet est derrière vous. Retournez-vous."
        }
    }

    static func objectBehindTurn(toRight: Bool) -> String {
        switch lang {
        case .en: return "Object is behind you. Turn \(toRight ? "right" : "left")."
        case .fr: return "L’objet est derrière vous. Tournez à \(toRight ? "droite" : "gauche")."
        }
    }

    /// `lastSeen` comes from `lastSeenSide` below.
    static func outOfViewTurn(lastSeen: String, toRight: Bool) -> String {
        switch lang {
        case .en: return "Out of view, was \(lastSeen). Turn \(toRight ? "right" : "left")."
        case .fr: return "Hors champ. Il était \(lastSeen). Tournez à \(toRight ? "droite" : "gauche")."
        }
    }

    static func lastSeenSide(toRight: Bool) -> String {
        switch lang {
        case .en: return toRight ? "to your right" : "to your left"
        case .fr: return toRight ? "à votre droite" : "à votre gauche"
        }
    }

    static func offTrackObjectIs(_ side: String) -> String {
        switch lang {
        case .en: return "Off track. Object is \(side)."
        case .fr: return "Vous déviez. L’objet est \(side)."
        }
    }

    static func objectIs(_ side: String) -> String {
        switch lang {
        case .en: return "Object is \(side)."
        case .fr: return "L’objet est \(side)."
        }
    }

    // ── Approach ────────────────────────────────────────────────────────────

    static func straightAheadDistance(_ distance: String) -> String {
        switch lang {
        case .en: return "Straight ahead. \(distance)."
        case .fr: return "Tout droit. \(distance)."
        }
    }

    static func goingTheRightWay(_ distance: String) -> String {
        switch lang {
        case .en: return "\(distance). Going the right way."
        case .fr: return "\(distance). Vous allez dans la bonne direction."
        }
    }

    static func gettingFurther(_ distance: String) -> String {
        switch lang {
        case .en: return "Getting further. \(distance)."
        case .fr: return "Vous vous éloignez. \(distance)."
        }
    }

    static func distanceOnly(_ distance: String) -> String {
        "\(distance)."
    }

    static func armsReachKeepGoing() -> String {
        switch lang {
        case .en: return "Arm's reach. Keep going."
        case .fr: return "À portée de main. Continuez."
        }
    }

    static func almostThere() -> String {
        switch lang {
        case .en: return "Almost there."
        case .fr: return "Vous y êtes presque."
        }
    }

    static func tiltPhoneUp() -> String {
        switch lang {
        case .en: return "Tilt phone up."
        case .fr: return "Inclinez le téléphone vers le haut."
        }
    }

    static func tiltPhoneDown() -> String {
        switch lang {
        case .en: return "Tilt phone down."
        case .fr: return "Inclinez le téléphone vers le bas."
        }
    }

    // ── Distances (reaching scale: centimetres or arm's-length steps) ────────

    static func armsReachDistance() -> String {
        switch lang {
        case .en: return "arm's reach"
        case .fr: return "à portée de main"
        }
    }

    /// A reaching distance, rounded to the nearest half metre.
    ///
    /// The exact figure used to be spoken — "straight ahead, 92 centimeters" —
    /// and a reviewer called it ridiculous on 15 Aug 2026 on two counts: the
    /// depth estimate is nowhere near that accurate, and nobody can track their
    /// own movement at that scale. Half-metre steps are the coarsest reading
    /// that still separates "a couple of paces away" from "right in front of
    /// you", which is the only distinction the user acts on.
    ///
    /// Rounding is counted in half-metre units, so 1 is half a metre, 2 is one
    /// metre, 3 is one and a half. Never zero: below the arm's-reach threshold
    /// the caller speaks `armsReachDistance()` instead.
    static func roundedReachDistance(_ distanceMeters: Double) -> String {
        let halves = max(1, Int((max(0, distanceMeters) / 0.5).rounded()))
        if halves == 1 { return halfMeter() }
        if halves == 2 { return oneMeterDistance() }
        let whole = halves / 2
        if halves.isMultiple(of: 2) { return wholeMeters(whole) }
        return metersAndAHalf(whole)
    }

    private static func halfMeter() -> String {
        switch lang {
        case .en: return "half a meter"
        case .fr: return "un demi-mètre"
        }
    }

    private static func oneMeterDistance() -> String {
        switch lang {
        case .en: return "1 meter"
        case .fr: return "1 mètre"
        }
    }

    private static func wholeMeters(_ count: Int) -> String {
        switch lang {
        case .en: return "\(count) meters"
        case .fr: return "\(count) mètres"
        }
    }

    private static func metersAndAHalf(_ count: Int) -> String {
        switch lang {
        case .en: return "\(count) and a half meters"
        case .fr: return "\(count) mètres et demi"
        }
    }

    static func oneStepAway() -> String {
        switch lang {
        case .en: return "one step away"
        case .fr: return "à un pas"
        }
    }

    static func aboutStepsAway(_ count: Int) -> String {
        switch lang {
        case .en: return "about \(count) steps"
        case .fr: return "à environ \(count) pas"
        }
    }

    // ── Final reach ─────────────────────────────────────────────────────────

    /// `hint` is `slightlyRightHint`/`slightlyLeftHint` or an empty string.
    static func objectHereReachForward(object: String, hint: String) -> String {
        switch lang {
        case .en: return "\(object) here. Reach forward\(hint)."
        case .fr: return "\(object), juste ici. Tendez la main vers l’avant\(hint)."
        }
    }

    static func slightlySideHint(toRight: Bool) -> String {
        switch lang {
        case .en: return toRight ? ", slightly right" : ", slightly left"
        case .fr: return toRight ? ", légèrement à droite" : ", légèrement à gauche"
        }
    }

    /// Carries the exit instruction on purpose.
    ///
    /// A pilot participant reached the object and then waited, because nothing
    /// had told her the session ends on a tap — it was said once, in the
    /// opening line, thirty seconds and one aisle earlier. Reaching distance is
    /// where that sentence is worth saying.
    static func almostThereReachFor(_ object: String) -> String {
        switch lang {
        case .en: return "Reach forward for \(object). Tap the screen when you have it."
        case .fr: return "Tendez la main vers \(object). Touchez l’écran quand vous l’avez."
        }
    }

    static func almostThereGrab(_ object: String) -> String {
        switch lang {
        case .en: return "Grab \(object). Tap the screen when you have it."
        case .fr: return "Attrapez \(object). Touchez l’écran quand vous l’avez."
        }
    }

    static func keepReachingRightInFront(_ object: String) -> String {
        switch lang {
        case .en: return "Keep reaching. \(object) is right in front of you."
        case .fr: return "Continuez à tendre la main. \(object) est juste devant vous."
        }
    }

    /// "Tap when you have it" cannot use a French object clitic: "quand vous
    /// l'avez" fixes the object as singular and a plural target needs "les".
    static func tapWhenYouHave(_ object: String) -> String {
        switch lang {
        case .en: return "Tap anywhere when you have \(object)."
        case .fr: return "Touchez l’écran quand vous avez \(object)."
        }
    }

    static func reachForwardTapWhenDone() -> String {
        switch lang {
        case .en: return "Reach forward. Tap anywhere when you have it."
        case .fr: return "Tendez la main vers l’avant. Touchez l’écran quand vous avez l’article."
        }
    }

    static func reachedObject(_ object: String) -> String {
        switch lang {
        case .en: return "\(object) reached!"
        // Not "\(object) atteint" — the participle would have to agree with the
        // object. After "avoir" with the object following, it does not.
        case .fr: return "Vous avez atteint \(object)!"
        }
    }

    static func done() -> String {
        switch lang {
        case .en: return "Done"
        case .fr: return "Terminé"
        }
    }

    /// VoiceOver label for the full-screen exit control. It is the whole
    /// screen, so it says so — a participant who hears "button" and hunts for
    /// its edges is doing work the control was built to remove.
    static func exitOverlayLabel(_ object: String) -> String {
        switch lang {
        case .en: return "I have \(object). Tap anywhere to finish."
        case .fr: return "J’ai \(object). Touchez n’importe où pour terminer."
        }
    }

    static func exitOverlayHint() -> String {
        switch lang {
        case .en: return "Double tap anywhere on the screen to end reaching guidance"
        case .fr: return "Touchez deux fois n’importe où sur l’écran pour terminer le guidage"
        }
    }

    // ── Hand tracking (withHand mode) ───────────────────────────────────────

    static func closeEnoughRaiseHand(_ object: String) -> String {
        switch lang {
        case .en: return "Close enough. Raise your hand to reach for \(object)."
        case .fr: return "Assez proche. Levez la main pour attraper \(object)."
        }
    }

    static func showYourHand() -> String {
        switch lang {
        case .en: return "Show your hand to the camera."
        case .fr: return "Montrez votre main à la caméra."
        }
    }

    static func cannotSeeYourHand() -> String {
        switch lang {
        case .en: return "I can't see your hand. Hold it up in front of the camera."
        case .fr: return "Je ne vois pas votre main. Tenez-la devant la caméra."
        }
    }

    static func handAlignedReachToGrab(_ object: String) -> String {
        switch lang {
        case .en: return "Hand aligned. Reach forward to grab \(object)."
        case .fr: return "Main alignée. Tendez la main pour attraper \(object)."
        }
    }

    /// `directionRawValue` is `ReachingViewController.Direction.rawValue`, which
    /// is an English token because it doubles as a trace/log key. It is mapped
    /// here rather than localized at the enum so the logs stay stable.
    static func moveHand(_ directionRawValue: String) -> String {
        switch lang {
        case .en: return "Move hand \(directionRawValue)"
        case .fr: return "Déplacez la main \(handDirectionFrench(directionRawValue))"
        }
    }

    private static func handDirectionFrench(_ raw: String) -> String {
        switch raw {
        case "left": return "vers la gauche"
        case "right": return "vers la droite"
        case "up": return "vers le haut"
        case "down": return "vers le bas"
        case "top left": return "vers le haut à gauche"
        case "top right": return "vers le haut à droite"
        case "down left": return "vers le bas à gauche"
        case "down right": return "vers le bas à droite"
        default: return raw
        }
    }

    // ── Session start, handoff and AR status ────────────────────────────────

    /// Two clauses, not three. The middle one ("point phone toward it") was
    /// advice the beeps give continuously and better, and it pushed the tap
    /// instruction — the only thing here the user has to remember — to the end
    /// of a long sentence spoken while they were still turning around.
    static func guidingPointPhoneThenTap(_ object: String) -> String {
        switch lang {
        case .en: return "Guiding to \(object). Tap the screen when you have it."
        case .fr: return "Je vous guide vers \(object). Touchez l’écran quand vous l’avez."
        }
    }

    static func guidingPointPhoneThenRaiseHand(_ object: String) -> String {
        switch lang {
        case .en: return "Guiding to \(object). I'll tell you when to raise your hand."
        case .fr: return "Je vous guide vers \(object). Je vous dirai quand lever la main."
        }
    }

    static func guidingToSavedSpot(_ object: String) -> String {
        switch lang {
        case .en: return "Guiding to the saved spot near \(object), within arm's reach."
        case .fr: return "Je vous guide vers l’endroit enregistré près de \(object), à portée de main."
        }
    }

    /// No listener agreement: "vous vous êtes éloigné" would be masculine.
    static func movedAwayResumingNavigation() -> String {
        switch lang {
        case .en: return "Moved away. Resuming navigation."
        case .fr: return "Trop loin. Reprise de la navigation."
        }
    }

    static func targetLocked() -> String {
        switch lang {
        case .en: return "Target locked."
        case .fr: return "Cible verrouillée."
        }
    }

    static func couldNotLineUpWithMap() -> String {
        switch lang {
        case .en: return "I could not line up with the saved map here. Try scanning this area again, then retry."
        case .fr: return "Je n’ai pas pu m’aligner avec la carte enregistrée ici. Balayez cette zone de nouveau, puis réessayez."
        }
    }

    static func findingSavedMap() -> String {
        switch lang {
        case .en: return "Finding the saved map. Move the phone slowly and point toward the mapped shelf."
        // "tablette", not "étagère" — the Quebec word for a store shelf.
        case .fr: return "Je cherche la carte enregistrée. Déplacez le téléphone lentement et pointez-le vers la tablette cartographiée."
        }
    }

    static func stillMatchingStepAndSweep() -> String {
        switch lang {
        case .en: return "Still matching. Take a small step and sweep the phone slowly across the shelf and what is beside it."
        case .fr: return "Je cherche encore. Faites un petit pas et balayez lentement le téléphone sur la tablette et autour."
        }
    }

    static func stillMatchingKeepMoving() -> String {
        switch lang {
        case .en: return "Still matching. Keep moving slowly — turn a little and look further along the aisle."
        case .fr: return "Je cherche encore. Continuez à bouger lentement — tournez un peu et regardez plus loin dans l’allée."
        }
    }

    static func trackingFailed() -> String {
        switch lang {
        case .en: return "Tracking failed."
        case .fr: return "Échec du suivi."
        }
    }

    static func trackingPaused() -> String {
        switch lang {
        case .en: return "Tracking paused"
        case .fr: return "Suivi en pause"
        }
    }

    static func trackingResumed() -> String {
        switch lang {
        case .en: return "Tracking resumed"
        case .fr: return "Suivi rétabli"
        }
    }
}
