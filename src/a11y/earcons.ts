// src/a11y/earcons.ts
//
// The semantic sound-cue layer ("sound icons").
//
// ── Why this exists ────────────────────────────────────────────────────────
// Cue playback used to be spelled out at each call site, always behind the
// same guard:
//
//     const shouldPlaySFX = !screenReaderEnabledRef.current && !wearables;
//     if (shouldPlaySFX) { playThinkingStarted(); }
//     if (!screenReaderEnabled) { audioFeedback.playEarcon('ready'); }
//
// Two problems, both of which a blind user feels immediately:
//
//   1. Every cue was suppressed when VoiceOver was on. The user who depends
//      entirely on audio got the least audio. `setScreenReaderMode()` in
//      utils/soundEffects.ts fixes the session conflict that motivated the
//      guard, so the guard itself can go.
//
//   2. Haptics were suppressed too, by the same guard — even though
//      `Vibration` has nothing whatsoever to do with the audio session. That
//      was collateral damage from a copy-pasted condition, and it removed the
//      one feedback channel that works in a noisy grocery aisle.
//
// A cue here is named for what it MEANS, not for the file it plays. Call
// sites say `earcons.play('thinking')`, never `playThinkingStarted()`, so the
// mapping from meaning to asset stays in one table that can be re-voiced
// without touching the pipeline.
//
// ── Design rules for cues ──────────────────────────────────────────────────
//   • Every state the user can be in has a distinct entry cue. Silence is
//     never a state — if the app is doing something, it says so.
//   • Entering and leaving a mode are different sounds. "Did it start?" and
//     "did it stop?" must never share an answer.
//   • Success and failure are different sounds, and failure also vibrates.
//   • Cues are short. Anything long enough to talk over is too long.

import { Platform, Vibration } from 'react-native';
import {
  playListenSound,
  stopListenSound,
  playThinkingStarted,
  stopLatencyLoop,
  playSuccessChime,
  playErrorSound,
  playStopReachingSound,
} from '../utils/soundEffects';

/**
 * Semantic cue names. Adding one means adding a row to CUES below — the
 * compiler will not let a name exist without a definition.
 */
export type EarconName =
  /** Microphone is open; start speaking now. */
  | 'listenStart'
  /** Microphone closed, request accepted. */
  | 'listenEnd'
  /** Work is in flight. Loops until `thinkingEnd`. */
  | 'thinking'
  /** Work finished; stops the loop. */
  | 'thinkingEnd'
  /** A result is about to be spoken. */
  | 'success'
  /** Something failed. */
  | 'error'
  /** A guided mode (reaching / navigation) has started. */
  | 'modeEnter'
  /** A guided mode has ended, by arrival or by the user stopping it. */
  | 'modeExit'
  /** The app is idle and accepting input. */
  | 'ready'
  /** A menu item took the press. Confirms the tap landed. */
  | 'select';

type HapticPattern = 'none' | 'tap' | 'double' | 'long' | 'buzz';

interface CueDefinition {
  /** Plays the sound. Resolves when it finishes, where that is knowable. */
  sound?: () => Promise<void> | void;
  haptic: HapticPattern;
  /**
   * True when this cue is a response to something the user just did, so it
   * must not be swallowed by the repeat filter — pressing the same button
   * twice has to feel the same both times.
   */
  alwaysPlay?: boolean;
}

// ── Haptics ────────────────────────────────────────────────────────────────
//
// iOS ignores per-element durations in `Vibration.vibrate(pattern)` and treats
// the array as alternating wait/vibrate delays with a fixed pulse length, so
// these patterns encode PULSE COUNT and spacing, which is all iOS can express.
// The distinction users actually reported using is one buzz versus more than
// one, so that is what the vocabulary is built around.
const HAPTIC_PATTERNS: Record<Exclude<HapticPattern, 'none'>, number | number[]> = {
  tap: 35,
  double: [0, 35, 90, 35],
  long: 140,
  buzz: [0, 60, 80, 60, 80, 60],
};

const CUES: Record<EarconName, CueDefinition> = {
  listenStart: { sound: playListenSound, haptic: 'tap', alwaysPlay: true },
  listenEnd: { sound: stopListenSound, haptic: 'tap', alwaysPlay: true },
  thinking: { sound: playThinkingStarted, haptic: 'none' },
  thinkingEnd: { sound: stopLatencyLoop, haptic: 'none' },
  success: { sound: playSuccessChime, haptic: 'double' },
  error: { sound: playErrorSound, haptic: 'buzz', alwaysPlay: true },
  modeEnter: { sound: playSuccessChime, haptic: 'double', alwaysPlay: true },
  modeExit: { sound: playStopReachingSound, haptic: 'long', alwaysPlay: true },
  ready: { haptic: 'tap' },
  select: { haptic: 'tap', alwaysPlay: true },
};

