/**
 * src/hooks/useSTT_Enhanced.ts
 * 
 * INDUSTRY STANDARD: Hybrid VAD Approach
 * 
 * Combines THREE detection methods for maximum reliability:
 * 
 * 1. RMS Power Monitoring (Primary) - Energy-based VAD
 *    - Fast response (<100ms)
 *    - Accurate silence detection
 *    - Platform-independent
 * 
 * 2. iOS Speech Framework (Secondary) - Platform-native EOU
 *    - Built-in ML models
 *    - Handles edge cases
 *    - Reliable fallback
 * 
 * 3. Manual Tap (Tertiary) - User control
 *    - Accessibility requirement
 *    - Ultimate fallback
 * 
 * WHICHEVER FIRES FIRST WINS!
 * 
 * This approach is used by:
 * - Google Assistant (VAD + platform-native)
 * - Amazon Alexa (VAD + timeout)
 * - Apple Siri (ML VAD + Speech framework)
 * - Production voice AI applications
 */

import { useState, useRef, useEffect, useCallback } from 'react';
import { Platform, Alert, AccessibilityInfo } from 'react-native';
import Voice from '@react-native-voice/voice';
import { AccessibilityService } from '../services/AccessibilityService';
import { getVADInstance } from '../services/RMSVoiceActivityDetector';

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
  silenceThreshold?: number; // milliseconds
  enableRMSVAD?: boolean; // Enable RMS-based VAD
}

