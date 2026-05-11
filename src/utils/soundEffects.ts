// src/utils/soundEffects.ts
// ─────────────────────────────────────────────────────────────────────────────
// CyberSight — iOS Sound Effects
//
// Five physical audio files replace verbal state announcements:
//
//   siri-begin-improved.caf    → Listening started  (Siri-style chime)
//   jbl_begin_sae.caf          → Thinking started   (replaces "Thinking" TTS)
//   jbl_latency_sae.caf        → Loops while waiting for backend response
//   jbl_success_sae.caf        → Right before speaking the result
//   jbl_stopped_ios_sae.mp3    → Error returned from backend
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

// ── Configure sound to play through the speaker, not earpiece ─────────────
// MUST be called before any Sound() constructors
// FIX: mixWithOthers = false → full volume, physical buttons control it.
// With mixWithOthers = true, iOS treats our audio as secondary and ducks it.
Sound.setCategory('Playback', false);

// ── File → bundle key map ──────────────────────────────────────────────────
// NOTE: "jbl_stopped,IOS_sae.mp3" has been RENAMED to "jbl_stopped_ios_sae.mp3"
// on disk. Do that rename before building.
const SOUND_FILES: Record<string, string> = {
  listen:   'siri-begin-improved.caf',
  begin:    'jbl_begin_sae.caf',
  latency:  'jbl_latency_sae.caf',
  success:  'jbl_success_sae.caf',
  stopped:  'jbl_stopped_ios_sae.mp3',  // ← renamed from "jbl_stopped,IOS_sae.mp3"
};

// ── Sound instances ────────────────────────────────────────────────────────
type SoundKey = keyof typeof SOUND_FILES;
const sounds: Partial<Record<SoundKey, Sound>> = {};
let latencyLooping = false;

// ─────────────────────────────────────────────────────────────────────────────
// init — call once at app startup (e.g. in App.tsx useEffect)
// ─────────────────────────────────────────────────────────────────────────────
export const initSounds = (): Promise<void> => {
  return new Promise((resolve) => {
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
  // FIX: Re-assert Playback category before every play.
  // Other modules (e.g. streaming TTS stop, voice recognition) may have
  // switched the category to Ambient/PlayAndRecord — this guarantees our
  // earcons always play at full media volume controlled by physical buttons.
  Sound.setCategory('Playback', false);
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
 * Replaces the "Listening" verbal announcement.
 */
export const playListenSound = (): void => {
  _playOnce('listen');
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
 * Play when the app enters THINKING state (photo taken, request sent).
 * Replaces the "Thinking" verbal announcement.
 * Immediately starts the latency loop AFTER the begin tone finishes.
 */
export const playThinkingStarted = (): void => {
    // As soon as "begin" finishes, start the latency loop
    _startLatencyLoop();
};

/**
 * Internal — start the latency loop. Called after "begin" sound finishes.
 *
 * Bug 4 hardening: a fast cycle (stopLatencyLoop → next cycle's
 * playThinkingStarted) could call this while iOS was still processing
 * the previous s.stop(), leaving the loop physically playing after a
 * later state transition to Ready. We now call s.stop() defensively
 * before every s.play() so any in-flight loop is guaranteed dead before
 * we restart it. iOS treats stop() on an already-stopped sound as a no-op.
 */
const _startLatencyLoop = (): void => {
  const s = sounds.latency;
  if (!s) {
    console.warn('⚠️ [SFX] Latency sound not loaded');
    return;
  }
  if (latencyLooping) return; // already running
  latencyLooping = true;
  // FIX: Re-assert Playback category + full volume before looping audio
  Sound.setCategory('Playback', false);
  s.setVolume(1.0);
  // Defensive: ensure no previous play is still queued/active before
  // we restart the loop. Prevents Bug 4 (latency surviving a recent stop).
  s.stop(() => {
    s.setCurrentTime(0);
    s.setNumberOfLoops(-1); // infinite loop
    s.play((success) => {
      // This callback fires when play() is manually stopped or fails
      latencyLooping = false;
      if (!success) {
        console.log('[SFX] Latency loop stopped');
      }
    });
  });
  console.log('🔁 [SFX] Latency loop started');
};

/**
 * Stop the latency loop (call when backend response arrives).
 * Returns a Promise that resolves when the loop has fully stopped.
 *
 * FIX: Always call s.stop() regardless of latencyLooping flag.
 * Previously, if the play callback fired early (e.g. audio session
 * contention) it set latencyLooping = false — then stopLatencyLoop()
 * would short-circuit and never call s.stop(), leaving the sound
 * physically playing on device.
 */
export const stopLatencyLoop = (): Promise<void> => {
  return new Promise((resolve) => {
    const s = sounds.latency;
    latencyLooping = false; // clear flag immediately — always
    if (!s) {
      resolve();
      return;
    }
    s.stop(() => {
      console.log('⏹️ [SFX] Latency loop stopped');
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