// src/services/SpeachesStreamingTTSClient.ts
// ----------------------------------------------------------------------
// Speaches Streaming TTS Client - React Native Compatible
// Uses XMLHttpRequest for streaming support
// ----------------------------------------------------------------------

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

interface AudioChunk {
  index: number;
  data: string; // base64
  filePath: string;
  sound: Sound | null;
  isPlaying: boolean;
}

class SpeachesStreamingTTSClient {
  private currentSound: Sound | null = null;
  private audioQueue: AudioChunk[] = [];
  private isProcessing: boolean = false;
  private isStopped: boolean = false;
  private currentIndex: number = 0;
  private xhr: XMLHttpRequest | null = null;
  private processingPromise: Promise<void> | null = null;

  constructor() {
    try {
      Sound.setCategory('Playback', false); // Don't mix with others
      console.log('✅ Audio category set to Playback in TTS constructor');
    } catch (error: any) {
      console.warn('⚠️ Failed to set audio category:', error);
    }
    
    console.log('✅ Speaches TTS Client initialized');
  }

  /**
   * Stream audio from Speaches API and play chunks as they arrive
   * Uses XMLHttpRequest for React Native compatibility
   */
  async synthesizeSpeechStreaming(text: string): Promise<void> {
    const trimmed = (text || '').trim();
    if (!trimmed) {
      console.warn('⚠️ No text provided for TTS');
      return;
    }

    // Reset state
    this.isStopped = false;
    this.audioQueue = [];
    this.currentIndex = 0;

    console.log('🌊 Starting streaming TTS:', trimmed.substring(0, 50) + '...');

    try {
      await this.streamAudioWithXHR(trimmed);
    } catch (error) {
      console.error('❌ Speaches streaming TTS error:', error);
      throw error;
    }
  }

  /**
   * Stream audio using XMLHttpRequest (React Native compatible)
   */
  private async streamAudioWithXHR(text: string): Promise<void> {
    return new Promise((resolve, reject) => {
      this.xhr = new XMLHttpRequest();

      const payload = {
        model: SPEACHES_CONFIG.model,
        input: text,
        voice: SPEACHES_CONFIG.voice,
        language: SPEACHES_CONFIG.language,
        response_format: SPEACHES_CONFIG.responseFormat,
        speed: SPEACHES_CONFIG.speed,
        sample_rate: SPEACHES_CONFIG.sampleRate,
        stream: true, // Enable streaming
      };

      console.log('📤 Sending streaming TTS request to:', SPEACHES_CONFIG.ttsUrl);

      this.xhr.open('POST', SPEACHES_CONFIG.ttsUrl, true);
      this.xhr.setRequestHeader('Content-Type', 'application/json');
      this.xhr.setRequestHeader('Accept', 'audio/mpeg');
      
      if (SPEACHES_CONFIG.apiKey) {
        this.xhr.setRequestHeader('Authorization', `Bearer ${SPEACHES_CONFIG.apiKey}`);
        this.xhr.setRequestHeader('X-API-Key', SPEACHES_CONFIG.apiKey);
      }

      // Set response type to handle binary data
      this.xhr.responseType = 'blob';

      let chunkIndex = 0;
      let receivedData: Uint8Array[] = [];

      // Start playback processor
      this.startPlaybackProcessor();

      // Handle progress for streaming chunks
      this.xhr.onprogress = async (event) => {
        if (this.isStopped) {
          this.xhr?.abort();
          return;
        }

        // For true streaming, we'd need chunked transfer encoding
        // Since we're getting a blob, we'll process it differently
        console.log(`📦 Receiving data... ${event.loaded} bytes`);
      };

      // Handle completion
      this.xhr.onload = async () => {
        if (this.xhr!.status === 200) {
          console.log('✅ Audio received successfully');
          
          // Get the blob response
          const blob = this.xhr!.response as Blob;
          
          // Convert blob to base64 for React Native Sound
          const reader = new FileReader();
          reader.onloadend = async () => {
            const base64 = (reader.result as string).split(',')[1];
            
            // Create a single audio chunk
            const chunk: AudioChunk = {
              index: chunkIndex++,
              data: base64,
              filePath: '',
              sound: null,
              isPlaying: false,
            };

            this.audioQueue.push(chunk);
            console.log(`📦 Audio chunk received (${blob.size} bytes)`);

            // Wait for playback to finish
            await this.waitForQueueToFinish();
            resolve();
          };
          reader.readAsDataURL(blob);
          
        } else {
          const error = new Error(`HTTP ${this.xhr!.status}: ${this.xhr!.statusText}`);
          console.error('❌ Request failed:', error);
          reject(error);
        }
      };

      this.xhr.onerror = () => {
        const error = new Error('Network request failed');
        console.error('❌ Network error:', error);
        reject(error);
      };

      this.xhr.onabort = () => {
        console.log('🛑 Request aborted');
        resolve();
      };

      // Send request
      this.xhr.send(JSON.stringify(payload));
    });
  }

