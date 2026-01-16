/**
 * src/hooks/useSTT.ts
 * 
 * WCAG 2.1 Level AA Compliant Speech-to-Text Hook
 * 
 * Compliance Features:
 * - 3.3.1 Error Identification: Clear, actionable error messages
 * - 3.3.2 Labels or Instructions: Guidance for permission errors
 * - 4.1.3 Status Messages: Announces state changes to screen reader
 * 
 * Platform-specific implementation:
 * - iOS: Uses native Voice Recognition (@react-native-voice/voice)
 * - Android: Uses Speaches API for STT
 */

import { useState, useRef, useEffect } from 'react';
import { Platform, Alert } from 'react-native';
import Voice from '@react-native-voice/voice';
import { AccessibilityService } from '../services/AccessibilityService';
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

  // ============================================================================
  // iOS Voice Recognition Setup
  // ============================================================================
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
          console.log('📝 Transcript (iOS):', text);
          setTranscript(text);
          finalTranscriptRef.current = text;
        }
      };

      Voice.onSpeechPartialResults = (event) => {
        if (event.value && event.value.length > 0) {
          const text = event.value[0];
          console.log('📝 Partial transcript (iOS):', text);
          setTranscript(text);
          finalTranscriptRef.current = text;
        }
      };

      // WCAG 3.3.1: Handle errors with clear messages
      Voice.onSpeechError = (event) => {
        console.error('❌ Speech recognition error (iOS):', event.error);
        setIsListening(false);
        
        // Format error for user
        handleVoiceError(event.error);
      };
    }

    return () => {
      // Cleanup
      if (Platform.OS === 'ios') {
        Voice.destroy().then(Voice.removeAllListeners).catch((err) => {
          console.warn('Voice cleanup error:', err);
        });
      }
    };
  }, []);

  // ============================================================================
  // WCAG 3.3.1: Error Handler with Clear Messages
  // ============================================================================
  const handleVoiceError = (error: any) => {
    const errorCode = error?.code || error?.message || error;
    
    let userMessage = 'Voice recognition failed.';
    let shouldAnnounce = true;
    
    // Format based on error type
    if (typeof errorCode === 'string') {
      const errorStr = errorCode.toLowerCase();
      
      if (errorStr.includes('permission')) {
        userMessage = Platform.OS === 'ios'
          ? 'Microphone permission denied. To enable: Open Settings → Privacy → Microphone → Enable for CyberSight.'
          : 'Microphone permission denied. To enable: Open Settings → Apps → CyberSight → Permissions → Enable Microphone.';
      } else if (errorStr.includes('network') || errorStr.includes('connection')) {
        userMessage = 'Network error. Please check your internet connection and try again.';
      } else if (errorStr.includes('timeout')) {
        userMessage = 'Voice recognition timed out. Please try again.';
      } else if (errorStr.includes('busy') || errorStr.includes('already')) {
        userMessage = 'Voice recognition is busy. Please try again.';
        shouldAnnounce = false; // Common, don't announce
      } else if (errorStr.includes('unavailable') || errorStr.includes('not available')) {
        userMessage = 'Voice recognition is not available on this device.';
      } else {
        userMessage = `Voice recognition error: ${errorCode}. Please try again.`;
      }
    }
    
    // WCAG 4.1.3: Announce error to screen reader
    if (shouldAnnounce) {
      AccessibilityService.announceError(userMessage, false);
      
      // Show visual alert for sighted users
      if (!errorCode.toString().toLowerCase().includes('already')) {
        Alert.alert(
          'Voice Recognition Error',
          userMessage,
          [{ text: 'OK', style: 'default' }]
        );
      }
    }
  };

  // ============================================================================
  // WCAG 3.3.1: Start Listening with Error Handling
  // ============================================================================
  const startListening = async () => {
    try {
      // Reset state
      setTranscript('');
      finalTranscriptRef.current = '';
      isProcessingRef.current = false;

      if (Platform.OS === 'ios') {
        // Use iOS native voice recognition
        console.log('🎤 Starting iOS voice recognition...');
        
        try {
          await Voice.start('en-US');
          setIsListening(true);
          console.log('✅ iOS voice recognition started');
        } catch (error: any) {
          console.error('❌ Error starting iOS voice recognition:', error);
          
          // WCAG 3.3.1: Format error for user
          handleVoiceError(error);
          
          setIsListening(false);
          throw new Error('Failed to start voice recognition. Please try again.');
        }
      } else {
        // Android - use Speaches API
        console.log('🎤 Starting Android STT (Speaches)...');
        setIsListening(true);
        
        try {
          await startSpeachesSTT();
          console.log('✅ Android STT started');
        } catch (error: any) {
          console.error('❌ Error starting Android STT:', error);
          
          // WCAG 3.3.1: Clear error message
          const userMessage = error.message.includes('permission')
            ? 'Microphone permission denied. Please enable it in Settings.'
            : error.message.includes('network')
            ? 'Network error. Please check your internet connection.'
            : 'Failed to start voice recognition. Please try again.';
          
          AccessibilityService.announceError(userMessage, false);
          
          Alert.alert(
            'Voice Recognition Error',
            userMessage,
            [{ text: 'OK', style: 'default' }]
          );
          
          setIsListening(false);
          throw new Error(userMessage);
        }
      }
    } catch (error: any) {
      console.error('❌ Error starting STT:', error);
      setIsListening(false);
      
      // Re-throw with user-friendly message
      throw error;
    }
  };

  // ============================================================================
  // WCAG 3.3.1: Stop Listening with Error Handling
  // ============================================================================
  const stopListening = async (): Promise<string> => {
    try {
      if (Platform.OS === 'ios') {
        console.log('🛑 Stopping iOS voice recognition...');
        
        try {
          await Voice.stop();
          setIsListening(false);
          console.log('✅ iOS voice recognition stopped');
          
          // Return final transcript
          return finalTranscriptRef.current;
        } catch (error: any) {
          console.error('❌ Error stopping iOS voice recognition:', error);
          
          // Don't announce - stopping errors are usually not critical
          setIsListening(false);
          return finalTranscriptRef.current;
        }
      } else {
        // Android - stop Speaches recording
        console.log('🛑 Stopping Android STT...');
        
        try {
          const finalText = await stopSpeachesSTT();
          setIsListening(false);
          console.log('✅ Android STT stopped');
          return finalText;
        } catch (error: any) {
          console.error('❌ Error stopping Android STT:', error);
          
          // WCAG 3.3.1: Announce error if critical
          if (!error.message.includes('not started')) {
            AccessibilityService.announceError(
              'Failed to process voice input. Please try again.',
              false
            );
          }
          
          setIsListening(false);
          return finalTranscriptRef.current;
        }
      }
    } catch (error: any) {
      console.error('❌ Error stopping STT:', error);
      setIsListening(false);
      return finalTranscriptRef.current;
    }
  };

  // ============================================================================
  // WCAG 3.3.1: Cancel Listening with Error Handling
  // ============================================================================
  const cancelListening = async () => {
    try {
      console.log('🛑 Canceling STT...');
      
      if (Platform.OS === 'ios') {
        try {
          await Voice.cancel();
          await Voice.stop();
          console.log('✅ iOS voice recognition canceled');
        } catch (error: any) {
          console.warn('⚠️ Error canceling iOS voice recognition:', error);
          // Don't announce - cancel errors are usually not critical
        }
      } else {
        // Android - cancel Speaches recording
        try {
          await cancelSpeachesSTT();
          console.log('✅ Android STT canceled');
        } catch (error: any) {
          console.warn('⚠️ Error canceling Android STT:', error);
          // Don't announce - cancel errors are usually not critical
        }
      }
      
      setIsListening(false);
      setTranscript('');
      finalTranscriptRef.current = '';
    } catch (error: any) {
      console.error('❌ Error canceling STT:', error);
      
      // Always reset state even if cancel fails
      setIsListening(false);
      setTranscript('');
      finalTranscriptRef.current = '';
    }
  };

  // ============================================================================
  // Android Speaches STT Functions
  // ============================================================================
  
  /**
   * Start Android STT using Speaches API
   */
  const startSpeachesSTT = async () => {
    // TODO: Implement Speaches STT recording start
    // This would involve starting audio recording and preparing for streaming
    console.log('📱 Speaches STT start - implement recording');
    
    // Placeholder implementation
    // When implemented, this should:
    // 1. Request microphone permission
    // 2. Start audio recording
    // 3. Prepare for streaming to Speaches API
    
    // For now, log that it's not implemented
    console.warn('⚠️ Speaches STT not fully implemented yet');
  };

  /**
   * Stop Android STT and get transcription
   */
  const stopSpeachesSTT = async (): Promise<string> => {
    // TODO: Implement Speaches STT stop and transcription
    // This would send the recorded audio to Speaches API
    console.log('📱 Speaches STT stop - implement transcription');
    
    // Placeholder implementation
    // When implemented, this should:
    // 1. Stop audio recording
    // 2. Send audio to Speaches API
    // 3. Get transcription result
    // 4. Return transcribed text
    
    // For now, return whatever transcript we have
    console.warn('⚠️ Speaches STT not fully implemented yet');
    return finalTranscriptRef.current;
  };

  /**
   * Cancel Android STT recording
   */
  const cancelSpeachesSTT = async () => {
    // TODO: Implement Speaches STT cancel
    console.log('📱 Speaches STT cancel - implement cleanup');
    
    // Placeholder implementation
    // When implemented, this should:
    // 1. Stop audio recording
    // 2. Cancel any pending API requests
    // 3. Clean up resources
    
    console.warn('⚠️ Speaches STT cancel not fully implemented yet');
  };

  return {
    isListening,
    transcript,
    startListening,
    stopListening,
    cancelListening,
  };
};