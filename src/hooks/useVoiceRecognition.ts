/**
 * src/hooks/useVoiceRecognition.ts
 * 
 * WCAG 2.1 Level AA Compliant Voice Recognition Hook
 * 
 * Compliance Features:
 * - 3.3.1 Error Identification: Clear error messages for voice recognition failures
 * - 3.3.2 Labels or Instructions: Guidance for fixing permission and recovery issues
 * - 4.1.3 Status Messages: Announces voice recognition status to screen reader
 * 
 * Provides voice recognition with accessibility support and automatic error recovery
 */

import { useEffect, useCallback, useRef } from 'react';
import { Alert, Platform } from 'react-native';
import Voice, {
  SpeechResultsEvent,
  SpeechErrorEvent,
  SpeechStartEvent,
  SpeechEndEvent,
} from '@react-native-voice/voice';
import { AccessibilityService } from '../services/AccessibilityService';

/**
 * Voice Recognition Hook with WCAG-compliant error handling
 * 
 * @returns Voice recognition functionality with auto-recovery
 */
export const useVoiceRecognition = () => {
  const callbacksRef = useRef<{
    onResults?: (transcript: string) => void;
    onError?: (error: any) => void;
    onStart?: () => void;
    onEnd?: () => void;
  }>({});

  const isRecognizingRef = useRef(false);
  const recoveryAttemptRef = useRef(0);
  const MAX_RECOVERY_ATTEMPTS = 2;

  // ============================================================================
  // Setup Voice Recognition Event Handlers
  // ============================================================================
  useEffect(() => {
    Voice.onSpeechStart = (e: SpeechStartEvent) => {
      console.log('[Voice] 🎤 Speech started');
      isRecognizingRef.current = true;
      recoveryAttemptRef.current = 0; // Reset recovery counter on success
      callbacksRef.current.onStart?.();
    };

    Voice.onSpeechEnd = (e: SpeechEndEvent) => {
      console.log('[Voice] 🎤 Speech ended');
      isRecognizingRef.current = false;
      callbacksRef.current.onEnd?.();
    };

    Voice.onSpeechResults = (e: SpeechResultsEvent) => {
      console.log('[Voice] 📝 Speech results:', e.value);
      if (e.value && e.value.length > 0) {
        callbacksRef.current.onResults?.(e.value[0]);
      }
    };

    Voice.onSpeechError = (e: SpeechErrorEvent) => {
      console.error('[Voice] ❌ Speech error:', e.error);
      isRecognizingRef.current = false;
      
      // WCAG 3.3.1: Format error for user
      handleVoiceError(e.error);
    };

    return () => {
      Voice.destroy().then(Voice.removeAllListeners).catch((err) => {
        console.warn('[Voice] Cleanup error:', err);
      });
    };
  }, []);

  // ============================================================================
  // WCAG 3.3.1: Voice Error Handler with Clear Messages
  // ============================================================================
  const handleVoiceError = (error: any) => {
    const errorCode = error?.code || error?.message || error;
    
    let userMessage = 'Voice recognition failed.';
    let shouldShowAlert = true;
    
    // Format based on error type
    if (typeof errorCode === 'string') {
      const errorStr = errorCode.toLowerCase();
      
      if (errorStr.includes('permission')) {
        // WCAG 3.3.2: Platform-specific guidance
        const guidance = Platform.OS === 'ios'
          ? 'To enable: Settings → Privacy → Microphone → ShelfScout'
          : 'To enable: Settings → Apps → ShelfScout → Permissions → Microphone';
        
        userMessage = `Microphone permission denied.\n\n${guidance}`;
      } 
      else if (errorStr.includes('network') || errorStr.includes('connection')) {
        userMessage = 'Network error. Please check your internet connection and try again.';
      } 
      else if (errorStr.includes('timeout')) {
        userMessage = 'Voice recognition timed out. Please try again.';
      } 
      else if (errorStr.includes('busy') || errorStr.includes('already')) {
        userMessage = 'Voice recognition is busy. Please wait a moment and try again.';
        shouldShowAlert = false; // Common issue, don't alert every time
      } 
      else if (errorStr.includes('unavailable') || errorStr.includes('not available')) {
        userMessage = 'Voice recognition is not available on this device.';
      }
      else if (errorStr.includes('no speech') || errorStr.includes('no match')) {
        userMessage = 'No speech detected. Please speak clearly and try again.';
      }
      else if (errorStr.includes('audio')) {
        userMessage = 'Audio error. Please check your microphone and try again.';
      }
      else {
        userMessage = `Voice recognition error: ${errorCode}. Please try again.`;
      }
    }
    
    // WCAG 4.1.3: Announce error to screen reader
    if (shouldShowAlert) {
      AccessibilityService.announceError(userMessage, false);
      
      // Show visual alert
      Alert.alert(
        'Voice Recognition Error',
        userMessage,
        [{ text: 'OK', style: 'default' }]
      );
    }
    
    // Call error callback
    callbacksRef.current.onError?.(error);
  };

  // ============================================================================
  // WCAG 3.3.1: Start Recognition with Automatic Error Recovery
  // ============================================================================
  const startRecognition = useCallback(
    async (
      onResults: (transcript: string) => void,
      onError: (error: any) => void,
      onStart?: () => void,
      onEnd?: () => void
    ) => {
      callbacksRef.current = { onResults, onError, onStart, onEnd };

      try {
        // WCAG 3.3.1: Ensure Voice is completely stopped before starting
        if (isRecognizingRef.current) {
          console.log('[Voice] ⚠️ Voice already recognizing, stopping first...');
          
          try {
            await Voice.cancel();
            isRecognizingRef.current = false;
            
            // Small delay to ensure cleanup
            await new Promise(resolve => setTimeout(resolve, 100));
          } catch (cancelError: any) {
            console.warn('[Voice] Cancel error (continuing):', cancelError);
          }
        }

        console.log('[Voice] ✅ Starting voice recognition');
        await Voice.start('en-US');
        
        console.log('[Voice] ✅ Voice recognition started successfully');
        
      } catch (error: any) {
        console.error('[Voice] ❌ Start recognition error:', error);
        
        // WCAG 3.3.1: Handle "already started" error with automatic recovery
        if (error?.message?.includes('already started')) {
          console.log('[Voice] 🔄 Attempting recovery from "already started" error');
          
          // Only attempt recovery a limited number of times
          if (recoveryAttemptRef.current < MAX_RECOVERY_ATTEMPTS) {
            recoveryAttemptRef.current += 1;
            
            console.log(`[Voice] Recovery attempt ${recoveryAttemptRef.current}/${MAX_RECOVERY_ATTEMPTS}`);
            
            try {
              // Try to recover
              await Voice.cancel();
              await new Promise(resolve => setTimeout(resolve, 200));
              await Voice.start('en-US');
              
              console.log('[Voice] ✅ Recovery successful');
              
              // WCAG 4.1.3: Quietly announce success
              AccessibilityService.announce('Voice recognition started.');
              
              return; // Success!
              
            } catch (retryError: any) {
              console.error('[Voice] ❌ Recovery failed:', retryError);
              
              // Format error message
              const message = 'Failed to start voice recognition. Please try again.';
              
              // WCAG 4.1.3: Announce error
              AccessibilityService.announceError(message, false);
              
              Alert.alert(
                'Voice Recognition Error',
                message,
                [{ text: 'OK', style: 'default' }]
              );
              
              onError(retryError);
              return;
            }
          } else {
            // Too many recovery attempts
            console.error('[Voice] ❌ Too many recovery attempts');
            
            const message = 'Voice recognition failed to start after multiple attempts. Please restart the app.';
            
            AccessibilityService.announceError(message, false);
            
            Alert.alert(
              'Voice Recognition Error',
              message,
              [{ text: 'OK', style: 'default' }]
            );
            
            onError(error);
            return;
          }
        }
        
        // Other errors - format with clear messages
        let userMessage = 'Failed to start voice recognition.';
        
        if (error.message) {
          const errorMsg = error.message.toLowerCase();
          
          if (errorMsg.includes('permission')) {
            const guidance = Platform.OS === 'ios'
              ? 'Settings → Privacy → Microphone → ShelfScout'
              : 'Settings → Apps → ShelfScout → Permissions → Microphone';
            
            userMessage = `Microphone permission denied.\n\nTo enable: ${guidance}`;
          } 
          else if (errorMsg.includes('unavailable')) {
            userMessage = 'Voice recognition is not available on this device.';
          } 
          else if (errorMsg.includes('busy')) {
            userMessage = 'Voice recognition is busy. Please wait and try again.';
          } 
          else {
            userMessage = `Voice recognition error: ${error.message}`;
          }
        }
        
        // WCAG 4.1.3: Announce error
        AccessibilityService.announceError(userMessage, false);
        
        Alert.alert(
          'Voice Recognition Error',
          userMessage + '\n\nPlease try again.',
          [{ text: 'OK', style: 'default' }]
        );
        
        onError(error);
      }
    },
    []
  );

  // ============================================================================
  // WCAG 3.3.1: Stop Recognition with Error Handling
  // ============================================================================
  const stopRecognition = useCallback(async () => {
    try {
      console.log('[Voice] 🛑 Stopping voice recognition');
      
      await Voice.stop();
      
      isRecognizingRef.current = false;
      
      console.log('[Voice] ✅ Voice recognition stopped');
      
    } catch (error: any) {
      console.error('[Voice] ❌ Stop recognition error:', error);
      
      // Force stopped state
      isRecognizingRef.current = false;
      
      // WCAG 3.3.1: Don't announce stop errors - usually not critical
      console.warn('[Voice] Stop failed, but continuing');
    }
  }, []);

  // ============================================================================
  // WCAG 3.3.1: Cancel Recognition with Error Handling
  // ============================================================================
  const cancelRecognition = useCallback(async () => {
    try {
      console.log('[Voice] 🚫 Canceling voice recognition');
      
      await Voice.cancel();
      
      isRecognizingRef.current = false;
      recoveryAttemptRef.current = 0;
      
      console.log('[Voice] ✅ Voice recognition canceled');
      
    } catch (error: any) {
      console.error('[Voice] ❌ Cancel recognition error:', error);
      
      // Force stopped state
      isRecognizingRef.current = false;
      recoveryAttemptRef.current = 0;
      
      // WCAG 3.3.1: Don't announce cancel errors - usually not critical
      console.warn('[Voice] Cancel failed, but continuing');
    }
  }, []);

  // ============================================================================
  // Check if currently recognizing
  // ============================================================================
  const isRecognizing = useCallback((): boolean => {
    return isRecognizingRef.current;
  }, []);

  // ============================================================================
  // Reset recovery counter (call when user explicitly stops)
  // ============================================================================
  const resetRecovery = useCallback(() => {
    recoveryAttemptRef.current = 0;
    console.log('[Voice] Recovery counter reset');
  }, []);

  return {
    startRecognition,
    stopRecognition,
    cancelRecognition,
    isRecognizing,
    resetRecovery,
  };
};