  /**
   * Process and play audio chunks from queue
   */
  private async startPlaybackProcessor(): Promise<void> {
    if (this.isProcessing) return;

    this.isProcessing = true;

    this.processingPromise = (async () => {
      while (this.isProcessing || this.currentIndex < this.audioQueue.length) {
        if (this.isStopped) {
          break;
        }

        if (this.currentIndex < this.audioQueue.length) {
          const chunk = this.audioQueue[this.currentIndex];

          if (!chunk.sound) {
            try {
              await this.prepareChunk(chunk);
              await this.playChunk(chunk);
            } catch (error) {
              console.error(`❌ Error playing chunk ${chunk.index}:`, error);
            }

            this.currentIndex++;
          }
        } else {
          // Wait for more chunks
          await new Promise<void>(resolve => setTimeout(() => resolve(), 50));
        }
      }

      console.log('✅ Playback processor finished');
      this.isProcessing = false;
    })();
  }

  /**
   * Prepare audio chunk for playback
   */
  private async prepareChunk(chunk: AudioChunk): Promise<void> {
    const tempPath = `${RNFS.DocumentDirectoryPath}/tts_chunk_${chunk.index}_${Date.now()}.mp3`;
    chunk.filePath = tempPath;

    try {
      // Write chunk to file
      await RNFS.writeFile(tempPath, chunk.data, 'base64');

      // Load sound
      return new Promise((resolve, reject) => {
        chunk.sound = new Sound(tempPath, '', (error) => {
          if (error) {
            console.error(`❌ Failed to load chunk ${chunk.index}:`, error);
            reject(error);
            return;
          }
          console.log(`🎵 Chunk ${chunk.index} loaded`);
          resolve();
        });
      });
    } catch (error) {
      console.error(`❌ Failed to prepare chunk ${chunk.index}:`, error);
      throw error;
    }
  }

  /**
   * Play a single audio chunk
   */
  private async playChunk(chunk: AudioChunk): Promise<void> {
    if (!chunk.sound) {
      throw new Error(`Chunk ${chunk.index} has no sound`);
    }

    return new Promise((resolve) => {
      chunk.isPlaying = true;
      console.log(`▶️ Playing chunk ${chunk.index}...`);

      chunk.sound!.play((success) => {
        chunk.isPlaying = false;

        if (success) {
          console.log(`✅ Chunk ${chunk.index} finished`);
        } else {
          console.log(`❌ Chunk ${chunk.index} playback failed`);
        }

        // Cleanup
        chunk.sound?.release();
        
        // Delete temp file
        if (chunk.filePath) {
          RNFS.unlink(chunk.filePath).catch(() => {});
        }
        
        resolve();
      });
    });
  }

  /**
   * Wait for all queued audio to finish playing
   */
  private async waitForQueueToFinish(): Promise<void> {
    // Wait for processing to start
    while (!this.isProcessing && !this.isStopped) {
      await new Promise<void>(resolve => setTimeout(() => resolve(), 50));
    }

    // Wait for all chunks to be played
    while ((this.currentIndex < this.audioQueue.length || this.isProcessing) && !this.isStopped) {
      await new Promise<void>(resolve => setTimeout(() => resolve(), 100));
    }
  }

  /**
   * Stop streaming and all playback
   */
  async stop(): Promise<void> {
    console.log('🛑 Stopping Speaches TTS...');

    this.isStopped = true;

    if (this.currentSound) {
      try {
        this.currentSound.stop();
        this.currentSound.release();
        this.currentSound = null;
      } catch (error: any) {
        console.warn('⚠️ Error stopping sound:', error);
      }
    }

    // FIX: Do NOT reset to 'Ambient' here.
    // 'Ambient' routes audio to ringer volume — physical buttons stop working
    // and all subsequent sound effects play at near-silent levels.
    // Voice recognition (STT) manages its own audio session category when it
    // starts; we don't need to pre-emptively switch away from Playback.
    console.log('✅ TTS stopped successfully');
  }

  isPlaying(): boolean {
    return this.currentSound !== null;
  }

  reset(): void {
    this.isStopped = false;
  }
}

// Export singleton instance
export const speachesStreamingTTS = new SpeachesStreamingTTSClient();
