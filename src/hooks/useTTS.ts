import { useEffect } from 'react';
import Tts from 'react-native-tts';

export const useTTS = () => {
  useEffect(() => {
    Tts.setDefaultLanguage('en-US').catch(() => {});
    
    console.log('TTS initialized');

    return () => {
      Tts.stop().catch(() => {});
    };
  }, []);

  const speak = async (text: string): Promise<void> => {
    try {
      console.log('Speaking:', text);
      await Tts.stop();
      await Tts.speak(text);
    } catch (error) {
      console.error('TTS error:', error);
    }
  };

  const stop = async (): Promise<void> => {
    try {
      await Tts.stop();
    } catch (error) {
      console.error('TTS stop error:', error);
    }
  };

  return { speak, stop };
};