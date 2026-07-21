// src/services/iOSTtsClient.ts

import Tts from 'react-native-tts';
import { NativeEventEmitter, NativeModules, Platform } from 'react-native';
import {
  AppLanguage,
  LANGUAGE_LOCALES,
  getAppLanguage,
  onAppLanguageChange,
} from '../i18n';

// ========================================================================
// Event Emitter — fixes "Sending tts-finish with no listeners registered"
// ========================================================================
const TextToSpeechModule = NativeModules.TextToSpeech;
let ttsEmitter: NativeEventEmitter | null = null;

try {
  if (TextToSpeechModule) {
    ttsEmitter = new NativeEventEmitter(TextToSpeechModule);
    console.log('✅ TTS NativeEventEmitter created');
  } else {
    console.warn('⚠️ TextToSpeech native module not found');
  }
} catch (err: any) {
  console.warn('⚠️ Failed to create TTS NativeEventEmitter:', err.message);
}

// ========================================================================
// Voice preferences — ordered by quality (premium > enhanced > compact)
//
// Premium voices use Apple's Neural TTS engine and sound much more
// natural than enhanced voices. They require download but most
// accessibility users already have them installed.
//
// ⚠️  Your device has Zoe Premium installed but NOT Samantha Premium.
//     Keep both listed so whichever is available gets picked.
// ========================================================================
//
// Per-language preference lists. These are a best-effort fast path: a device
// only has the voices its owner downloaded, and Apple renames bundles between
// iOS releases. Whatever is missing falls through to _findVoiceForLanguage(),
// which picks the best-quality installed voice matching the language prefix,
// so an unfamiliar voice ID here degrades rather than breaks.
const PREFERRED_VOICES: Record<AppLanguage, string[]> = {
  en: [
    // Premium (Neural TTS) — most natural, closest to Siri quality
    'com.apple.voice.premium.en-US.Zoe',
    'com.apple.voice.premium.en-US.Samantha',
    // Enhanced — good quality, often pre-installed
    'com.apple.voice.enhanced.en-US.Samantha',
    'com.apple.voice.enhanced.en-US.Ava',
    'com.apple.voice.enhanced.en-AU.Karen',
    'com.apple.voice.enhanced.en-GB.Serena',
    // Compact — last resort
    'com.apple.voice.compact.en-US.Samantha',
  ],
  fr: [
    // Quebec French first — a Montreal user should not hear Paris French.
    'com.apple.voice.premium.fr-CA.Amelie',
    'com.apple.voice.enhanced.fr-CA.Amelie',
    'com.apple.voice.enhanced.fr-CA.Nicolas',
    'com.apple.voice.compact.fr-CA.Amelie',
    // European French — intelligible in Quebec, used only if no fr-CA voice
    // is installed.
    'com.apple.voice.premium.fr-FR.Thomas',
    'com.apple.voice.enhanced.fr-FR.Thomas',
    'com.apple.voice.enhanced.fr-FR.Marie',
    'com.apple.voice.compact.fr-FR.Thomas',
  ],
};

// ========================================================================
// Defaults
// ========================================================================
// Pitch 1.0 = natural. Previous 1.05 made Samantha sound slightly robotic.
const DEFAULT_SPEECH_PITCH = 1.0;

// iOS AVSpeechUtteranceDefaultSpeechRate = 0.5
// Range: 0.0 (slowest) to 1.0 (fastest)
// 0.5 is "normal" conversational speed
const DEFAULT_SPEECH_RATE = 0.5;

const SAFETY_TIMEOUT_MS = 30_000;

class IOSTtsClient {
  private _isPlaying = false;
  private _isStopped = false;
  private _initialized = false;
  private _initializing = false;
  private _selectedVoice: string | null = null;
  private _resolveSpeak: (() => void) | null = null;
  private _safetyTimer: ReturnType<typeof setTimeout> | null = null;
  private _subscriptions: Array<{ remove: () => void }> = [];

