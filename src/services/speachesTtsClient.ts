// src/services/speachesTtsClient.ts
// ----------------------------------------------------------------------
// Speaches TTS Client for React Native
// Matches N8N workflow TTS configuration exactly
// ----------------------------------------------------------------------

import Sound from 'react-native-sound';
import RNFS from 'react-native-fs';
import { Buffer } from 'buffer';

/**
 * Configuration matching N8N TTS workflow
 */
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

/**
 * Speaches TTS Client
 */
class SpeachesTTSClient {
  private currentSound: Sound | null = null;
  private isPlaying: boolean = false;
  private currentTempPath: string | null = null;
  private playbackCancelled: boolean = false;  // ✅ Track if playback was cancelled

  constructor() {
    Sound.setCategory('Playback');
    console.log('✅ Speaches TTS Client initialized');
  }

  /**
   * Synthesize speech from text using Speaches API
   * 
   * @param text - Text to convert to speech
   * @returns Promise that resolves when audio FINISHES playing
   */
  async synthesizeSpeech(text: string): Promise<void> {
    const trimmed = (text || '').trim();
    if (!trimmed) {
      console.warn('⚠️ No text provided for TTS');
      return;
    }

    try {
      // ✅ Stop any current speech first
      await this.stop();

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

      console.log('📤 Sending TTS request to:', SPEACHES_CONFIG.ttsUrl);
      console.log('📝 Payload:', JSON.stringify(payload, null, 2));

      const response = await fetch(SPEACHES_CONFIG.ttsUrl, {
        method: 'POST',
        headers,
        body: JSON.stringify(payload),
      });

      if (!response.ok) {
        const errorBody = await response.text().catch(() => '');
        throw new Error(`Speaches TTS failed: ${response.status} ${errorBody}`);
      }

      const blob = await response.blob();
      console.log('✅ Received audio blob:', blob.size, 'bytes');

      // ✅ Convert blob to file and play - NOW WAITS UNTIL FINISHED!
      await this.playAudioBlob(blob);

    } catch (error) {
      console.error('❌ Speaches TTS error:', error);
      throw error;
    }
  }

  /**
   * Convert audio blob to file and play it
   * 
   * ✅ Returns a Promise that resolves when audio FINISHES playing
   */
  private async playAudioBlob(blob: Blob): Promise<void> {
    return new Promise(async (resolve, reject) => {
      try {
        this.playbackCancelled = false;  // ✅ Reset cancellation flag
        
        const base64 = await this.blobToBase64(blob);
        const tempPath = `${RNFS.DocumentDirectoryPath}/tts_speech_${Date.now()}.mp3`;
        this.currentTempPath = tempPath;  // ✅ Store temp path for cleanup
        
        await RNFS.writeFile(tempPath, base64, 'base64');
        console.log('💾 Saved audio to:', tempPath);

        this.currentSound = new Sound(tempPath, '', (error) => {
          if (error) {
            console.error('❌ Failed to load sound:', error);
            this.cleanup();
            reject(error);
            return;
          }

          // ✅ Check if cancelled before playing
          if (this.playbackCancelled) {
            console.log('⚠️ Playback cancelled before start');
            this.cleanup();
            resolve();
            return;
          }

          console.log('▶️ Playing audio...');
          this.isPlaying = true;

          // ✅ Play and wait for completion
          this.currentSound?.play((success) => {
            this.isPlaying = false;
            
            // ✅ Check if cancelled during playback
            if (this.playbackCancelled) {
              console.log('⚠️ Playback was cancelled');
              this.cleanup();
              resolve();
              return;
            }
            
            if (success) {
              console.log('✅ Playback finished');
            } else {
              console.log('❌ Playback failed');
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
   * Stop current speech playback
   * 
   * ✅ FIXED: Now properly stops audio without restarting
   */
  async stop(): Promise<void> {
    return new Promise((resolve) => {
      if (!this.currentSound && !this.isPlaying) {
        resolve();
        return;
      }

      console.log('🛑 Stopping TTS playback...');
      this.playbackCancelled = true;  // ✅ Set cancellation flag
      this.isPlaying = false;
      
      if (this.currentSound) {
        try {
          // ✅ Stop the sound immediately
          this.currentSound.stop(() => {
            // Callback after stop
            this.cleanup();
            console.log('✅ TTS stopped');
            resolve();
          });
        } catch (error) {
          // If stop() fails, still cleanup
          console.warn('⚠️ Error stopping sound:', error);
          this.cleanup();
          resolve();
        }
      } else {
        this.cleanup();
        resolve();
      }
    });
  }

  /**
   * Cleanup - release sound and delete temporary file
   */
  private cleanup(): void {
    // ✅ Release sound resources
    if (this.currentSound) {
      try {
        this.currentSound.release();
      } catch (error) {
        console.warn('⚠️ Error releasing sound:', error);
      }
      this.currentSound = null;
    }

    // ✅ Delete temporary audio file
    if (this.currentTempPath) {
      RNFS.unlink(this.currentTempPath).catch((err) => {
        console.warn('⚠️ Could not delete temp file:', err);
      });
      this.currentTempPath = null;
    }
  }

  /**
   * Convert Blob to Base64 string
   */
  private blobToBase64(blob: Blob): Promise<string> {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      
      reader.onload = () => {
        if (typeof reader.result === 'string') {
          const base64 = reader.result.split(',')[1];
          resolve(base64);
        } else {
          reject(new Error('Failed to convert blob to base64'));
        }
      };
      
      reader.onerror = reject;
      reader.readAsDataURL(blob);
    });
  }

  /**
   * Check if TTS is currently playing
   */
  isCurrentlyPlaying(): boolean {
    return this.isPlaying;
  }
}

// ✅ Export singleton instance
export const speachesTTS = new SpeachesTTSClient();