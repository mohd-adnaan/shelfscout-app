// src/utils/soundEffects.ts
// ─────────────────────────────────────────────────────────────────────────────
// CyberSight — iOS Sound Effects
//
// App state audio cues:
//
//   soundshelfstudio-ui-notification-listening-start.mp3 → Interaction/listening started
//   jbl_latency_sae.caf                                  → Loops while waiting for backend/RTAB
//   jbl_success_sae.caf                                  → Right before speaking the result
//   jbl_stopped_ios_sae.mp3                              → Error returned from backend
//   soundshelfstudio-ui-notification-stop-reaching.wav   → Manual reaching stop
//
// FILE PLACEMENT (see SOUND_SETUP_GUIDE.md):
//   iOS  → ios/<ProjectName>/sounds/<filename>  (added to Xcode bundle)
//   Droid→ android/app/src/main/res/raw/<filename>
//
// ─────────────────────────────────────────────────────────────────────────────

import Sound from 'react-native-sound';
import { Platform, NativeModules } from 'react-native';

// ── Native audio session helper ──────────────────────────────────────────
// react-native-sound's Sound.setCategory('Playback', false) only calls
// [session setCategory:error:] — it never calls setActive:YES, never sets
// mode to .default, and never overrides the output port to speaker.
// After @react-native-voice/voice leaves the session in Record+Measurement
// mode, this produces noticeably lower volume for ALL subsequent RN audio.
//
// configurePlaybackSession() calls our native ReachingModule method that
// mirrors the reaching pipeline's audio session setup:
//   setCategory(.playback, mode: .default)  +  setActive(true)  +  overrideOutputAudioPort(.speaker)
//
// Call this ONCE after STT ends, before any SFX or TTS output.
// ──────────────────────────────────────────────────────────────────────────
const { ReachingModule } = NativeModules;

export const configurePlaybackSession = async (useSpeaker: boolean = true): Promise<void> => {
  if (Platform.OS !== 'ios' || !ReachingModule?.configurePlaybackSession) return;
  try {
    await ReachingModule.configurePlaybackSession(useSpeaker);
  } catch (e: any) {
    // Non-fatal — Sound.setCategory is still called as a fallback
    console.warn('⚠️ [SFX] configurePlaybackSession failed:', e?.message);
  }
};

// ── Glasses-mode flag ─────────────────────────────────────────────────────
// When Meta glasses are connected, the audio session is owned by BluetoothHFP.
// Calling Sound.setCategory('Playback') corrupts the HFP session, causing:
//   - ATAudioSessionClientImpl activation failed (status = 561015905)
//   - recv bitrate: 0 (no video frames from glasses)
//   - configureBluetoothRecordingSession loop failures
// This flag is set by App.tsx at startup and prevents ALL setCategory calls.
let _wearablesMode = false;

/**
 * Call this from App.tsx before initSounds() when glasses mode is persisted.
 * Prevents Sound.setCategory('Playback') from fighting with BluetoothHFP.
 */
export const setWearablesMode = (enabled: boolean): void => {
  _wearablesMode = enabled;
};

/** Safe wrapper: only calls setCategory when NOT in glasses mode. */
const _safeSetPlaybackCategory = (): void => {
  if (_wearablesMode) return;
  Sound.setCategory('Playback', false);
};

// ── Configure sound to play through the speaker, not earpiece ─────────────
// MUST be called before any Sound() constructors.
// NOTE: This runs at module import time. In glasses mode the flag isn't set
// yet, so we defer the actual category set to initSounds() instead.
// Sound.setCategory('Playback', false); ← REMOVED (caused BT-HFP conflict)

// ── File → bundle key map ──────────────────────────────────────────────────
const SOUND_FILES: Record<string, string> = {
  listen:   'soundshelfstudio-ui-notification-listening-start.mp3',
  begin:    'jbl_begin_sae.caf',
  latency:  'jbl_latency_sae.caf',
  success:  'jbl_success_sae.caf',
  stopped:  'jbl_stopped_ios_sae.mp3',
  stop_reaching: 'soundshelfstudio-ui-notification-stop-reaching.wav',
};

export type RecordingMicrophoneSource = 'wearables' | 'phone';

export interface RecordingSessionResult {
  success: boolean;
  requestedSource?: RecordingMicrophoneSource;
  source?: RecordingMicrophoneSource;
  inputPort?: string;
  inputType?: string;
  fallbackReason?: string;
  availableInputs?: Array<{
    portName: string;
    portType: string;
  }>;
}

