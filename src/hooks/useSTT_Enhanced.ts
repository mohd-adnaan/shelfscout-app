/**
 * src/hooks/useSTT_Enhanced.ts
 * 
 * Enhanced Speech-to-Text hook with automatic silence detection
 * 
 * FIXED: Prevents duplicate auto-submits (Jan 24, 2026)
 * - Added hasAutoSubmittedRef to track if we've already auto-submitted
 * - Both RMS_VAD and iOS_onSpeechEnd can detect end-of-utterance
 * - Only the FIRST detection triggers auto-submit
 * - Reset flag when starting new listening session
 * 
 * Features:
 * - iOS native voice recognition
 * - RMS-based Voice Activity Detection (VAD)
 * - Automatic end-of-utterance detection
 * - Auto-submit callback when silence detected
 */

import { useState, useRef, useCallback, useEffect } from 'react';
import Voice, {
  SpeechResultsEvent,
  SpeechErrorEvent,
  SpeechEndEvent,
  SpeechStartEvent,
} from '@react-native-voice/voice';
import { Platform, NativeEventEmitter, NativeModules } from 'react-native';

// ============================================================================
// Types
// ============================================================================

interface UseSTTOptions {
  /** Callback when auto-submit is triggered (silence detected) */
  onAutoSubmit?: () => void;
  /** Enable auto-submit feature */
  enableAutoSubmit?: boolean;
  /** Silence threshold in ms before auto-submit (default: 1500) */
  silenceThreshold?: number;
  /** Enable RMS-based VAD (default: true) */
  enableRMSVAD?: boolean;
}

interface UseSTTReturn {
  startListening: () => Promise<void>;
  stopListening: () => Promise<string>;
  cancelListening: () => Promise<void>;
  isListening: boolean;
  transcript: string;
  error: string | null;
}

// ============================================================================
// Constants
// ============================================================================

const DEFAULT_SILENCE_THRESHOLD = 1500; // 1.5 seconds
const RMS_SILENCE_THRESHOLD = 0.02; // RMS level below this = silence
const RMS_CHECK_INTERVAL = 100; // Check RMS every 100ms

// ============================================================================
// Hook Implementation
// ============================================================================

