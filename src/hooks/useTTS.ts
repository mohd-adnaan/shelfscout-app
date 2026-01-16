/**
 * src/hooks/useTTS.ts
 * 
 * WCAG 2.1 Level AA Compliant Text-to-Speech Hook
 * 
 * Compliance Features:
 * - 3.3.1 Error Identification: Clear, actionable error messages
 * - 4.1.3 Status Messages: Announces TTS state changes
 * - Proper error handling for blind users who depend on audio feedback
 * 
 * Uses Speaches API to match N8N workflow TTS configuration
 */

import { useEffect } from 'react';
import { Alert } from 'react-native';
import { speachesTTS } from '../services/speachesTtsClient';
import { AccessibilityService } from '../services/AccessibilityService';

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

    // Cleanup on unmount
    return () => {
      speachesTTS.stop().catch((err) => {
        console.warn('⚠️ TTS cleanup error:', err);
      });
    };
  }, []);

  /**
   * Speak the given text using Speaches TTS API
   * 
   * WCAG 3.3.1: Includes comprehensive error handling with clear messages
   * WCAG 4.1.3: Announces TTS state changes to screen reader
   * 
   * This function:
   * 1. Validates input text
   * 2. Stops any currently playing speech
   * 3. Sends text to Speaches API (https://cybersight.cim.mcgill.ca/audio/speech)
   * 4. Downloads the MP3 audio
   * 5. Plays the audio
   * 6. Announces errors if they occur
   * 
   * @param text - Text to convert to speech
   * @returns Promise that resolves when audio starts playing
   * @throws Error if TTS request fails (with user-friendly message)
   */
  const speak = async (text: string): Promise<void> => {
    try {
      // Validate input
      const trimmedText = (text || '').trim();
      
      if (!trimmedText) {
        console.warn('⚠️ No text provided for TTS');
        
        // WCAG 3.3.1: Clear error message
        const message = 'No text to speak. Please try again.';
        AccessibilityService.announceError(message, false);
        
        throw new Error(message);
      }

      console.log('🔊 Speaking with Speaches TTS (N8N config)...');
      console.log('📝 Text length:', trimmedText.length, 'characters');
      
      // WCAG 4.1.3: Announce that we're about to speak
      // (This is handled by the calling code, so we don't duplicate it here)
      
      await speachesTTS.synthesizeSpeech(trimmedText);
      
      console.log('✅ TTS playback started');
      
    } catch (error: any) {
      console.error('❌ TTS speak error:', error);
      
      // WCAG 3.3.1: Format error for users
      let userMessage = 'Failed to speak response.';
      
      if (error.message) {
        const errorMsg = error.message.toLowerCase();
        
        if (errorMsg.includes('network') || errorMsg.includes('connection')) {
          userMessage = 'Network error. Please check your internet connection and try again.';
        } else if (errorMsg.includes('timeout')) {
          userMessage = 'Request timed out. The speech server took too long to respond. Please try again.';
        } else if (errorMsg.includes('server') || errorMsg.includes('500')) {
          userMessage = 'Speech server error. Please try again later.';
        } else if (errorMsg.includes('audio') || errorMsg.includes('playback')) {
          userMessage = 'Audio playback error. Please check your device audio settings.';
        } else if (errorMsg.includes('permission')) {
          userMessage = 'Audio permission denied. Please enable audio permissions in Settings.';
        } else if (!errorMsg.includes('no text')) {
          // Include original error if it's not a validation error
          userMessage = `Failed to speak response: ${error.message}`;
        }
      }
      
      // WCAG 4.1.3: Announce error to screen reader
      AccessibilityService.announceError(userMessage, false);
      
      // Show visual alert for sighted users
      Alert.alert(
        'Text-to-Speech Error',
        userMessage + ' Please try again.',
        [{ text: 'OK', style: 'default' }]
      );
      
      // Re-throw with user-friendly message
      throw new Error(userMessage);
    }
  };

  /**
   * Stop current speech playback
   * 
   * WCAG 4.1.3: Announces when speech is stopped
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
      
      console.log('✅ TTS stopped successfully');
      
      // WCAG 4.1.3: Announce that speech was stopped
      // (This is handled by the calling code, so we don't duplicate it here)
      
    } catch (error: any) {
      console.error('❌ Stop error:', error);
      
      // WCAG 3.3.1: Don't announce stop errors - they're usually not critical
      // The audio will stop anyway when the app is closed or interrupted
      
      // Only log the error, don't throw or alert
      console.warn('⚠️ TTS stop failed, but continuing:', error.message);
    }
  };

  /**
   * Check if TTS is currently playing
   * 
   * @returns true if audio is currently playing, false otherwise
   */
  const isPlaying = (): boolean => {
    try {
      return speachesTTS.isCurrentlyPlaying();
    } catch (error: any) {
      console.warn('⚠️ Error checking TTS playing state:', error);
      // Return false if we can't determine state
      return false;
    }
  };

  return { speak, stop, isPlaying };
};