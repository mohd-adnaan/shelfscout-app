// src/hooks/useSpeachesTTS.ts
import { useEffect, useRef } from 'react';
import { speachesTTS } from '../services/speaches/speachesTTS';

/**
 * Hook for Speaches TTS - replaces buggy iOS native TTS
 * Uses the same TTS service as the web application
 */
export const useSpeachesTTS = () => {
  const isMountedRef = useRef(true);

  useEffect(() => {
    console.log('✅ Speaches TTS hook initialized');

    return () => {
      isMountedRef.current = false;
      // Cleanup: stop any playing audio
      speachesTTS.stop().catch(() => {});
    };
  }, []);

  const speak = async (text: string): Promise<void> => {
    if (!isMountedRef.current) {
      console.warn('⚠️ Component unmounted, skipping speak');
      return;
    }

    try {
      await speachesTTS.speak(text);
    } catch (error) {
      console.error('❌ Speaches TTS speak error:', error);
      throw error;
    }
  };

  const stop = async (): Promise<void> => {
    try {
      await speachesTTS.stop();
    } catch (error) {
      console.error('❌ Speaches TTS stop error:', error);
    }
  };

  return { speak, stop };
};