  // ── User-controllable settings ─────────────────────────────────────────
  private _speechRate: number = DEFAULT_SPEECH_RATE;
  private _speechPitch: number = DEFAULT_SPEECH_PITCH;

  constructor() {
    this._registerEventListeners();
    this._initializeAsync();

    // Re-pick a voice when the user switches language. Long-lived singleton,
    // so this subscription intentionally lives for the process.
    onAppLanguageChange(() => {
      void this._onLanguageChanged();
    });
  }

  /**
   * Cut off any in-flight utterance before re-selecting: the queued text is in
   * the previous language, and hearing half a sentence in the old voice is
   * more confusing than silence.
   */
  private async _onLanguageChanged(): Promise<void> {
    try {
      await this.stop();
    } catch (error: any) {
      console.warn('⚠️ TTS stop during language change failed:', error?.message);
    }
    await this._selectBestVoice();
  }

  // ========================================================================
  // Event registration — ONLY supported events
  // ========================================================================
  // Supported: tts-start, tts-finish, tts-pause, tts-resume,
  //            tts-progress, tts-cancel
  // NOT supported (CRASHES): tts-error
  // ========================================================================
  private _registerEventListeners(): void {
    if (!ttsEmitter) {
      console.warn('⚠️ No TTS emitter — will rely on safety timeout');
      return;
    }

    try {
      this._subscriptions.push(
        ttsEmitter.addListener('tts-finish', this._onFinish),
        ttsEmitter.addListener('tts-cancel', this._onCancel),
        // DO NOT add 'tts-error' — it is NOT supported and crashes the app
      );
      console.log('✅ TTS event listeners registered (finish, cancel)');
    } catch (err: any) {
      console.warn('⚠️ Failed to register TTS listeners:', err.message);
    }
  }

  // ========================================================================
  // Initialization
  // ========================================================================
  private async _initializeAsync(): Promise<void> {
    if (this._initialized || this._initializing) return;
    this._initializing = true;

    try {
      // *** DO NOT call Tts.setDefaultRate() ***
      // The native bridge method requires a BOOL param (skipTransform)
      // that doesn't convert on New Architecture / TurboModules.
      // Instead we pass rate per-utterance in Tts.speak() options.

      try { Tts.setDefaultPitch(this._speechPitch); } catch (e: any) {
        console.warn('⚠️ setDefaultPitch failed:', e.message);
      }

      try { Tts.setIgnoreSilentSwitch('ignore'); } catch (e: any) {
        console.warn('⚠️ setIgnoreSilentSwitch failed:', e.message);
      }

      await this._selectBestVoice();

      this._initialized = true;
      console.log(
        '✅ iOS TTS Client initialized',
        this._selectedVoice ? `(voice: ${this._selectedVoice})` : '(default voice)',
        `| rate: ${this._speechRate} | pitch: ${this._speechPitch}`,
      );
    } catch (error: any) {
      console.warn('⚠️ iOS TTS init warning:', error.message);
      this._initialized = true;
    } finally {
      this._initializing = false;
    }
  }

