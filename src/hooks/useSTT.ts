// src/hooks/useSTT.ts

import { useState, useEffect, useCallback } from 'react';
import { Platform } from 'react-native';
import Voice from '@react-native-voice/voice';
import { speachesSTT } from '../services/speachesSttClient';

/**
 * Platform-specific STT hook
 * 
 * iOS: Native voice recognition (fast, reliable)
 * Android: Speaches API (works when native doesn't)
 * 
 * Usage:
 * ```typescript
 * const { 
 *   startListening, 
 *   stopListening, 
 *   isListening, 
 *   transcript 
 * } = useSTT();
 * ```
 */
export const useSTT = () => {
  const [isListening, setIsListening] = useState(false);
  const [transcript, setTranscript] = useState('');

  useEffect(() => {
    if (Platform.OS === 'ios') {
      // ✅ iOS: Setup native Voice recognition
      console.log('🍎 Using native iOS Voice recognition');

      Voice.onSpeechStart = () => {
        console.log('🎤 Speech started (iOS)');
        setIsListening(true);
      };

      Voice.onSpeechEnd = () => {
        console.log('🎤 Speech ended (iOS)');
        setIsListening(false);
      };

      Voice.onSpeechResults = (e) => {
        if (e.value && e.value[0]) {
          const newTranscript = e.value[0];
          console.log('📝 Transcript (iOS):', newTranscript);
          setTranscript(newTranscript);
        }
      };

      Voice.onSpeechError = (e) => {
        console.error('❌ Speech error (iOS):', e);
        setIsListening(false);
      };

      return () => {
        Voice.destroy().then(Voice.removeAllListeners);
      };
    } else {
      // ✅ Android: Using Speaches STT
      console.log('🤖 Using Speaches STT for Android');
    }
  }, []);

  /**
   * Start listening for speech
   * 
   * iOS: Starts native voice recognition
   * Android: Starts audio recording
   */
  const startListening = useCallback(async () => {
    try {
      setTranscript('');

      if (Platform.OS === 'ios') {
        // ✅ iOS: Use native Voice
        console.log('🎤 Starting iOS voice recognition...');
        await Voice.start('en-US');
      } else {
        // ✅ Android: Start recording with Speaches
        console.log('🎤 Starting Android audio recording...');
        await speachesSTT.startRecording();
        setIsListening(true);
      }
    } catch (error) {
      console.error('❌ Start listening error:', error);
      setIsListening(false);
      throw error;
    }
  }, []);

  /**
   * Stop listening and get transcript
   * 
   * iOS: Stops native voice recognition, transcript comes via callback
   * Android: Stops recording and transcribes via Speaches API
   * 
   * @returns Promise that resolves with transcript (Android only, iOS uses callback)
   */
  const stopListening = useCallback(async (): Promise<string> => {
    try {
      if (Platform.OS === 'ios') {
        // ✅ iOS: Stop native Voice
        console.log('🛑 Stopping iOS voice recognition...');
        await Voice.stop();
        // Transcript will come via onSpeechResults callback
        return transcript;
      } else {
        // ✅ Android: Stop recording and transcribe
        console.log('🛑 Stopping Android recording and transcribing...');
        const androidTranscript = await speachesSTT.stopRecordingAndTranscribe();
        setIsListening(false);
        setTranscript(androidTranscript);
        return androidTranscript;
      }
    } catch (error) {
      console.error('❌ Stop listening error:', error);
      setIsListening(false);
      throw error;
    }
  }, [transcript]);

  /**
   * Cancel current listening session
   */
  const cancelListening = useCallback(async () => {
    try {
      if (Platform.OS === 'ios') {
        await Voice.stop();
        await Voice.destroy();
      } else {
        await speachesSTT.cancelRecording();
      }
      setIsListening(false);
      setTranscript('');
    } catch (error) {
      console.error('❌ Cancel listening error:', error);
    }
  }, []);

  return {
    startListening,
    stopListening,
    cancelListening,
    isListening,
    transcript,
  };
};