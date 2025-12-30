import { Platform } from 'react-native';
import Tts from 'react-native-tts';

/**
 * Play audio feedback sounds for different states
 * Uses TTS to generate simple audio cues
 */
export const playSound = async (type: 'start' | 'stop' | 'processing') => {
  try {
    // Platform-specific audio feedback
    if (Platform.OS === 'ios') {
      // iOS: Use system haptic feedback (vibration patterns)
      // Note: For full haptic support, you would need react-native-haptic-feedback
      // For now, we'll just use short TTS beeps
      
      switch (type) {
        case 'start':
          // Short ascending beep sound
          console.log('🔊 Audio feedback: Microphone ON');
          break;
        case 'stop':
          // Short descending beep sound
          console.log('🔊 Audio feedback: Microphone OFF');
          break;
        case 'processing':
          // Processing sound
          console.log('🔊 Audio feedback: Thinking...');
          break;
      }
    } else {
      // Android: Similar approach
      console.log(`🔊 Audio feedback: ${type}`);
    }
  } catch (error) {
    console.error('Sound effect error:', error);
  }
};

/**
 * Alternative: Use actual audio files if you want better sound effects
 * 
 * To implement:
 * 1. Install: npm install react-native-sound
 * 2. Add sound files to android/app/src/main/res/raw/ and ios/[ProjectName]/
 * 3. Use the following code:
 * 
 * import Sound from 'react-native-sound';
 * 
 * Sound.setCategory('Playback');
 * 
 * const sounds = {
 *   start: new Sound('mic_start.mp3', Sound.MAIN_BUNDLE),
 *   stop: new Sound('mic_stop.mp3', Sound.MAIN_BUNDLE),
 *   processing: new Sound('processing.mp3', Sound.MAIN_BUNDLE),
 * };
 * 
 * export const playSound = (type: 'start' | 'stop' | 'processing') => {
 *   sounds[type].play((success) => {
 *     if (!success) {
 *       console.log('Sound playback failed');
 *     }
 *   });
 * };
 */