  // ========================================================================
  // Voice Selection
  // ========================================================================
  private async _selectBestVoice(): Promise<void> {
    if (Platform.OS !== 'ios') return;

    const language = getAppLanguage();

    try {
      const voices = await Tts.voices();
      const availableIds = new Set(voices.map((v: any) => v.id));

      // Log available voices for this language for debugging
      const matching = voices
        .filter((v: any) => v.language?.startsWith(language))
        .map((v: any) => `${v.id} (q:${v.quality})`);
      console.log(`📋 Available ${language} voices:`, matching.join(', '));

      // Try preferred voices in order (premium → enhanced → compact)
      for (const voiceId of PREFERRED_VOICES[language]) {
        if (availableIds.has(voiceId)) {
          try {
            await Tts.setDefaultVoice(voiceId);
            this._selectedVoice = voiceId;
            const tier = voiceId.includes('.premium.') ? 'PREMIUM'
              : voiceId.includes('.enhanced.') ? 'ENHANCED' : 'COMPACT';
            console.log(`🎤 Selected iOS voice: ${voiceId} [${tier}]`);
            return;
          } catch (e: any) {
            console.warn(`⚠️ setDefaultVoice failed for ${voiceId}:`, e.message);
          }
        }
      }

      // Fallback: best installed voice for this language (non-network).
      const fallback = this._findVoiceForLanguage(voices, language);

      if (fallback) {
        try {
          await Tts.setDefaultVoice(fallback.id);
          this._selectedVoice = fallback.id;
          console.log('🎤 Selected fallback voice:', fallback.id);
          return;
        } catch (e: any) {
          console.warn('⚠️ Fallback voice selection failed:', e.message);
        }
      }

      // No voice at all for this language. Clear any previously selected
      // voice so we do not read French text with an English voice — the
      // system default at least follows the utterance language.
      this._selectedVoice = null;
      console.log(
        `ℹ️ No ${language} voice installed — using iOS system default`,
      );
    } catch (error: any) {
      console.warn('⚠️ Voice selection failed:', error.message);
    }
  }

  /**
   * Best installed voice for a language, preferring the exact regional locale
   * (fr-CA) over other regions (fr-FR) and higher quality over lower.
   */
  private _findVoiceForLanguage(voices: any[], language: AppLanguage): any | null {
    const preferredLocale = LANGUAGE_LOCALES[language].tts.toLowerCase();

    const candidates = voices.filter(
      (v: any) =>
        typeof v.language === 'string' &&
        v.language.toLowerCase().startsWith(language) &&
        !v.networkConnectionRequired,
    );

    if (candidates.length === 0) return null;

    const score = (v: any): number => {
      const exactRegion = v.language.toLowerCase() === preferredLocale ? 1_000_000 : 0;
      return exactRegion + (typeof v.quality === 'number' ? v.quality : 0);
    };

    return candidates.reduce((best, v) => (score(v) > score(best) ? v : best));
  }

  // ========================================================================
  // Event Handlers
  // ========================================================================
  private _onFinish = (_event: any) => {
    console.log('✅ iOS TTS finished (event received)');
    this._resolvePending();
  };

  private _onCancel = (_event: any) => {
    console.log('🛑 iOS TTS cancelled (event received)');
    this._resolvePending();
  };

  private _resolvePending(): void {
    this._isPlaying = false;
    this._clearSafetyTimer();
    if (this._resolveSpeak) {
      this._resolveSpeak();
      this._resolveSpeak = null;
    }
  }

  // ========================================================================
  // Safety Timer
  // ========================================================================
  private _clearSafetyTimer(): void {
    if (this._safetyTimer) {
      clearTimeout(this._safetyTimer);
      this._safetyTimer = null;
    }
  }

  private _startSafetyTimer(): void {
    this._clearSafetyTimer();
    this._safetyTimer = setTimeout(() => {
      console.warn('⚠️ iOS TTS safety timeout — force-resolving');
      this._resolvePending();
    }, SAFETY_TIMEOUT_MS);
  }

  // ========================================================================
  // Public API — Speech Rate Control
  // ========================================================================

  /**
   * Set the speech rate for ALL subsequent TTS output.
   * Called by SettingsContext when the user moves the slider.
   *
   * @param rate - iOS AVSpeechUtterance rate (0.0–1.0, default 0.5)
   *
   * Maps to user-facing labels:
   *   0.42 = Slow       (relaxed, good for complex directions)
   *   0.50 = Normal     (conversational, iOS default)
   *   0.55 = Slightly Fast
   *   0.60 = Fast       (experienced users)
   *   0.65 = Very Fast  (power users)
   */
  setSpeechRate(rate: number): void {
    const clamped = Math.max(0.0, Math.min(1.0, rate));
    this._speechRate = clamped;
    console.log(`🎚️ TTS speech rate set to: ${clamped}`);
  }

