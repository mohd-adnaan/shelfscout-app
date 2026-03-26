// src/services/iOSNativeTTSClient.ts
//
// ⚠️ DEPRECATED — DO NOT IMPORT THIS FILE ⚠️
//
// This is an older TTS client with INCONSISTENT voice/rate behavior:
//   - Uses Tts.setDefaultRate(0.52) — hardcoded, ignores user's setting
//   - Selects voice by quality score, NOT by the explicit PREFERRED_VOICES list
//   - Does not use per-utterance rate (crashes on New Architecture)
//
// The canonical TTS singleton is:  import { speachesTTS } from './iOSTtsClient';
// That client uses Zoe Premium, per-utterance rate, and respects user settings.
//
// Kept for reference only. Will be removed in a future cleanup pass.

import Tts from 'react-native-tts';
import { Platform } from 'react-native';

class IOSNativeTTSClient {
  private selectedVoice: string | null = null;
  private isSpeaking: boolean = false;
  private initialized: boolean = false;
  private initPromise: Promise<void> | null = null;

  // ✅ THE FIX: store resolve so stop() can unblock synthesizeSpeech immediately
  private currentResolve: (() => void) | null = null;
  private currentCleanup: (() => void) | null = null;

  constructor() {
    if (Platform.OS === 'ios') {
      this.initPromise = this.init();
    }
  }

  private async init(): Promise<void> {
    try {
      await Tts.getInitStatus();
      await Tts.setDefaultLanguage('en-US');
      await Tts.setDefaultRate(0.52, false); // second arg prevents ObjC BOOL bridge error
      await Tts.setDefaultPitch(1.0);

      this.selectedVoice = await this.selectBestVoice();
      if (this.selectedVoice) {
        await Tts.setDefaultVoice(this.selectedVoice);
        console.log('✅ iOS TTS ready, voice:', this.selectedVoice);
      } else {
        console.warn('⚠️ No premium voice found — using system default');
      }

      this.initialized = true;
    } catch (error: any) {
      console.error('❌ iOS TTS init error:', error);
      this.initialized = true; // don't retry every utterance
    }
  }

  private async selectBestVoice(): Promise<string | null> {
    try {
      const voices = await Tts.voices();
      const english = voices.filter(
        (v) => v.language?.startsWith('en') && !v.notInstalled
      );
      if (english.length === 0) return null;

      // Highest quality first — premium (500+) > enhanced (400) > compact (300)
      const sorted = [...english].sort((a, b) => (b.quality ?? 0) - (a.quality ?? 0));
      const best = sorted[0];
      console.log(`🎤 Selected iOS voice: ${best.id} [q:${best.quality ?? 'unknown'}]`);
      return best.id;
    } catch (error: any) {
      console.warn('⚠️ getVoices() failed:', error.message);
      return null;
    }
  }

  /**
   * Speak text. Returns Promise that resolves when done OR when stop() is called.
   */
  async synthesizeSpeech(text: string): Promise<void> {
    const trimmed = (text || '').trim();
    if (!trimmed) return;

    if (!this.initialized && this.initPromise) {
      await this.initPromise;
    }

    // Stop anything currently playing first
    await this.stop();

    this.isSpeaking = true;

    return new Promise((resolve) => {
      let finishSub: any = null;
      let cancelSub: any = null;
      let errorSub: any = null;
      let settled = false;

      const cleanup = () => {
        if (settled) return;
        settled = true;
        try { finishSub?.remove(); } catch { /* ignore */ }
        try { cancelSub?.remove(); } catch { /* ignore */ }
        try { errorSub?.remove(); } catch { /* ignore */ }
        this.isSpeaking = false;
        // Clear stored refs so stop() doesn't double-call
        this.currentResolve = null;
        this.currentCleanup = null;
      };

      const done = () => {
        cleanup();
        resolve();
      };

      // ✅ Store so stop() can call them directly — no dependency on tts-cancel firing
      this.currentResolve = done;
      this.currentCleanup = cleanup;

      finishSub = Tts.addEventListener('tts-finish', done);
      cancelSub = Tts.addEventListener('tts-cancel', done);
      errorSub  = Tts.addEventListener('tts-error', (e: any) => {
        console.error('❌ iOS TTS speak error:', e);
        done();
      });

      Tts.speak(trimmed);
    });
  }

  /**
   * Stop immediately.
   * ✅ Directly resolves any pending synthesizeSpeech Promise — no event dependency.
   */
  async stop(): Promise<void> {
    this.isSpeaking = false;

    // ✅ Unblock the awaiting synthesizeSpeech call RIGHT NOW
    if (this.currentResolve) {
      const resolve = this.currentResolve;
      if (this.currentCleanup) this.currentCleanup();
      resolve();
    }

    try {
      await Tts.stop();
    } catch (error: any) {
      console.warn('⚠️ TTS stop error (non-critical):', error.message);
    }
  }

  isCurrentlyPlaying(): boolean {
    return this.isSpeaking;
  }
}

export const iOSNativeTTS = new IOSNativeTTSClient();