// ── Sound instances ────────────────────────────────────────────────────────
type SoundKey = keyof typeof SOUND_FILES;
const sounds: Partial<Record<SoundKey, Sound>> = {};
let latencyLooping = false;

/**
 * Tracks whether the listen sound is currently playing.
 * Prevents redundant .stop() calls on an already-finished Sound object,
 * which on iOS can produce brief audio artifacts ("beat" / replay glitch).
 */
let _listenPlaying = false;
/**
 * Generation counter for the latency loop.
 *
 * Each call to `_startLatencyLoop()` increments this and captures its own
 * snapshot. Every subsequent action (the deferred `s.play()` inside the
 * pre-flight `s.stop()` callback, the play-finish callback, etc.) compares
 * its captured generation against the current one — if they differ, this
 * action belongs to a SUPERSEDED generation and bails out silently.
 *
 * `stopLatencyLoop()` simply bumps the generation. That single action
 * invalidates every in-flight callback the previous start may have queued.
 * This pattern is the same one used by `SpeachesSentenceChunker.sessionId`
 * and is provably race-free without depending on stop-flag bookkeeping.
 *
 * Why the old flag-based guard wasn't enough:
 *   playThinkingStarted() cleared `latencyStopRequested = false` on every
 *   fresh start. If `stopLatencyLoop()` set the flag and then a NEW
 *   `playThinkingStarted()` fired before iOS had finished processing the
 *   stop, the new start would clear the flag — and any callbacks queued
 *   by the PREVIOUS start would now no longer be gated, letting the loop
 *   resurrect itself moments after the user reached the Ready state.
 *   This bug surfaced as "thinking sound keeps playing after output".
 */
let latencyGen = 0;

// ─────────────────────────────────────────────────────────────────────────────
// init — call once at app startup (e.g. in App.tsx useEffect)
// ─────────────────────────────────────────────────────────────────────────────
export const initSounds = (): Promise<void> => {
  return new Promise((resolve) => {
    // Set playback category ONCE before loading sounds (skip in glasses mode)
    _safeSetPlaybackCategory();

    const keys = Object.keys(SOUND_FILES) as SoundKey[];
    let loaded = 0;

    keys.forEach((key) => {
      const filename = SOUND_FILES[key];
      // Sound.MAIN_BUNDLE → looks in iOS app bundle / Android raw resources
      const s = new Sound(filename, Sound.MAIN_BUNDLE, (err) => {
        if (err) {
          console.warn(`⚠️ [SFX] Failed to load "${filename}":`, err.message);
        } else {
          console.log(`✅ [SFX] Loaded "${filename}"`);
          s.setVolume(1.0); // FIX: ensure max volume on media channel
          sounds[key] = s;
        }
        loaded++;
        if (loaded === keys.length) resolve();
      });
    });
  });
};

// ─────────────────────────────────────────────────────────────────────────────
// Internal — play a one-shot sound, optionally with a callback on finish
// Returns immediately so the caller is never blocked.
// ─────────────────────────────────────────────────────────────────────────────
const _playOnce = (key: SoundKey, onFinish?: () => void): void => {
  const s = sounds[key];
  if (!s) {
    console.warn(`⚠️ [SFX] Sound "${key}" not loaded — skipping`);
    onFinish?.();
    return;
  }
  // FIX: Re-assert Playback category before every play (skip in glasses mode).
  // Other modules (e.g. streaming TTS stop, voice recognition) may have
  // switched the category to Ambient/PlayAndRecord — this guarantees our
  // earcons always play at full media volume controlled by physical buttons.
  _safeSetPlaybackCategory();
  s.setVolume(1.0);
  // Reset to beginning before every play so rapid calls don't skip
  s.setCurrentTime(0);
  s.setNumberOfLoops(0); // one-shot
  s.play((success) => {
    if (!success) {
      console.warn(`⚠️ [SFX] Playback failed for "${key}"`);
    }
    onFinish?.();
  });
};

// ─────────────────────────────────────────────────────────────────────────────
// PUBLIC API
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Play when the app enters LISTENING state.
 * Resolves when the cue finishes so recording can start after the full sound.
 */
export const playListenSound = (): Promise<void> => {
  _listenPlaying = true;
  return new Promise((resolve) => _playOnce('listen', () => {
    _listenPlaying = false;
    resolve();
  }));
};

/**
 * Stop the listen sound if it is currently playing.
 * Guarded by _listenPlaying to avoid calling .stop() on an already-finished
 * Sound object, which on iOS produces brief audio artifacts.
 */
