// src/hooks/useTTS.ts
// ----------------------------------------------------------------------
// Text-to-Speech Hook using Speaches API
// Matches N8N workflow TTS configuration
// ----------------------------------------------------------------------

import { useEffect } from 'react';
import { speachesTTS } from '../services/speachesTtsClient';

/**
 * Text-to-Speech Hook
 * 
 * Provides TTS functionality using the Speaches API, matching the exact
 * configuration used in your N8N workflow. This ensures consistent voice
 * quality across web app, mobile app, and backend workflows.
 * 
 * Usage:
 * ```typescript
 * const { speak, stop, isPlaying } = useTTS();
 * 
 * // Speak some text
 * await speak("Hello, world!");
 * 
 * // Stop current speech
 * await stop();
 * 
 * // Check if playing
 * if (isPlaying()) {
 *   console.log("TTS is speaking");
 * }
 * ```
 */
export const useTTS = () => {
  useEffect(() => {
    console.log('✅ Speaches TTS ready (N8N config)');

    // ✅ Cleanup on unmount
    return () => {
      speachesTTS.stop().catch((err) => {
        console.warn('TTS cleanup error:', err);
      });
    };
  }, []);

  /**
   * Speak the given text using Speaches TTS API
   * 
   * This function:
   * 1. Stops any currently playing speech
   * 2. Sends text to Speaches API (https://cybersight.cim.mcgill.ca/audio/speech)
   * 3. Downloads the MP3 audio
   * 4. Plays the audio
   * 
   * @param text - Text to convert to speech
   * @returns Promise that resolves when audio starts playing
   * @throws Error if TTS request fails
   */
  const speak = async (text: string): Promise<void> => {
    try {
      console.log('🔊 Speaking with Speaches TTS (N8N config)...');
      await speachesTTS.synthesizeSpeech(text);
    } catch (error) {
      console.error('❌ TTS speak error:', error);
      throw error;
    }
  };

  /**
   * Stop current speech playback
   * 
   * This immediately stops any audio that is currently playing.
   * Unlike native iOS TTS, this stop method is reliable and fast.
   * 
   * @returns Promise that resolves when audio is stopped
   */

  const stop = async (): Promise<void> => {
    try {
      console.log('🛑 Stopping Speaches TTS...');
      await speachesTTS.stop();
    } catch (error) {
      console.error('❌ Stop error:', error);
    }
  };

  /**
   * Check if TTS is currently playing
   * 
   * @returns true if audio is currently playing, false otherwise
   */

  const isPlaying = (): boolean => {
    return speachesTTS.isCurrentlyPlaying();
  };

  return { speak, stop, isPlaying };
};