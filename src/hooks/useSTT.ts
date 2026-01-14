// src/hooks/useSTT.ts
// Platform-specific Speech-to-Text hook
import { useState, useRef, useEffect } from 'react';
import { Platform } from 'react-native';
import Voice from '@react-native-voice/voice';
import { SPEACHES_CONFIG } from '../utils/constants';

interface UseSTTReturn {
  isListening: boolean;
  transcript: string;
  startListening: () => Promise<void>;
  stopListening: () => Promise<string>;
  cancelListening: () => Promise<void>;
}

export const useSTT = (): UseSTTReturn => {
  const [isListening, setIsListening] = useState(false);
  const [transcript, setTranscript] = useState('');
  
  const finalTranscriptRef = useRef('');
  const isProcessingRef = useRef(false);

  // iOS Voice Recognition Setup
  useEffect(() => {
    if (Platform.OS === 'ios') {
      // Voice event handlers for iOS
      Voice.onSpeechStart = () => {
        console.log('🎤 Speech started (iOS)');
        setIsListening(true);
      };

      Voice.onSpeechEnd = () => {
        console.log('🎤 Speech ended (iOS)');
      };

      Voice.onSpeechResults = (event) => {
        if (event.value && event.value.length > 0) {
          const text = event.value[0];
          console.log("📝 Transcript (iOS):", text);
          setTranscript(text);
          finalTranscriptRef.current = text;
        }
      };

      Voice.onSpeechPartialResults = (event) => {
        if (event.value && event.value.length > 0) {
          const text = event.value[0];
          console.log("📝 Transcript (iOS):", text);
          setTranscript(text);
          finalTranscriptRef.current = text;
        }
      };

      Voice.onSpeechError = (event) => {
        console.error('❌ Speech recognition error (iOS):', event.error);
        setIsListening(false);
      };
    }

    return () => {
      // Cleanup
      if (Platform.OS === 'ios') {
        Voice.destroy().then(Voice.removeAllListeners);
      }
    };
  }, []);

  const startListening = async () => {
    try {
      // Reset state
      setTranscript('');
      finalTranscriptRef.current = '';
      isProcessingRef.current = false;

      if (Platform.OS === 'ios') {
        // Use iOS native voice recognition
        console.log('🎤 Starting iOS voice recognition...');
        await Voice.start('en-US');
        setIsListening(true);
      } else {
        // Android - use Speaches API
        console.log('🎤 Starting Android STT (Speaches)...');
        setIsListening(true);
        await startSpeachesSTT();
      }
    } catch (error) {
      console.error('❌ Error starting STT:', error);
      setIsListening(false);
      throw error;
    }
  };

  const stopListening = async (): Promise<string> => {
    try {
      if (Platform.OS === 'ios') {
        console.log('🛑 Stopping iOS voice recognition...');
        await Voice.stop();
        setIsListening(false);
        
        // Return final transcript
        return finalTranscriptRef.current;
      } else {
        // Android - stop Speaches recording
        console.log('🛑 Stopping Android STT...');
        const finalText = await stopSpeachesSTT();
        setIsListening(false);
        return finalText;
      }
    } catch (error) {
      console.error('❌ Error stopping STT:', error);
      setIsListening(false);
      return finalTranscriptRef.current;
    }
  };

  const cancelListening = async () => {
    try {
      console.log('🛑 Canceling STT...');
      
      if (Platform.OS === 'ios') {
        await Voice.cancel();
        await Voice.stop();
      } else {
        // Android - cancel Speaches recording
        // Implementation depends on your Speaches setup
      }
      
      setIsListening(false);
      setTranscript('');
      finalTranscriptRef.current = '';
    } catch (error) {
      console.error('❌ Error canceling STT:', error);
      setIsListening(false);
    }
  };

  // Android Speaches STT functions
  const startSpeachesSTT = async () => {
    // TODO: Implement Speaches STT recording start
    // This would involve starting audio recording and preparing for streaming
    console.log('📱 Speaches STT start - implement recording');
  };

  const stopSpeachesSTT = async (): Promise<string> => {
    // TODO: Implement Speaches STT stop and transcription
    // This would send the recorded audio to Speaches API
    console.log('📱 Speaches STT stop - implement transcription');
    return finalTranscriptRef.current;
  };

  return {
    isListening,
    transcript,
    startListening,
    stopListening,
    cancelListening,
  };
};