export const useSTT = (options?: UseSTTOptions): UseSTTReturn => {
  const [isListening, setIsListening] = useState(false);
  const [transcript, setTranscript] = useState('');
  
  const finalTranscriptRef = useRef('');
  
  // Callback ref to avoid stale closures
  const onAutoSubmitRef = useRef(options?.onAutoSubmit);
  const enableAutoSubmit = options?.enableAutoSubmit ?? true;
  const silenceThreshold = options?.silenceThreshold ?? 1500; // 1.5s default
  const enableRMSVAD = options?.enableRMSVAD ?? true; // Enable by default
  
  useEffect(() => {
    onAutoSubmitRef.current = options?.onAutoSubmit;
  }, [options?.onAutoSubmit]);
  
  // Auto-submit state
  const hasAutoSubmittedRef = useRef(false);
  const isManualStopRef = useRef(false);
  
  // VAD instance - initialized once
  const vadRef = useRef<ReturnType<typeof getVADInstance> | null>(null);
  
  // Initialize VAD once
  if (!vadRef.current) {
    vadRef.current = getVADInstance({
      silenceThresholdMs: silenceThreshold,
      minPauseThresholdMs: 500, // Ignore pauses < 500ms
    });
  }

  // ============================================================================
  // End-of-Utterance Handler (called by any detection method)
  // ============================================================================
  
  const handleEndOfUtterance = useCallback(async (source: string) => {
    console.log(`⏱️ End-of-Utterance detected from: ${source}`);
    
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
      console.log('⏹️ No transcript - ignoring EOU');
      return;
    }
    
    console.log('🎯 AUTO-SUBMIT TRIGGERED!');
    console.log(`📝 Transcript: "${currentTranscript}"`);
    console.log(`🔍 Detection method: ${source}`);
    
    hasAutoSubmittedRef.current = true;
    
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
  // iOS Voice Recognition Setup (ONCE on mount)
  // ============================================================================
  
  useEffect(() => {
    if (Platform.OS !== 'ios') return;
    
    console.log('🔧 Setting up iOS Voice handlers with RMS VAD...');
    
    Voice.onSpeechStart = () => {
      console.log('🎤 Speech started (iOS)');
      setIsListening(true);
      hasAutoSubmittedRef.current = false;
      isManualStopRef.current = false;
      
      // Start RMS VAD monitoring
      if (enableRMSVAD && vadRef.current) {
        vadRef.current.start({
          onSpeechStart: () => {
            console.log('🗣️ RMS VAD: Speech detected');
          },
          onSpeechEnd: () => {
            console.log('🤫 RMS VAD: Silence detected');
          },
          onEndOfUtterance: () => {
            handleEndOfUtterance('RMS_VAD');
          },
        }).catch(error => {
          console.warn('⚠️ Failed to start RMS VAD:', error);
        });
      }
    };

    Voice.onSpeechEnd = () => {
      console.log('🎤 Speech ended (iOS)');
      
      const currentTranscript = finalTranscriptRef.current.trim();
      
      console.log('📊 iOS onSpeechEnd state:', {
        hasAutoSubmitted: hasAutoSubmittedRef.current,
        isManualStop: isManualStopRef.current,
        hasTranscript: !!currentTranscript,
      });
      
      // iOS detected silence - trigger EOU if not already done
      // This is our SECONDARY detection (RMS VAD is primary)
      if (enableAutoSubmit && !hasAutoSubmittedRef.current && !isManualStopRef.current && currentTranscript) {
        handleEndOfUtterance('iOS_onSpeechEnd');
      }
      
      // Stop VAD monitoring
      if (enableRMSVAD && vadRef.current) {
        vadRef.current.stop();
      }
    };

    Voice.onSpeechPartialResults = (event) => {
      if (event.value && event.value.length > 0) {
        const text = event.value[0];
        console.log('📝 Partial:', text);
        setTranscript(text);
        finalTranscriptRef.current = text;
      }
    };

    Voice.onSpeechResults = (event) => {
      if (event.value && event.value.length > 0) {
        const text = event.value[0];
        console.log('📝 Final:', text);
        setTranscript(text);
        finalTranscriptRef.current = text;
      }
    };

    Voice.onSpeechError = (event) => {
      console.error('❌ Speech error (iOS):', event.error);
      setIsListening(false);
      hasAutoSubmittedRef.current = false;
      isManualStopRef.current = false;
      
      // Stop VAD on error
      if (enableRMSVAD && vadRef.current) {
        vadRef.current.stop();
      }
      
      handleVoiceError(event.error);
    };
    
    console.log('✅ iOS Voice handlers registered with RMS VAD support');

    return () => {
      console.log('🧹 Cleaning up Voice and VAD...');
      
      if (vadRef.current) {
        vadRef.current.stop();
      }
      
      Voice.destroy().then(Voice.removeAllListeners).catch((err) => {
        console.warn('Voice cleanup error:', err);
      });
    };
  }, [handleEndOfUtterance, enableRMSVAD]); // Include deps for callbacks

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

      if (Platform.OS === 'ios') {
        console.log('🎤 Starting iOS voice with RMS VAD...');
        console.log('⚙️ Auto-submit config:', {
          enabled: enableAutoSubmit,
          threshold: `${silenceThreshold}ms`,
          rmsVAD: enableRMSVAD,
          hasCallback: !!onAutoSubmitRef.current,
        });
        
        try {
          // Stop any existing Voice session
          await Voice.stop().catch(() => {});
          await Voice.cancel().catch(() => {});
          
          await new Promise(resolve => setTimeout(resolve, 100));
          
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
        // Android implementation
        console.log('🎤 Starting Android STT...');
        setIsListening(true);
        
        // Note: For Android, we would configure SpeechRecognizer with
        // EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS
        // See implementation notes below
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
      
      // Stop VAD first
      if (enableRMSVAD && vadRef.current) {
        await vadRef.current.stop();
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
      
      // Stop VAD
      if (enableRMSVAD && vadRef.current) {
        await vadRef.current.stop();
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

// ============================================================================
// ANDROID IMPLEMENTATION NOTES
// ============================================================================

/**
 * For Android, configure SpeechRecognizer with proper silence thresholds:
 * 
 * ```java
 * Intent intent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
 * intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, 
 *                 RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
 * intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, "en-US");
 * 
 * // Configure silence detection (industry standard values)
 * intent.putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 
 *                 1500);  // 1.5 seconds
 * intent.putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 
 *                 800);   // 0.8 seconds (mid-speech pause tolerance)
 * intent.putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, 
 *                 500);   // Minimum 0.5 seconds of speech
 * 
 * speechRecognizer.startListening(intent);
 * ```
 * 
 * Then implement RecognitionListener:
 * 
 * ```java
 * @Override
 * public void onEndOfSpeech() {
 *     // Android detected end of utterance
 *     // Trigger auto-submit here
 * }
 * ```
 * 
 * References:
 * - https://developer.android.com/reference/android/speech/RecognizerIntent
 * - https://developer.android.com/reference/android/speech/SpeechRecognizer
 */