// src/utils/soundEffects.ts

import { Platform } from 'react-native';
import { iOSTts } from '../services/iOSTtsClient';

/**
 * Play audio feedback sounds for different states
 * 
 * WCAG 1.4.2: Audio feedback is supplementary, not required
 * WCAG 3.3.1: Errors handled gracefully without crashing app
 * 
 * Uses console logging for state audio cues.
 * If this fails, app continues to work - audio is optional enhancement.
 * 
 * @param type - Type of sound to play
 */
export const playSound = async (type: 'start' | 'stop' | 'processing'): Promise<void> => {
  try {
    // WCAG 1.4.2: Audio feedback is supplementary
    // If this fails, app continues to work - don't announce errors
    
    if (Platform.OS === 'ios') {
      switch (type) {
        case 'start':
          console.log('[Audio] 🔊 Feedback: Microphone ON');
          break;
          
        case 'stop':
          console.log('[Audio] 🔊 Feedback: Microphone OFF');
          break;
          
        case 'processing':
          console.log('[Audio] 🔊 Feedback: Thinking...');
          break;
          
        default:
          console.warn('[Audio] ⚠️ Unknown sound type:', type);
          break;
      }
    } else {
      console.log(`[Audio] 🔊 Feedback: ${type}`);
    }
    
  } catch (error: any) {
    // WCAG 3.3.1: Handle sound errors gracefully
    console.warn('[Audio] ⚠️ Sound effect error:', error.message || error);
  }
};

/**
 * Play success sound
 * 
 * WCAG 1.4.2: Optional audio enhancement
 * 
 * ✅ Routes through iOSTts singleton so the user's speech rate setting
 *    from SettingsContext is automatically applied.
 * 
 * @param message - Optional success message to speak
 */
export const playSuccessSound = async (message?: string): Promise<void> => {
  try {
    console.log('[Audio] ✅ Success sound');
    
    if (message) {
      try {
        // ✅ Use singleton — respects user's rate setting, no BOOL crash
        await iOSTts.synthesizeSpeech(message);
      } catch (ttsError: any) {
        console.warn('[Audio] TTS error:', ttsError.message);
        // Don't crash - TTS is optional
      }
    }
    
  } catch (error: any) {
    console.warn('[Audio] Success sound error:', error.message || error);
    // Don't crash - audio is supplementary
  }
};

/**
 * Play error sound
 * 
 * WCAG 1.4.2: Optional audio enhancement
 */
export const playErrorSound = async (): Promise<void> => {
  try {
    console.log('[Audio] ❌ Error sound');
  } catch (error: any) {
    console.warn('[Audio] Error sound failed:', error.message || error);
  }
};

/**
 * Stop any currently playing sounds
 * 
 * WCAG 1.4.2: Users can control audio
 * 
 * ✅ Routes through iOSTts singleton — catches BOOL error internally.
 */
export const stopAllSounds = async (): Promise<void> => {
  try {
    console.log('[Audio] 🛑 Stopping all sounds');
    
    // ✅ Use singleton — Tts.stop() BOOL crash handled inside
    await iOSTts.stop();
    
  } catch (error: any) {
    console.warn('[Audio] Stop sounds error:', error.message || error);
    // Don't crash
  }
};

/**
 * Check if TTS is available
 * 
 * @returns boolean - always true since iOSTts singleton is always available
 */
export const isTTSAvailable = (): boolean => {
  return true;
};

/**
 * Initialize audio system
 * 
 * WCAG 3.3.1: Initialization errors handled gracefully
 * 
 * ✅ No direct Tts calls — iOSTts singleton handles all setup in its
 *    constructor (voice selection, pitch, ignoreSilentSwitch).
 *    Rate is applied per-utterance, so no setDefaultRate() needed.
 */
export const initializeAudio = async (): Promise<boolean> => {
  try {
    console.log('[Audio] Initializing audio system...');
    
    // iOSTts singleton auto-initializes in its constructor.
    // Voice selection, pitch, and silent switch are all handled there.
    // Speech rate is controlled by SettingsContext → iOSTts.setSpeechRate().
    // No direct Tts.setDefaultRate() / setDefaultLanguage() calls needed.
    
    console.log('[Audio] ✅ Audio system initialized (via iOSTts singleton)');
    return true;
    
  } catch (error: any) {
    console.warn('[Audio] Initialization error:', error.message || error);
    return false;
  }
};

/**
 * Clean up audio resources
 * 
 * Call this when app unmounts or user leaves screen
 */
export const cleanupAudio = async (): Promise<void> => {
  try {
    console.log('[Audio] Cleaning up audio resources...');
    await stopAllSounds();
    console.log('[Audio] ✅ Audio cleanup complete');
  } catch (error: any) {
    console.warn('[Audio] Cleanup error:', error.message || error);
  }
};

// Export all functions
export default {
  playSound,
  playSuccessSound,
  playErrorSound,
  stopAllSounds,
  isTTSAvailable,
  initializeAudio,
  cleanupAudio,
};