export const stopListenSound = (): Promise<void> => {
  return new Promise((resolve) => {
    const s = sounds.listen;
    if (!s || !_listenPlaying) {
      _listenPlaying = false;
      resolve();
      return;
    }
    _listenPlaying = false;
    s.stop(() => resolve());
  });
};

/**
 * Play when the user stops reaching manually or when it goes back to default.
 */
export const playStopReachingSound = (): Promise<void> => {
  return new Promise((resolve) => _playOnce('stop_reaching', resolve));
};

/**
 * Reset the iOS audio session from Playback → PlayAndRecord so that
 * Voice / SFSpeechRecognizer can acquire the microphone.
 *
 * MUST be called after playListenSound() and before Voice.start().
 * Without this, the earcon's Sound.setCategory('Playback', false) leaves
 * the session in exclusive-playback mode, which blocks recording.
 */
export const prepareForRecording = (): void => {
  Sound.setCategory('PlayAndRecord', false);
};

/**
 * Configure the audio session for the chosen recording microphone.
 *
 * Unlike prepareForRecording() (which just sets the category via
 * react-native-sound), this calls into native code to set:
 *   .playAndRecord + selected input + setActive(true)
 *
 * For the Meta Ray-Ban path, native code explicitly prefers Bluetooth HFP.
 * If no HFP mic is available, the result reports the fallback input.
 *
 * Returns the active input port info for logging/debugging.
 */
export const configureBluetoothRecordingSession = async (
  preferredSource: RecordingMicrophoneSource = 'wearables',
): Promise<RecordingSessionResult> => {
  if (Platform.OS !== 'ios') {
    // Fallback: just set PlayAndRecord without BT options
    Sound.setCategory('PlayAndRecord', false);
    return {
      success: true,
      requestedSource: preferredSource,
      source: 'phone',
      inputPort: 'builtin',
      inputType: 'builtin',
    };
  }

  try {
    if (ReachingModule?.configureRecordingSession) {
      const result = await ReachingModule.configureRecordingSession(preferredSource);
      return result;
    }

    if (preferredSource === 'wearables' && ReachingModule?.configureBluetoothRecordingSession) {
      const result = await ReachingModule.configureBluetoothRecordingSession();
      return {
        ...result,
        requestedSource: 'wearables',
        source: result?.source || 'wearables',
      };
    }

    Sound.setCategory('PlayAndRecord', false);
    return {
      success: true,
      requestedSource: preferredSource,
      source: 'phone',
      inputPort: 'iPhone microphone',
      inputType: 'builtin',
      fallbackReason: 'Native microphone source selection is unavailable; using the iPhone microphone.',
    };
  } catch (e: any) {
    console.warn('⚠️ [SFX] configureBluetoothRecordingSession failed:', e?.message);
    Sound.setCategory('PlayAndRecord', false);
    return {
      success: false,
      requestedSource: preferredSource,
      source: 'phone',
      fallbackReason: e?.message || 'Recording session configuration failed.',
    };
  }
};

export const configureRecordingSession = async (
  preferredSource: RecordingMicrophoneSource,
): Promise<RecordingSessionResult> => {
  try {
    const result = await configureBluetoothRecordingSession(preferredSource);
    return result;
  } catch (e: any) {
    return {
      success: false,
      requestedSource: preferredSource,
      source: 'phone',
      fallbackReason: e?.message || 'Recording session configuration failed.',
    };
  }
};

/**
 * Start the only thinking sound: the latency loop while waiting for backend/RTAB.
 *
 * NOTE: The listen sound is NOT stopped here — callers (handleVoiceCommand,
 * handleAutoSubmit) already call stopListenSound() before this function.
 * Calling sounds.listen?.stop() here was causing iOS AVAudioPlayer to
 * produce brief audio artifacts (the user-reported "beat" / listen-sound
 * replaying during the listening→thinking transition).
 */
export const playThinkingStarted = (): void => {
    // Ensure the listen flag is cleared (defensive, in case caller skipped stopListenSound).
    _listenPlaying = false;
    // Bump the generation so any in-flight callbacks from a previous loop
    // (e.g. a queued s.play() inside a pre-flight stop callback) are
    // considered superseded and silently bail out. This is the fundamental
    // race fix — no flag-clearing means no window for old callbacks to
    // accidentally proceed under our newly-fresh state.
    latencyGen++;
    _startLatencyLoop(latencyGen);
};

