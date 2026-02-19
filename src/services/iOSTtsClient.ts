// src/services/iOSTtsClient.ts

import Tts from 'react-native-tts';
import { NativeEventEmitter, NativeModules, Platform } from 'react-native';

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
// Voice preferences — warm female voices matching Kokoro "af_heart"
// ========================================================================
const PREFERRED_VOICES = [
  'com.apple.voice.enhanced.en-US.Samantha',
  //'com.apple.voice.premium.en-US.Zoe',
  //'com.apple.voice.premium.en-US.Samantha',
  //'com.apple.voice.enhanced.en-US.Ava',
  //'com.apple.voice.enhanced.en-AU.Karen',
  //'com.apple.voice.enhanced.en-GB.Serena',
  //'com.apple.voice.compact.en-US.Samantha',
];

const SPEECH_PITCH = 1.05;
const SAFETY_TIMEOUT_MS = 30000;

class IOSTtsClient {
  private _isPlaying = false;
  private _isStopped = false;
  private _initialized = false;
  private _initializing = false; // guard against concurrent init
  private _selectedVoice: string | null = null;
  private _resolveSpeak: (() => void) | null = null;
  private _safetyTimer: ReturnType<typeof setTimeout> | null = null;
  private _subscriptions: Array<{ remove: () => void }> = [];

  constructor() {
    this._registerEventListeners();
    this._initializeAsync();
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
      // The native bridge method requires a BOOL param that doesn't
      // convert on New Architecture. iOS default rate = 0.5 which
      // is exactly what we want.

      try { Tts.setDefaultPitch(SPEECH_PITCH); } catch (e: any) {
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
      );
    } catch (error: any) {
      console.warn('⚠️ iOS TTS init warning:', error.message);
      this._initialized = true; // still mark done so we don't retry
    } finally {
      this._initializing = false;
    }
  }

  // ========================================================================
  // Voice Selection
  // ========================================================================
  private async _selectBestVoice(): Promise<void> {
    if (Platform.OS !== 'ios') return;

    try {
      const voices = await Tts.voices();
      const availableIds = new Set(voices.map((v: any) => v.id));

      for (const voiceId of PREFERRED_VOICES) {
        if (availableIds.has(voiceId)) {
          await Tts.setDefaultVoice(voiceId);
          this._selectedVoice = voiceId;
          console.log('🎤 Selected iOS voice:', voiceId);
          return;
        }
      }

      // Fallback: any English enhanced voice
      const englishEnhanced = voices.find(
        (v: any) =>
          v.language?.startsWith('en') &&
          v.quality != null &&
          v.quality >= 300 &&
          !v.networkConnectionRequired,
      );

      if (englishEnhanced) {
        await Tts.setDefaultVoice(englishEnhanced.id);
        this._selectedVoice = englishEnhanced.id;
        console.log('🎤 Selected fallback enhanced voice:', englishEnhanced.id);
        return;
      }

      console.log('ℹ️ No enhanced voice found — using iOS default');
    } catch (error: any) {
      console.warn('⚠️ Voice selection failed:', error.message);
    }
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
  // Public API
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

      console.log('🎤 iOS TTS speaking:', trimmed.substring(0, 50) + (trimmed.length > 50 ? '...' : ''));

      Tts.speak(trimmed).catch((err: any) => {
        console.error('❌ Tts.speak() error:', err);
        this._resolvePending();
      });
    });
  }

  async stop(): Promise<void> {
    this._clearSafetyTimer();

    if (!this._isPlaying && !this._resolveSpeak) return;

    console.log('🛑 Stopping iOS TTS...');
    this._isStopped = true;
    this._isPlaying = false;

    try {
      await Tts.stop();
    } catch (error: any) {
      // Tts.stop() may throw BOOL conversion error — non-fatal,
      // native side still stops speech
      console.warn('⚠️ Tts.stop() error (non-fatal):', error.message);
    }

    // Give native cancel event 50ms to fire, then force-resolve
    await new Promise<void>((r) => setTimeout(r, 50));

    if (this._resolveSpeak) {
      console.log('🔧 Force-resolving pending speak promise');
      this._resolveSpeak();
      this._resolveSpeak = null;
    }

    console.log('✅ iOS TTS stopped');
  }

  isCurrentlyPlaying(): boolean {
    return this._isPlaying;
  }

  getSelectedVoice(): string | null {
    return this._selectedVoice;
  }
}

// Singleton
export const iOSTts = new IOSTtsClient();
export const speachesTTS = iOSTts;