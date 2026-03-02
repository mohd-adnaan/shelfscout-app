// src/services/speachesTtsClient.ts

import Sound from 'react-native-sound';
import RNFS from 'react-native-fs';
import { Buffer } from 'buffer';

const SPEACHES_CONFIG = {
  ttsUrl: 'https://cybersight.cim.mcgill.ca/speaches/v1/audio/speech',
  model: 'speaches-ai/Kokoro-82M-v1.0-ONNX',
  voice: 'af_heart',
  language: 'en-us',
  responseFormat: 'mp3',
  speed: 1,
  sampleRate: 24000,
  apiKey: 'dev-test-key-change-in-production',
};

class SpeachesTTSClient {
  private currentSound: Sound | null = null;
  private isPlaying: boolean = false;
  private currentTempPath: string | null = null;
  private playbackCancelled: boolean = false;
  // ✅ FIX: AbortController to cancel in-flight fetch requests
  private currentAbortController: AbortController | null = null;

  constructor() {
    Sound.setCategory('Playback');
    console.log('✅ Speaches TTS Client initialized');
  }

  async synthesizeSpeech(text: string): Promise<void> {
    const trimmed = (text || '').trim();
    if (!trimmed) {
      console.warn('⚠️ No text provided for TTS');
      return;
    }

    try {
      // Stop previous playback first
      await this.stop();

      // ✅ FIX: Reset cancellation flag HERE (after stop, before fetch)
      //         NOT inside playAudioBlob — that was the bug
      this.playbackCancelled = false;

      console.log('🎤 Synthesizing speech:', trimmed.substring(0, 50) + '...');

      const payload = {
        model: SPEACHES_CONFIG.model,
        input: trimmed,
        voice: SPEACHES_CONFIG.voice,
        language: SPEACHES_CONFIG.language,
        response_format: SPEACHES_CONFIG.responseFormat,
        speed: SPEACHES_CONFIG.speed,
        sample_rate: SPEACHES_CONFIG.sampleRate,
      };

      const headers: Record<string, string> = {
        'accept': 'audio/mpeg',
        'Content-Type': 'application/json',
      };

      if (SPEACHES_CONFIG.apiKey) {
        headers['Authorization'] = `Bearer ${SPEACHES_CONFIG.apiKey}`;
        headers['X-API-Key'] = SPEACHES_CONFIG.apiKey;
      }

      // ✅ FIX: Create AbortController for this request so stop() can cancel it
      this.currentAbortController = new AbortController();

      console.log('📤 Sending TTS request to:', SPEACHES_CONFIG.ttsUrl);

      let response: Response;
      try {
        response = await fetch(SPEACHES_CONFIG.ttsUrl, {
          method: 'POST',
          headers,
          body: JSON.stringify(payload),
          signal: this.currentAbortController.signal, // ✅ FIX: Attach abort signal
        });
      } catch (fetchError: any) {
        // ✅ FIX: Fetch was aborted by stop() — silently return
        if (fetchError?.name === 'AbortError') {
          console.log('🛑 TTS fetch aborted by stop()');
          return;
        }
        throw fetchError;
      }

      // ✅ FIX: Check cancellation AFTER fetch completes (before playing)
      //         This handles the race where stop() fires mid-fetch
      if (this.playbackCancelled) {
        console.log('⚠️ Playback cancelled after fetch — skipping playback');
        return;
      }

      if (!response.ok) {
        const errorBody = await response.text().catch(() => '');
        throw new Error(`Speaches TTS failed: ${response.status} ${errorBody}`);
      }

      const blob = await response.blob();
      console.log('✅ Received audio blob:', blob.size, 'bytes');

      // ✅ FIX: Check again after blob read (async gap)
      if (this.playbackCancelled) {
        console.log('⚠️ Playback cancelled after blob read — skipping playback');
        return;
      }

      await this.playAudioBlob(blob);

    } catch (error) {
      console.error('❌ Speaches TTS error:', error);
      throw error;
    }
  }

  /**
   * Convert audio blob to file and play it.
   * ✅ FIX: Does NOT reset playbackCancelled — that is the caller's responsibility
   */
  private async playAudioBlob(blob: Blob): Promise<void> {
    return new Promise(async (resolve, reject) => {
      try {
        // ✅ FIX: No longer resets playbackCancelled here
        //         Flag is only reset at the top of synthesizeSpeech

        const base64 = await this.blobToBase64(blob);
        const tempPath = `${RNFS.DocumentDirectoryPath}/tts_speech_${Date.now()}.mp3`;
        this.currentTempPath = tempPath;

        await RNFS.writeFile(tempPath, base64, 'base64');
        console.log('💾 Saved audio to:', tempPath);

        // ✅ FIX: Guard before loading sound
        if (this.playbackCancelled) {
          console.log('⚠️ Cancelled before sound load');
          this.cleanupFile(tempPath);
          resolve();
          return;
        }

        this.currentSound = new Sound(tempPath, '', (error) => {
          if (error) {
            console.error('❌ Failed to load sound:', error);
            this.cleanup();
            reject(error);
            return;
          }

          // ✅ FIX: Guard before play
          if (this.playbackCancelled) {
            console.log('⚠️ Cancelled before play — releasing sound');
            this.cleanup();
            resolve();
            return;
          }

          console.log('▶️ Playing audio...');
          this.isPlaying = true;

          this.currentSound?.play((success) => {
            this.isPlaying = false;

            if (this.playbackCancelled) {
              console.log('⚠️ Playback was cancelled during play');
              this.cleanup();
              resolve();
              return;
            }

            if (success) {
              console.log('✅ Playback finished');
            } else {
              console.log('❌ Playback failed (interrupted or error)');
            }

            this.cleanup();
            resolve();
          });
        });

      } catch (error) {
        console.error('❌ Error playing audio:', error);
        this.cleanup();
        reject(error);
      }
    });
  }

  /**
   * Stop current speech playback immediately.
   * ✅ FIX: Also aborts any in-flight fetch request
   */
  async stop(): Promise<void> {
    return new Promise((resolve) => {
      console.log('🛑 Stopping TTS playback...');

      // ✅ FIX: Set cancelled FIRST before aborting fetch
      this.playbackCancelled = true;
      this.isPlaying = false;

      // ✅ FIX: Abort in-flight network request
      if (this.currentAbortController) {
        this.currentAbortController.abort();
        this.currentAbortController = null;
        console.log('🛑 Aborted in-flight TTS fetch');
      }

      if (this.currentSound) {
        try {
          this.currentSound.stop(() => {
            this.cleanup();
            console.log('✅ TTS stopped');
            resolve();
          });
        } catch (error) {
          console.warn('⚠️ Error stopping sound:', error);
          this.cleanup();
          resolve();
        }
      } else {
        resolve();
      }
    });
  }

  isCurrentlyPlaying(): boolean {
    return this.isPlaying;
  }

  private cleanup(): void {
    if (this.currentSound) {
      try {
        this.currentSound.release();
      } catch (e) {
        // ignore
      }
      this.currentSound = null;
    }

    if (this.currentTempPath) {
      this.cleanupFile(this.currentTempPath);
      this.currentTempPath = null;
    }
  }

  private cleanupFile(path: string): void {
    RNFS.unlink(path).catch(() => {});
  }

  private blobToBase64(blob: Blob): Promise<string> {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onloadend = () => {
        const dataUrl = reader.result as string;
        const base64 = dataUrl.split(',')[1];
        resolve(base64);
      };
      reader.onerror = reject;
      reader.readAsDataURL(blob);
    });
  }
}

export const speachesTTS = new SpeachesTTSClient();