  /** Get the current speech rate */
  getSpeechRate(): number {
    return this._speechRate;
  }

  /**
   * Set the speech pitch for ALL subsequent TTS output.
   * @param pitch - iOS pitch multiplier (0.5–2.0, default 1.0)
   */
  setSpeechPitch(pitch: number): void {
    const clamped = Math.max(0.5, Math.min(2.0, pitch));
    this._speechPitch = clamped;

    try { Tts.setDefaultPitch(clamped); } catch (e: any) {
      console.warn('⚠️ setDefaultPitch failed:', e.message);
    }
    console.log(`🎚️ TTS speech pitch set to: ${clamped}`);
  }

  // ========================================================================
  // Public API — Speak
  // ========================================================================

  async synthesizeSpeech(text: string): Promise<void> {
    const trimmed = (text || '').trim();
    if (!trimmed) {
      console.warn('⚠️ No text provided for iOS TTS');
      return;
    }

    if (!this._initialized) {
      await this._initializeAsync();
    }

    // Stop any in-progress speech
    await this.stop();
    this._isStopped = false;

    return new Promise<void>((resolve) => {
      this._resolveSpeak = resolve;
      this._isPlaying = true;
      this._startSafetyTimer();

      console.log(
        '🎤 iOS TTS speaking:',
        trimmed.substring(0, 50) + (trimmed.length > 50 ? '...' : ''),
        `[rate=${this._speechRate}]`,
      );

      // ── Per-utterance options ─────────────────────────────────────────
      // This is the KEY fix: rate is passed per-speak call, bypassing
      // the broken setDefaultRate() that crashes on New Architecture.
      //
      // iosVoiceId is a fallback — if setDefaultVoice() failed during
      // init, this ensures the voice is still applied per-utterance.
      const speakOptions = {
        rate: this._speechRate,
        ...(this._selectedVoice ? { iosVoiceId: this._selectedVoice } : {}),
      } as Parameters<typeof Tts.speak>[1];

      try {
        Tts.speak(trimmed, speakOptions);
      } catch (err: any) {
        console.error('❌ Tts.speak() error:', err);
        this._resolvePending();
      }
    });
  }

  // ========================================================================
  // Public API — Stop
  // ========================================================================

  async stop(): Promise<void> {
    this._clearSafetyTimer();

    if (!this._isPlaying && !this._resolveSpeak) return;

    console.log('🛑 Stopping iOS TTS...');
    this._isStopped = true;
    this._isPlaying = false;

    // Stop native AVSpeechSynthesizer immediately.
    // The BOOL→double patch in react-native-tts+4.1.1.patch ensures
    // this actually reaches the native stopSpeakingAtBoundary: call
    // on New Architecture. Without that patch, Tts.stop() silently
    // fails and speech continues in the background.
    try {
      await Tts.stop();
    } catch (error: any) {
      console.warn('⚠️ Tts.stop() error:', error.message,
        '— ensure patches/react-native-tts+4.1.1.patch is applied (npx patch-package)');
    }

    // Give native tts-cancel event 50ms to fire, then force-resolve
    await new Promise<void>((r) => setTimeout(r, 50));

    if (this._resolveSpeak) {
      console.log('🔧 Force-resolving pending speak promise');
      this._resolveSpeak();
      this._resolveSpeak = null;
    }

    console.log('✅ iOS TTS stopped');
  }

  // ========================================================================
  // Public API — Getters
  // ========================================================================

  isCurrentlyPlaying(): boolean {
    return this._isPlaying;
  }

  getSelectedVoice(): string | null {
    return this._selectedVoice;
  }
}

export const iOSTts = new IOSTtsClient();
export const speachesTTS = iOSTts;