/**
 * Repeat filter. A cue that fires twice inside this window is a re-render or
 * a duplicated call path, not two events, and hearing it twice reads as a
 * glitch. `alwaysPlay` cues bypass it.
 */
const REPEAT_WINDOW_MS = 300;

class EarconsClass {
  private lastPlayedAt = new Map<EarconName, number>();
  private hapticsEnabled = true;
  private soundEnabled = true;
  private nativeSessionActive = false;

  /**
   * Glasses mode locks the audio session to BluetoothHFP for the glasses mic.
   * Playing through react-native-sound there corrupts the HFP session and
   * leaves the latency loop in a zombie state that `.stop()` cannot silence,
   * so sound is disabled while haptics keep working.
   */
  setWearablesMode(enabled: boolean): void {
    this.soundEnabled = !enabled;
  }

  /** Respects a user preference; haptics stay independent of sound. */
  setHapticsEnabled(enabled: boolean): void {
    this.hapticsEnabled = enabled;
  }

  /**
   * True while a native AR screen (navigation or reaching) is presented over
   * the RN UI.
   *
   * Everything in this table describes the RN state machine — "ready", "an
   * error", "thinking" — and none of it describes what the user is doing while
   * a native screen owns the phone. `ready` in particular is a haptic with NO
   * sound, so a stray one reaches the user as a bare unexplained buzz. A
   * participant in the 25 Aug 2026 lab test reported exactly that, twice, mid
   * navigation, and had no way to attribute it to anything.
   *
   * Native owns feedback for that whole window and speaks for itself, so this
   * mutes the RN layer's cues rather than letting them interrupt from behind a
   * screen the user cannot see.
   */
  setNativeSessionActive(active: boolean): void {
    this.nativeSessionActive = active;
  }

  /**
   * Whether a haptic fired right now would reach the user.
   *
   * Exposed so the older `AudioFeedbackService.playEarcon` path — which
   * vibrates directly and predates this module — obeys the same preference and
   * the same native-screen mute instead of being the one buzz nothing governs.
   */
  hapticsAllowed(): boolean {
    return this.hapticsEnabled && !this.nativeSessionActive;
  }

  /**
   * Play a cue. Never throws and never blocks the caller: a failed cue is a
   * cosmetic problem, and the pipelines that call this are ones where an
   * unhandled rejection or a hung await would cost the user their session.
   */
  play(name: EarconName): void {
    this.playAndWait(name).catch(() => {
      // playAndWait already swallows and logs sound failures; this only
      // catches a programming error in the cue table itself.
    });
  }

  /**
   * Play a cue and resolve when it finishes. Use only where the timing
   * genuinely matters — `listenStart` must complete before the microphone
   * opens, or the recognizer hears the cue instead of the user.
   */
  async playAndWait(name: EarconName): Promise<void> {
    const cue = CUES[name];
    if (!cue) return;

    if (this.nativeSessionActive) {
      console.log(`[earcons] "${name}" suppressed — a native AR screen owns feedback`);
      return;
    }

    const now = Date.now();
    if (!cue.alwaysPlay) {
      const last = this.lastPlayedAt.get(name);
      if (last !== undefined && now - last < REPEAT_WINDOW_MS) return;
    }
    this.lastPlayedAt.set(name, now);

    // Haptics first and unconditionally. They reach the user even when the
    // audio session is held by something else, which is exactly when the
    // sound cue is least likely to land.
    this.vibrate(cue.haptic, name);

    if (!cue.sound || !this.soundEnabled) return;

    try {
      await cue.sound();
    } catch (error) {
      console.warn(`[earcons] "${name}" failed:`, error);
    }
  }

  private vibrate(pattern: HapticPattern, name: EarconName): void {
    if (pattern === 'none' || !this.hapticsEnabled) return;
    // Named on every buzz. `ready` and `select` have no sound at all, so a
    // haptic the user cannot account for is otherwise unattributable after the
    // fact — which is exactly the position the 25 Aug 2026 "random vibrations"
    // report left this code in.
    console.log(`📳 [earcons] haptic "${pattern}" for cue "${name}"`);
    try {
      Vibration.vibrate(HAPTIC_PATTERNS[pattern] as number[]);
    } catch (error) {
      // Simulators and some Android devices have no vibrator. Supplementary
      // feedback failing is not worth surfacing.
      if (Platform.OS !== 'ios') {
        console.warn('[earcons] vibration unavailable:', error);
      }
    }
  }

  /** Drop the repeat filter's memory. Called on mode transitions. */
  reset(): void {
    this.lastPlayedAt.clear();
  }
}

export const earcons = new EarconsClass();
export default earcons;
