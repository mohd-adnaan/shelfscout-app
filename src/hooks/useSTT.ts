/**
 * src/hooks/useSTT.ts
 * 
 * FINAL FIX: Combines iOS Voice.onSpeechEnd AND custom 1.5s timer
 * 
 * Why both?
 * - iOS Voice.onSpeechEnd takes 5-10 seconds (too slow)
 * - Custom timer fires after 1.5 seconds (responsive)
 * - Whichever fires first wins!
 */

import { useState, useRef, useEffect, useCallback } from 'react';
import { Platform, Alert, AccessibilityInfo } from 'react-native';
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

interface UseSTTOptions {
  onAutoSubmit?: () => Promise<void>;
  enableAutoSubmit?: boolean;
  silenceThreshold?: number;
}

export const useSTT = (options?: UseSTTOptions): UseSTTReturn => {
  const [isListening, setIsListening] = useState(false);
  const [transcript, setTranscript] = useState('');
  
  const finalTranscriptRef = useRef('');
  
  // Callback ref to avoid stale closures
  const onAutoSubmitRef = useRef(options?.onAutoSubmit);
  const enableAutoSubmit = options?.enableAutoSubmit ?? true;
  const silenceThreshold = options?.silenceThreshold ?? 1500;
  
  useEffect(() => {
    onAutoSubmitRef.current = options?.onAutoSubmit;
  }, [options?.onAutoSubmit]);
  
  // Auto-submit state
  const hasAutoSubmittedRef = useRef(false);
  const isManualStopRef = useRef(false);
  const silenceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const lastSpeechTimeRef = useRef<number>(0);

  // ============================================================================
  // Silence Detection Handler
  // ============================================================================
  const handleSilenceDetected = useCallback(async (source: string) => {
    console.log(`⏱️ Silence detected from: ${source}`);
    
    if (!enableAutoSubmit || hasAutoSubmittedRef.current || isManualStopRef.current) {
      console.log('⏹️ Auto-submit blocked:', {
        enableAutoSubmit,
        hasAutoSubmitted: hasAutoSubmittedRef.current,
        isManualStop: isManualStopRef.current,
      });
      return;
    }
    
    const currentTranscript = finalTranscriptRef.current.trim();
    
    if (!currentTranscript) {
      console.log('⏹️ No transcript - ignoring silence');
      return;
    }
    
    console.log('🎯 AUTO-SUBMIT TRIGGERED!');
    console.log(`📝 Transcript: "${currentTranscript}"`);
    
    hasAutoSubmittedRef.current = true;
    
    // Clear timer if still running
    if (silenceTimerRef.current) {
      clearTimeout(silenceTimerRef.current);
      silenceTimerRef.current = null;
    }
    
    AccessibilityInfo.announceForAccessibility('Processing your request');
    
    const callback = onAutoSubmitRef.current;
    if (callback) {
      console.log('🎯 Calling onAutoSubmit callback...');
      callback().catch(error => {
        console.error('❌ Auto-submit error:', error);
      });
    } else {
      console.error('❌ No onAutoSubmit callback!');
    }
  }, [enableAutoSubmit]);

  // ============================================================================
  // Reset Silence Timer (fires after 1.5s of no speech)
  // ============================================================================
  const resetSilenceTimer = useCallback(() => {
    // Clear existing timer
    if (silenceTimerRef.current) {
      clearTimeout(silenceTimerRef.current);
      silenceTimerRef.current = null;
    }
    
    // Update last speech time
    lastSpeechTimeRef.current = Date.now();
    
    if (!enableAutoSubmit || hasAutoSubmittedRef.current || !isListening) {
      return;
    }
    
    // Start new 1.5s timer
    console.log(`⏱️ Starting ${silenceThreshold}ms silence timer`);
    silenceTimerRef.current = setTimeout(() => {
      console.log('⏱️ Timer fired!');
      handleSilenceDetected('TIMER');
    }, silenceThreshold);
  }, [enableAutoSubmit, silenceThreshold, isListening, handleSilenceDetected]);

  // ============================================================================
  // iOS Voice Recognition Setup (ONCE on mount)
  // ============================================================================
  useEffect(() => {
    if (Platform.OS !== 'ios') return;
    
    console.log('🔧 Setting up iOS Voice handlers (PERMANENT)...');
    
    Voice.onSpeechStart = () => {
      console.log('🎤 Speech started (iOS)');
      setIsListening(true);
      hasAutoSubmittedRef.current = false;
      isManualStopRef.current = false;
    };

    Voice.onSpeechEnd = () => {
      console.log('🎤 Speech ended (iOS)');
      
      const currentTranscript = finalTranscriptRef.current.trim();
      
      console.log('📊 iOS onSpeechEnd state:', {
        hasAutoSubmitted: hasAutoSubmittedRef.current,
        isManualStop: isManualStopRef.current,
        hasTranscript: !!currentTranscript,
      });
      
      // iOS detected silence - trigger auto-submit if not already done
      if (enableAutoSubmit && !hasAutoSubmittedRef.current && !isManualStopRef.current && currentTranscript) {
        handleSilenceDetected('iOS_onSpeechEnd');
      }
    };

    Voice.onSpeechPartialResults = (event) => {
      if (event.value && event.value.length > 0) {
        const text = event.value[0];
        console.log('📝 Partial:', text);
        setTranscript(text);
        finalTranscriptRef.current = text;
        
        // CRITICAL: Reset timer on each partial result
        resetSilenceTimer();
      }
    };

    Voice.onSpeechResults = (event) => {
      if (event.value && event.value.length > 0) {
        const text = event.value[0];
        console.log('📝 Final:', text);
        setTranscript(text);
        finalTranscriptRef.current = text;
        
        // Reset timer on final result too
        resetSilenceTimer();
      }
    };

    Voice.onSpeechError = (event) => {
      console.error('❌ Speech error (iOS):', event.error);
      setIsListening(false);
      hasAutoSubmittedRef.current = false;
      isManualStopRef.current = false;
      
      // Clear timer on error
      if (silenceTimerRef.current) {
        clearTimeout(silenceTimerRef.current);
        silenceTimerRef.current = null;
      }
      
      handleVoiceError(event.error);
    };
    
    console.log('✅ iOS Voice handlers registered');

    return () => {
      console.log('🧹 Cleaning up Voice...');
      
      if (silenceTimerRef.current) {
        clearTimeout(silenceTimerRef.current);
      }
      
      Voice.destroy().then(Voice.removeAllListeners).catch((err) => {
        console.warn('Voice cleanup error:', err);
      });
    };
  }, [resetSilenceTimer, handleSilenceDetected]); // Include deps for callbacks

  // ============================================================================
  // Error Handler
  // ============================================================================
  const handleVoiceError = (error: any) => {
    const errorCode = error?.code || error?.message || error;
    let userMessage = 'Voice recognition failed.';
    let shouldAnnounce = true;
    
    if (typeof errorCode === 'string') {
      const errorStr = errorCode.toLowerCase();
      
      if (errorStr.includes('permission')) {
        userMessage = 'Microphone permission denied. Please enable it in Settings.';
      } else if (errorStr.includes('network')) {
        userMessage = 'Network error. Please check your internet connection.';
      } else if (errorStr.includes('timeout')) {
        userMessage = 'Voice recognition timed out. Please try again.';
      } else if (errorStr.includes('busy') || errorStr.includes('start_recording')) {
        userMessage = 'Voice recognition is busy. Please wait and try again.';
      } else if (errorStr.includes('unavailable')) {
        userMessage = 'Voice recognition is not available.';
      } else {
        userMessage = `Voice error: ${errorCode}. Please try again.`;
      }
    }
    
    if (shouldAnnounce) {
      AccessibilityService.announceError(userMessage, false);
      Alert.alert('Voice Recognition Error', userMessage, [{ text: 'OK' }]);
    }
  };

  // ============================================================================
  // Start Listening
  // ============================================================================
  const startListening = async () => {
    try {
      setTranscript('');
      finalTranscriptRef.current = '';
      hasAutoSubmittedRef.current = false;
      isManualStopRef.current = false;
      
      // Clear any existing timer
      if (silenceTimerRef.current) {
        clearTimeout(silenceTimerRef.current);
        silenceTimerRef.current = null;
      }

      if (Platform.OS === 'ios') {
        console.log('🎤 Starting iOS voice...');
        console.log('⚙️ Auto-submit config:', {
          enabled: enableAutoSubmit,
          threshold: `${silenceThreshold}ms`,
          hasCallback: !!onAutoSubmitRef.current,
        });
        
        try {
          // Stop any existing Voice session
          await Voice.stop().catch(() => {});
          await Voice.cancel().catch(() => {});
          
          await new Promise<void>(resolve => setTimeout(() => resolve(), 100));
          
          await Voice.start('en-US');
          setIsListening(true);
          console.log('✅ iOS voice started - waiting for speech...');
          
        } catch (error: any) {
          console.error('❌ Error starting iOS voice:', error);
          handleVoiceError(error);
          setIsListening(false);
          throw new Error('Failed to start voice recognition');
        }
      } else {
        console.log('🎤 Starting Android STT...');
        setIsListening(true);
        // Android implementation would go here
      }
    } catch (error: any) {
      console.error('❌ Error starting STT:', error);
      setIsListening(false);
      throw error;
    }
  };

  // ============================================================================
  // Stop Listening (Manual)
  // ============================================================================
  const stopListening = async (): Promise<string> => {
    try {
      console.log('🛑 Manual stop requested');
      isManualStopRef.current = true;
      
      // Clear silence timer
      if (silenceTimerRef.current) {
        clearTimeout(silenceTimerRef.current);
        silenceTimerRef.current = null;
      }
      
      if (Platform.OS === 'ios') {
        try {
          await Voice.stop();
          setIsListening(false);
          console.log('✅ iOS voice stopped (manual)');
          return finalTranscriptRef.current;
        } catch (error: any) {
          console.error('❌ Error stopping:', error);
          setIsListening(false);
          return finalTranscriptRef.current;
        }
      } else {
        setIsListening(false);
        return finalTranscriptRef.current;
      }
    } catch (error: any) {
      console.error('❌ Error stopping STT:', error);
      setIsListening(false);
      return finalTranscriptRef.current;
    }
  };

  // ============================================================================
  // Cancel Listening
  // ============================================================================
  const cancelListening = async () => {
    try {
      console.log('🛑 Canceling STT...');
      
      // Clear timer
      if (silenceTimerRef.current) {
        clearTimeout(silenceTimerRef.current);
        silenceTimerRef.current = null;
      }
      
      if (Platform.OS === 'ios') {
        await Voice.cancel().catch(() => {});
        await Voice.stop().catch(() => {});
      }
      
      setIsListening(false);
      setTranscript('');
      finalTranscriptRef.current = '';
      hasAutoSubmittedRef.current = false;
      isManualStopRef.current = false;
    } catch (error: any) {
      console.error('❌ Error canceling:', error);
      setIsListening(false);
      setTranscript('');
      finalTranscriptRef.current = '';
    }
  };

  return {
    isListening,
    transcript,
    startListening,
    stopListening,
    cancelListening,
  };
};
