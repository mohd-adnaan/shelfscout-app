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
 * 
 * N8N Workflow URL (internal): http://speaches:8000/v1/audio/speech
 * Public URL (mobile app): https://cybersight.cim.mcgill.ca/audio/speech
 * 
 * Model: Kokoro-82M-v1.0-ONNX-int8 (8-bit quantized for faster inference)
 * Voice: af_heart (natural, expressive female voice)
 * Language: en-us (English - US)
 * Format: MP3 at 24kHz sample rate
 * Speed: 1x (normal playback)
 */
const SPEACHES_CONFIG = {
  ttsUrl: 'https://cybersight.cim.mcgill.ca/speaches/v1/audio/speech',
  
  // ✅ REMOVE -int8 SUFFIX
  model: 'speaches-ai/Kokoro-82M-v1.0-ONNX',  // ← No -int8!
  
  voice: 'af_heart',
  language: 'en-us',
  responseFormat: 'mp3',
  speed: 1,
  sampleRate: 24000,
  
  // ✅ ADD YOUR API KEY
  apiKey: 'dev-test-key-change-in-production',
};

/**
 * Speaches TTS Client
 * 
 * Synthesizes speech using the same Speaches API as your N8N workflow.
 * Downloads MP3 audio and plays it using react-native-sound for reliable
 * playback control (stop, pause, etc.)
 */
class SpeachesTTSClient {
  private currentSound: Sound | null = null;
  private isPlaying: boolean = false;

  constructor() {
    // ✅ Configure Sound to play even in iOS silent mode
    Sound.setCategory('Playback');
    console.log('✅ Speaches TTS Client initialized');
  }

  /**
   * Synthesize speech from text using Speaches API
   * 
   * @param text - Text to convert to speech
   * @returns Promise that resolves when audio starts playing
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

      // ✅ Build request payload (EXACT match to N8N workflow)
      const payload = {
        model: SPEACHES_CONFIG.model,
        input: trimmed,
        voice: SPEACHES_CONFIG.voice,
        language: SPEACHES_CONFIG.language,
        response_format: SPEACHES_CONFIG.responseFormat,
        speed: SPEACHES_CONFIG.speed,
        sample_rate: SPEACHES_CONFIG.sampleRate,
      };

      // ✅ Build headers (matches N8N workflow)
      const headers: Record<string, string> = {
        'accept': 'audio/mpeg',
        'Content-Type': 'application/json',
      };

      // ✅ Add API key if configured
      if (SPEACHES_CONFIG.apiKey) {
        headers['Authorization'] = `Bearer ${SPEACHES_CONFIG.apiKey}`;
        headers['X-API-Key'] = SPEACHES_CONFIG.apiKey;
      }

      console.log('📤 Sending TTS request to:', SPEACHES_CONFIG.ttsUrl);
      console.log('📝 Payload:', JSON.stringify(payload, null, 2));

      // ✅ Make API request
      const response = await fetch(SPEACHES_CONFIG.ttsUrl, {
        method: 'POST',
        headers,
        body: JSON.stringify(payload),
      });

      // ✅ Check response status
      if (!response.ok) {
        const errorBody = await response.text().catch(() => '');
        throw new Error(`Speaches TTS failed: ${response.status} ${errorBody}`);
      }

      // ✅ Get audio blob from response
      const blob = await response.blob();
      console.log('✅ Received audio blob:', blob.size, 'bytes');

      // ✅ Convert blob to file and play
      await this.playAudioBlob(blob);

    } catch (error) {
      console.error('❌ Speaches TTS error:', error);
      throw error;
    }
  }

  /**
   * Convert audio blob to file and play it
   * 
   * @param blob - Audio blob from Speaches API
   */
  private async playAudioBlob(blob: Blob): Promise<void> {
    try {
      // ✅ Convert blob to base64 for file writing
      const base64 = await this.blobToBase64(blob);

      // ✅ Create temporary file path
      const tempPath = `${RNFS.DocumentDirectoryPath}/tts_speech_${Date.now()}.mp3`;
      
      // ✅ Write audio data to file
      await RNFS.writeFile(tempPath, base64, 'base64');
      console.log('💾 Saved audio to:', tempPath);

      // ✅ Load audio file with react-native-sound
      this.currentSound = new Sound(tempPath, '', (error) => {
        if (error) {
          console.error('❌ Failed to load sound:', error);
          this.cleanup(tempPath);
          return;
        }

        console.log('▶️ Playing audio...');
        this.isPlaying = true;

        // ✅ Play the audio
        this.currentSound?.play((success) => {
          this.isPlaying = false;
          if (success) {
            console.log('✅ Playback finished');
          } else {
            console.log('❌ Playback failed');
          }

          // ✅ Cleanup after playback
          this.cleanup(tempPath);
        });
      });

    } catch (error) {
      console.error('❌ Error playing audio:', error);
      throw error;
    }
  }

  /**
   * Stop current speech playback
   * 
   * @returns Promise that resolves when audio is stopped
   */
  async stop(): Promise<void> {
    return new Promise((resolve) => {
      if (this.currentSound && this.isPlaying) {
        console.log('🛑 Stopping TTS playback...');
        
        this.currentSound.stop(() => {
          this.isPlaying = false;
          console.log('✅ TTS stopped');
          resolve();
        });
      } else {
        resolve();
      }
    });
  }

  /**
   * Cleanup - release sound and delete temporary file
   * 
   * @param tempPath - Path to temporary audio file
   */
  private cleanup(tempPath: string): void {
    // ✅ Release sound resources
    if (this.currentSound) {
      this.currentSound.release();
      this.currentSound = null;
    }

    // ✅ Delete temporary audio file
    RNFS.unlink(tempPath).catch((err) => {
      console.warn('⚠️ Could not delete temp file:', err);
    });
  }

  /**
   * Convert Blob to Base64 string
   * 
   * @param blob - Audio blob to convert
   * @returns Promise resolving to base64 string
   */
  private blobToBase64(blob: Blob): Promise<string> {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      
      reader.onload = () => {
        if (typeof reader.result === 'string') {
          // ✅ Extract base64 data (remove data URL prefix)
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
   * 
   * @returns true if audio is playing, false otherwise
   */
  isCurrentlyPlaying(): boolean {
    return this.isPlaying;
  }
}

// ✅ Export singleton instance
export const speachesTTS = new SpeachesTTSClient();