// src/services/speaches/speachesTTS.ts
import Sound from 'react-native-sound';
import RNFS from 'react-native-fs';

// ✅ Configuration (match your web app config)
const SPEACHES_CONFIG = {
  baseUrl: '', // ⚠️ UPDATE THIS!
  apiKey: 'your-api-key-here', // ⚠️ UPDATE THIS!
  model: 'tts-1', // Match config.api.speachesTtsModel
  voice: 'alloy', // Match config.api.speachesTtsVoice
  format: 'mp3', // Match config.api.speachesTtsFormat
  sampleRate: 24000, // Match config.api.speachesTtsSampleRate
};

class SpeachesTTSService {
  private currentSound: Sound | null = null;
  private isInitialized = false;

  constructor() {
    // ✅ Configure sound to play even when phone is in silent mode
    Sound.setCategory('Playback');
    this.isInitialized = true;
  }

  /**
   * Build Speaches URL (matches buildSpeachesUrl from web)
   */
  private buildSpeachesUrl(preferredUrl?: string, fallbackPath = ''): string {
    const explicit = (preferredUrl || '').trim();
    if (explicit) {
      return explicit;
    }

    const base = (SPEACHES_CONFIG.baseUrl || '/speaches').trim() || '/speaches';
    const normalizedBase = base.endsWith('/') ? base.slice(0, -1) : base;
    const normalizedPath = fallbackPath
      ? fallbackPath.startsWith('/')
        ? fallbackPath
        : `/${fallbackPath}`
      : '';

    return `${normalizedBase}${normalizedPath}`;
  }

  /**
   * Build Speaches headers (matches buildSpeachesHeaders from web)
   */
  private buildSpeachesHeaders(extra: Record<string, string> = {}): Record<string, string> {
    const headers: Record<string, string> = { ...extra };

    const apiKey = SPEACHES_CONFIG.apiKey;
    if (apiKey) {
      headers.Authorization = `Bearer ${apiKey}`;
      headers['X-API-Key'] = apiKey;
      console.log('[Speaches] Using configured API key');
    } else {
      console.warn('[Speaches] API key missing; requests may fail');
    }

    return headers;
  }

  /**
   * Synthesize speech (matches synthesizeSpeech from web)
   */
  async synthesizeSpeech(text: string): Promise<Blob | null> {
    const trimmed = (text || '').trim();
    if (!trimmed) {
      console.warn('No text provided for TTS');
      return null;
    }

    const ttsUrl = this.buildSpeachesUrl(
      undefined,
      '/v1/audio/speech'
    );

    const payload = {
      model: SPEACHES_CONFIG.model,
      voice: SPEACHES_CONFIG.voice,
      format: SPEACHES_CONFIG.format,
      sample_rate: SPEACHES_CONFIG.sampleRate,
      input: trimmed,
    };

    const response = await fetch(ttsUrl, {
      method: 'POST',
      headers: this.buildSpeachesHeaders({
        'content-type': 'application/json',
      }),
      body: JSON.stringify(payload),
    });

    if (!response.ok) {
      const errorBody = await response.text().catch(() => '');
      throw new Error(`Speaches TTS failed: ${response.status} ${errorBody}`);
    }

    return await response.blob();
  }

  /**
   * Speak text using Speaches TTS
   */
  async speak(text: string): Promise<void> {
    try {
      console.log('🔊 Speaches TTS: Speaking...', text.substring(0, 50) + '...');

      // ✅ Stop any current speech
      await this.stop();

      // ✅ Get audio blob from Speaches API
      const audioBlob = await this.synthesizeSpeech(text);
      if (!audioBlob) {
        console.warn('⚠️ No audio blob returned');
        return;
      }

      // ✅ Convert blob to base64
      const base64Audio = await this.blobToBase64(audioBlob);

      // ✅ Save to temp file
      const audioPath = `${RNFS.DocumentDirectoryPath}/speaches-tts-${Date.now()}.mp3`;
      await RNFS.writeFile(audioPath, base64Audio, 'base64');

      // ✅ Play the audio
      this.currentSound = new Sound(audioPath, '', (error) => {
        if (error) {
          console.error('❌ Failed to load sound:', error);
          return;
        }

        console.log('▶️ Playing Speaches TTS audio');
        this.currentSound?.play((success) => {
          if (success) {
            console.log('✅ Speaches TTS finished playing');
          } else {
            console.error('❌ Playback failed');
          }

          // ✅ Cleanup
          this.currentSound?.release();
          this.currentSound = null;

          // ✅ Delete temp file
          RNFS.unlink(audioPath).catch(() => {});
        });
      });
    } catch (error) {
      console.error('❌ Speaches TTS error:', error);
      throw error;
    }
  }

  /**
   * Stop current speech
   */
  async stop(): Promise<void> {
    if (this.currentSound) {
      console.log('🛑 Stopping Speaches TTS');
      this.currentSound.stop(() => {
        this.currentSound?.release();
        this.currentSound = null;
      });
    }
  }

  /**
   * Convert blob to base64
   */
  private blobToBase64(blob: Blob): Promise<string> {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onloadend = () => {
        const base64 = (reader.result as string).split(',')[1];
        resolve(base64);
      };
      reader.onerror = reject;
      reader.readAsDataURL(blob);
    });
  }
}

// ✅ Export singleton instance
export const speachesTTS = new SpeachesTTSService();