/**
 * Internal — start the latency loop.
 *
 * `myGen` is captured at call time. Every async hop inside this function
 * (the pre-flight `s.stop()` callback, the eventual `s.play()` completion)
 * checks `latencyGen === myGen` before doing anything observable. If
 * `stopLatencyLoop()` (or another `_startLatencyLoop()`) has bumped the
 * generation in the meantime, this generation's callbacks are no-ops.
 *
 * Why a generation counter is strictly better than the old `latencyStopRequested`
 * flag: the flag had to be CLEARED at the start of every fresh play, opening
 * a window during which callbacks from a previous (now-stopped) generation
 * could observe a cleared flag and incorrectly proceed. A monotonically
 * increasing counter has no such window — old generations are forever old.
 */
const _startLatencyLoop = (myGen: number): void => {
  const s = sounds.latency;
  if (!s) {
    console.warn('⚠️ [SFX] Latency sound not loaded');
    return;
  }
  if (latencyLooping) {
    // Already running. Either it's still our generation (no-op) or it's
    // a stale one — in which case the next stopLatencyLoop()/playThinkingStarted()
    // pair will reset things. Either way, do nothing here.
    return;
  }
  latencyLooping = true;
  // Re-assert Playback category + full volume before looping audio (skip in glasses mode)
  _safeSetPlaybackCategory();
  s.setVolume(1.0);
  // Defensive: ensure no previous play is still queued/active before we
  // restart. iOS treats stop() on an already-stopped sound as a no-op.
  s.stop(() => {
    // ── Generation guard: did stopLatencyLoop() fire between our outer
    //    s.stop() and this callback? If so, abort silently. ─────────────
    if (latencyGen !== myGen) {
      console.log(`[SFX] Latency play aborted — superseded (gen ${myGen} → ${latencyGen})`);
      latencyLooping = false;
      return;
    }
    s.setCurrentTime(0);
    s.setNumberOfLoops(-1); // infinite loop
    s.play((success) => {
      // Fired when play() is manually stopped or fails.
      latencyLooping = false;
      if (!success) {
        console.log('[SFX] Latency loop stopped');
      }
    });
  });
  console.log(`🔁 [SFX] Latency loop started (gen ${myGen})`);
};

/**
 * Stop the latency loop (call when backend response arrives).
 * Returns a Promise that resolves when the loop has fully stopped.
 *
 * Bumps the generation counter so every in-flight callback from the
 * previous generation becomes a no-op. Then calls s.stop() to silence
 * any audio that's currently playing on device.
 */
export const stopLatencyLoop = (): Promise<void> => {
  return new Promise((resolve) => {
    const s = sounds.latency;
    // Bump generation FIRST — invalidates any pending start-callbacks
    // that might still be racing toward s.play().
    latencyGen++;
    latencyLooping = false;
    if (!s) {
      resolve();
      return;
    }
    s.stop(() => {
      console.log('⏹️ [SFX] Latency loop stopped');
      // Defensive: a second stop 200ms later catches the edge case where
      // iOS processes a queued play() between our stop() and this callback.
      // The generation guard inside _startLatencyLoop should already prevent
      // this, but a belt-and-suspenders stop here is cheap and bullet-proof.
      setTimeout(() => {
        s.stop(() => {});
      }, 200);
      resolve();
    });
  });
};

/**
 * Play right before the TTS result is spoken.
 * Returns a Promise so the caller can await it before starting TTS.
 *
 * Usage:
 *   await stopLatencyLoop();
 *   await playSuccessChime();
 *   await iOSTts.speak(resultText);
 */
export const playSuccessChime = (): Promise<void> => {
  return new Promise((resolve) => {
    _playOnce('success', resolve);
  });
};

/**
 * Play when the backend returns an error.
 * Returns a Promise that resolves when the sound finishes playing,
 * so callers can await it before starting TTS (prevents AVSpeechSynthesizer
 * from stealing the audio session mid-playback and cutting the sound short).
 */
export const playErrorSound = (): Promise<void> => {
  return new Promise((resolve) => _playOnce('stopped', resolve));
};

/**
 * Play camera shutter sound manually.
 * Called immediately before takePhoto() to fix iPhone 16 / iOS 18 
 * where enableShutterSound no longer works reliably.
 *
 * Uses the "begin" tone as the shutter click (natural transition cue).
 * If you have a dedicated shutter file, swap 'begin' for 'shutter'.
 */
export const playShutterSound = (): void => {
  _playOnce('begin');
};

/**
 * Release all sounds — call when the main component unmounts.
 */
export const releaseSounds = (): void => {
  (Object.keys(sounds) as SoundKey[]).forEach((key) => {
    sounds[key]?.release();
    delete sounds[key];
  });
  latencyLooping = false;
  console.log('✅ [SFX] Sounds released');
};
