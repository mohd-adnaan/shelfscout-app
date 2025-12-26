import { useEffect } from 'react';
import Tts from 'react-native-tts';
import { CONFIG } from '../utils/constants';

export const useTTS = () => {
  useEffect(() => {
    // Initialize TTS
    Tts.setDefaultLanguage(CONFIG.DEFAULT_LANGUAGE);
    Tts.setDefaultRate(CONFIG.TTS_RATE);
    Tts.setDefaultPitch(CONFIG.TTS_PITCH);

    // Set up event listeners
    Tts.addEventListener('tts-start', (event) => {
      console.log('TTS started:', event);
    });

    Tts.addEventListener('tts-finish', (event) => {
      console.log('TTS finished:', event);
    });

    Tts.addEventListener('tts-cancel', (event) => {
      console.log('TTS cancelled:', event);
    });

    return () => {
      Tts.stop();
      Tts.removeAllListeners('tts-start');
      Tts.removeAllListeners('tts-finish');
      Tts.removeAllListeners('tts-cancel');
    };
  }, []);

  const speak = async (text: string): Promise<void> => {
    try {
      console.log('Speaking:', text);
      await Tts.stop(); // Stop any ongoing speech
      await Tts.speak(text);
    } catch (error) {
      console.error('TTS error:', error);
      throw error;
    }
  };

  const stop = async (): Promise<void> => {
    try {
      await Tts.stop();
    } catch (error) {
      console.error('TTS stop error:', error);
    }
  };

  return {
    speak,
    stop,
  };
};