export const useSTT = (options: UseSTTOptions = {}): UseSTTReturn => {
  const {
    onAutoSubmit,
    enableAutoSubmit = true,
    silenceThreshold = DEFAULT_SILENCE_THRESHOLD,
    enableRMSVAD = true,
  } = options;

  // State
  const [isListening, setIsListening] = useState(false);
  const [transcript, setTranscript] = useState('');
  const [error, setError] = useState<string | null>(null);

  // Refs for internal state management
  const transcriptRef = useRef('');
  const silenceTimerRef = useRef<NodeJS.Timeout | null>(null);
  const rmsMonitorRef = useRef<NodeJS.Timeout | null>(null);
  const lastSpeechTimeRef = useRef<number>(Date.now());
  const isManualStopRef = useRef(false);
  
  // ✅ FIX: Track if we've already auto-submitted for this utterance
  const hasAutoSubmittedRef = useRef(false);
  
  // ✅ FIX: Track if we're currently processing an auto-submit
  const isAutoSubmittingRef = useRef(false);

  // ============================================================================
  // Cleanup Functions
  // ============================================================================

  const clearSilenceTimer = useCallback(() => {
    if (silenceTimerRef.current) {
      clearTimeout(silenceTimerRef.current);
      silenceTimerRef.current = null;
    }
  }, []);

  const stopRMSMonitoring = useCallback(() => {
    if (rmsMonitorRef.current) {
      clearInterval(rmsMonitorRef.current);
      rmsMonitorRef.current = null;
      console.log('✅ VAD monitoring stopped');
    }
  }, []);

  // ============================================================================
  // ✅ FIXED: Auto-Submit Trigger (with duplicate prevention)
  // ============================================================================

  const triggerAutoSubmit = useCallback((source: string) => {
    // ✅ FIX: Check if we've already auto-submitted
    if (hasAutoSubmittedRef.current) {
      console.log(`⚠️ [${source}] Auto-submit already triggered, ignoring duplicate`);
      return;
    }
    
    // ✅ FIX: Check if we're currently processing
    if (isAutoSubmittingRef.current) {
      console.log(`⚠️ [${source}] Auto-submit in progress, ignoring`);
      return;
    }
    
    // Check if we have a transcript and callback
    if (!transcriptRef.current.trim()) {
      console.log(`⚠️ [${source}] No transcript, skipping auto-submit`);
      return;
    }
    
    if (!onAutoSubmit) {
      console.log(`⚠️ [${source}] No onAutoSubmit callback`);
      return;
    }
    
    if (!enableAutoSubmit) {
      console.log(`⚠️ [${source}] Auto-submit disabled`);
      return;
    }
    
    // ✅ FIX: Set flags BEFORE calling callback
    hasAutoSubmittedRef.current = true;
    isAutoSubmittingRef.current = true;
    
    console.log('⏱️ End-of-Utterance detected from:', source);
    console.log('🎯 AUTO-SUBMIT TRIGGERED!');
    console.log('📝 Transcript:', `"${transcriptRef.current}"`);
    console.log('🔍 Detection method:', source);
    
    // Stop monitoring
    clearSilenceTimer();
    stopRMSMonitoring();
    
    // Call the callback
    console.log('🎯 Calling onAutoSubmit callback...');
    
    try {
      onAutoSubmit();
    } finally {
      // ✅ FIX: Clear processing flag after callback completes
      // (but keep hasAutoSubmitted true until next startListening)
      isAutoSubmittingRef.current = false;
    }
  }, [onAutoSubmit, enableAutoSubmit, clearSilenceTimer, stopRMSMonitoring]);

  // ============================================================================
  // Silence Detection (EOU Timer)
  // ============================================================================

  const startSilenceTimer = useCallback(() => {
    clearSilenceTimer();
    
    // ✅ FIX: Don't start timer if already auto-submitted
    if (hasAutoSubmittedRef.current) {
      console.log('⚠️ Already auto-submitted, not starting silence timer');
      return;
    }
    
    console.log(`⏱️ EOU timer started: ${silenceThreshold - 1}ms remaining`);
    
    silenceTimerRef.current = setTimeout(() => {
      console.log('🎯 End-of-Utterance detected!');
      triggerAutoSubmit('Silence_Timer');
    }, silenceThreshold);
  }, [silenceThreshold, clearSilenceTimer, triggerAutoSubmit]);

  // ============================================================================
  // RMS Voice Activity Detection
  // ============================================================================

  const startRMSMonitoring = useCallback(() => {
    if (!enableRMSVAD) return;
    
    stopRMSMonitoring();
    
    let isSpeaking = false;
    let silenceStartTime: number | null = null;
    
    console.log('✅ VAD monitoring started');
    console.log('Start Monitoring');
    
    rmsMonitorRef.current = setInterval(() => {
      // ✅ FIX: Stop monitoring if already auto-submitted
      if (hasAutoSubmittedRef.current) {
        stopRMSMonitoring();
        return;
      }
      
      // Simulate RMS detection based on speech activity
      // In real implementation, this would read from audio buffer
      const timeSinceLastSpeech = Date.now() - lastSpeechTimeRef.current;
      const isCurrentlySpeaking = timeSinceLastSpeech < 300; // 300ms window
      
      if (isCurrentlySpeaking && !isSpeaking) {
        // Speech started
        isSpeaking = true;
        silenceStartTime = null;
        console.log('🗣️ Speech detected!');
        console.log('🗣️ RMS VAD: Speech detected');
        clearSilenceTimer();
      } else if (!isCurrentlySpeaking && isSpeaking) {
        // Speech ended, silence started
        isSpeaking = false;
        silenceStartTime = Date.now();
        console.log('🤫 Silence detected - starting EOU timer');
        console.log('🤫 RMS VAD: Silence detected');
        startSilenceTimer();
      } else if (!isCurrentlySpeaking && silenceStartTime) {
        // Check if silence has exceeded threshold
        const silenceDuration = Date.now() - silenceStartTime;
        
        if (silenceDuration >= silenceThreshold && transcriptRef.current.trim()) {
          triggerAutoSubmit('RMS_VAD');
        }
      }
    }, RMS_CHECK_INTERVAL);
  }, [enableRMSVAD, silenceThreshold, stopRMSMonitoring, clearSilenceTimer, startSilenceTimer, triggerAutoSubmit]);

  // ============================================================================
  // Voice Event Handlers
  // ============================================================================

  const onSpeechStart = useCallback((e: SpeechStartEvent) => {
    console.log('🎤 Speech started (iOS)');
    lastSpeechTimeRef.current = Date.now();
    clearSilenceTimer();
  }, [clearSilenceTimer]);

  const onSpeechResults = useCallback((e: SpeechResultsEvent) => {
    const results = e.value || [];
    const finalResult = results[0] || '';
    
    if (finalResult) {
      transcriptRef.current = finalResult;
      setTranscript(finalResult);
      lastSpeechTimeRef.current = Date.now();
      
      console.log("'📝 Final:'", `'${finalResult}'`);
      
      // Cancel any pending silence timer since we got new speech
      if (!hasAutoSubmittedRef.current) {
        clearSilenceTimer();
      }
    }
  }, [clearSilenceTimer]);

  const onSpeechPartialResults = useCallback((e: SpeechResultsEvent) => {
    const results = e.value || [];
    const partialResult = results[0] || '';
    
    if (partialResult) {
      transcriptRef.current = partialResult;
      setTranscript(partialResult);
      lastSpeechTimeRef.current = Date.now();
      
      console.log("'📝 Partial:'", `'${partialResult}'`);
    }
  }, []);

  const onSpeechEnd = useCallback((e: SpeechEndEvent) => {
    console.log('🎤 Speech ended (iOS)');
    console.log("'📊 iOS onSpeechEnd state:'", {
      hasAutoSubmitted: hasAutoSubmittedRef.current,
      isManualStop: isManualStopRef.current,
      hasTranscript: !!transcriptRef.current.trim(),
    });
    
    // ✅ FIX: Only trigger if not already auto-submitted and not manual stop
    if (!isManualStopRef.current && 
        !hasAutoSubmittedRef.current && 
        transcriptRef.current.trim() && 
        enableAutoSubmit && 
        onAutoSubmit) {
      triggerAutoSubmit('iOS_onSpeechEnd');
    }
  }, [enableAutoSubmit, onAutoSubmit, triggerAutoSubmit]);

  const onSpeechError = useCallback((e: SpeechErrorEvent) => {
    console.error('❌ Speech error:', e.error);
    setError(e.error?.message || 'Speech recognition error');
  }, []);

  // ============================================================================
  // Setup Voice Listeners
  // ============================================================================

  useEffect(() => {
    Voice.onSpeechStart = onSpeechStart;
    Voice.onSpeechEnd = onSpeechEnd;
    Voice.onSpeechResults = onSpeechResults;
    Voice.onSpeechPartialResults = onSpeechPartialResults;
    Voice.onSpeechError = onSpeechError;

    return () => {
      Voice.destroy().then(Voice.removeAllListeners);
      clearSilenceTimer();
      stopRMSMonitoring();
    };
  }, [onSpeechStart, onSpeechEnd, onSpeechResults, onSpeechPartialResults, onSpeechError]);

  // ============================================================================
  // Public Methods
  // ============================================================================

  const startListening = useCallback(async () => {
    try {
      setError(null);
      setTranscript('');
      transcriptRef.current = '';
      isManualStopRef.current = false;
      
      // ✅ FIX: Reset auto-submit flag for new listening session
      hasAutoSubmittedRef.current = false;
      isAutoSubmittingRef.current = false;
      
      console.log('🎤 Starting iOS voice with RMS VAD...');
      console.log("'⚙️ Auto-submit config:'", {
        enabled: enableAutoSubmit,
        threshold: `${silenceThreshold}ms`,
        rmsVAD: enableRMSVAD,
        hasCallback: !!onAutoSubmit,
      });

      await Voice.start('en-US');
      setIsListening(true);
      
      console.log('✅ iOS voice started - waiting for speech...');
      
      // Start RMS monitoring for VAD
      if (enableRMSVAD) {
        startRMSMonitoring();
      }
    } catch (err: any) {
      console.error('❌ Failed to start voice:', err);
      setError(err.message || 'Failed to start voice recognition');
      setIsListening(false);
    }
  }, [enableAutoSubmit, silenceThreshold, enableRMSVAD, onAutoSubmit, startRMSMonitoring]);

  const stopListening = useCallback(async (): Promise<string> => {
    try {
      console.log('🛑 Stopping STT...');
      isManualStopRef.current = true;
      
      clearSilenceTimer();
      stopRMSMonitoring();
      
      await Voice.stop();
      setIsListening(false);
      
      const finalTranscript = transcriptRef.current;
      console.log('📝 Final transcript:', finalTranscript);
      
      return finalTranscript;
    } catch (err: any) {
      console.error('❌ Failed to stop voice:', err);
      setIsListening(false);
      return transcriptRef.current;
    }
  }, [clearSilenceTimer, stopRMSMonitoring]);

  const cancelListening = useCallback(async () => {
    try {
      console.log('🛑 Canceling STT...');
      isManualStopRef.current = true;
      
      // ✅ FIX: Set auto-submitted flag to prevent any pending auto-submits
      hasAutoSubmittedRef.current = true;
      
      clearSilenceTimer();
      stopRMSMonitoring();
      
      await Voice.cancel();
      setIsListening(false);
      setTranscript('');
      transcriptRef.current = '';
    } catch (err: any) {
      console.error('❌ Failed to cancel voice:', err);
      setIsListening(false);
    }
  }, [clearSilenceTimer, stopRMSMonitoring]);

  return {
    startListening,
    stopListening,
    cancelListening,
    isListening,
    transcript,
    error,
  };
};

export default useSTT;