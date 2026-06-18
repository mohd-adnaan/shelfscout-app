/**
 * src/hooks/useSTT_Enhanced.ts
 * 
 * Enhanced Speech-to-Text hook with automatic silence detection
 * 
 * FIXED: OpenAI-backed end-of-utterance validation (Mar 14, 2026)
 * - Uses OpenAI turn detection before auto-submit
 * - Keeps local silence fallback if OpenAI is unavailable
 * - Prevents duplicate auto-submits with request/submit guards
 * 
 * Features:
 * - iOS native voice recognition
 * - OpenAI-based end-of-utterance validation
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
import { openAIVADService } from '../services/OpenAIVADService';

// ============================================================================
// Types
// ============================================================================

interface UseSTTOptions {
  /** Callback when auto-submit is triggered (silence detected) */
  onAutoSubmit?: (transcript?: string) => void;
  /** Enable auto-submit feature */
  enableAutoSubmit?: boolean;
  /** Silence threshold in ms before auto-submit (default: 1500) */
  silenceThreshold?: number;
  /** Enable OpenAI VAD validation (default: true) */
  enableOpenAIVAD?: boolean;
  /** Legacy option kept for callers from the previous STT hook. */
  enableRMSVAD?: boolean;
  /** Minimum confidence required from OpenAI VAD (default: 0.55) */
  openAIVADMinConfidence?: number;
  /**
   * When true, the hook will NOT register Voice listeners or call
   * Voice.destroy(). Use this when another hook (e.g. useWakeWordSTT)
   * owns the Voice singleton.
   */
  disabled?: boolean;
}

interface UseSTTReturn {
  startListening: (gracePeriodMs?: number) => Promise<void>;
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
const OPENAI_VAD_RECHECK_INTERVAL_MS = 350;
const OPENAI_VAD_REQUEST_TIMEOUT_MS = 2500;

// ============================================================================
// Hook Implementation
// ============================================================================

export const useSTT = (options: UseSTTOptions = {}): UseSTTReturn => {
  const {
    onAutoSubmit,
    enableAutoSubmit = true,
    silenceThreshold = DEFAULT_SILENCE_THRESHOLD,
    enableOpenAIVAD = true,
    openAIVADMinConfidence = 0.55,
    disabled = false,
  } = options;

  // State
  const [isListening, setIsListening] = useState(false);
  const [transcript, setTranscript] = useState('');
  const [error, setError] = useState<string | null>(null);

  // Refs for internal state management
  const transcriptRef = useRef('');
  const silenceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const lastSpeechTimeRef = useRef<number>(Date.now());
  const isManualStopRef = useRef(false);
  const openAIVadRequestSeqRef = useRef(0);
  const hasHeardSpeechRef = useRef(false);
  
  // ✅ FIX: Track if we've already auto-submitted for this utterance
  const hasAutoSubmittedRef = useRef(false);
  
  // ✅ FIX: Track if we're currently processing an auto-submit
  const isAutoSubmittingRef = useRef(false);

  // ✅ VOICEOVER FIX: Grace period — discard results arriving within this window
  // When VoiceOver is on, it reads UI labels aloud right as STT starts.
  // The mic picks up VoiceOver's speech. Instead of delaying STT start (which
  // causes race conditions), we start STT immediately but discard any results
  // that arrive within the grace window.
  const sttStartTimeRef = useRef<number>(0);
  const gracePeriodMsRef = useRef<number>(0);

  // ============================================================================
  // Cleanup Functions
  // ============================================================================

  const clearSilenceTimer = useCallback(() => {
    if (silenceTimerRef.current) {
      clearTimeout(silenceTimerRef.current);
      silenceTimerRef.current = null;
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
    // Call the callback
    console.log('🎯 Calling onAutoSubmit callback...');
    
    try {
      onAutoSubmit(transcriptRef.current);
    } finally {
      // ✅ FIX: Clear processing flag after callback completes
      // (but keep hasAutoSubmitted true until next startListening)
      isAutoSubmittingRef.current = false;
    }
  }, [onAutoSubmit, enableAutoSubmit, clearSilenceTimer]);

  // ============================================================================
  // OpenAI VAD validation
  // ============================================================================

  const validateWithOpenAIVAD = useCallback(async (source: string) => {
    if (!enableAutoSubmit || hasAutoSubmittedRef.current || isManualStopRef.current) {
      return;
    }

    const currentTranscript = transcriptRef.current.trim();
    if (!currentTranscript) {
      return;
    }

    const silenceDurationMs = Date.now() - lastSpeechTimeRef.current;

    if (silenceDurationMs < silenceThreshold) {
      return;
    }

    if (!enableOpenAIVAD || !openAIVADService.isConfigured()) {
      console.log(`⚠️ [${source}] OpenAI VAD unavailable, using local fallback`);
      triggerAutoSubmit(`${source}_LocalFallback`);
      return;
    }

    const requestSeq = ++openAIVadRequestSeqRef.current;

    try {
      const timeoutPromise = new Promise<never>((_, reject) => {
        setTimeout(() => reject(new Error('OpenAI VAD timeout')), OPENAI_VAD_REQUEST_TIMEOUT_MS);
      });

      const result = await Promise.race([
        openAIVADService.detectEndOfUtterance({
          transcript: currentTranscript,
          silenceDurationMs,
          silenceThresholdMs: silenceThreshold,
        }),
        timeoutPromise,
      ]);

      // Ignore stale responses from older requests.
      if (requestSeq !== openAIVadRequestSeqRef.current || hasAutoSubmittedRef.current) {
        return;
      }

      if (result.shouldAutoSubmit && result.confidence >= openAIVADMinConfidence) {
        console.log('✅ OpenAI VAD confirmed end-of-utterance:', result);
        triggerAutoSubmit('OpenAI_VAD');
        return;
      }

      console.log('⏳ OpenAI VAD says continue listening, scheduling recheck:', result);
      clearSilenceTimer();
      silenceTimerRef.current = setTimeout(() => {
        validateWithOpenAIVAD('OpenAI_VAD_Recheck').catch((err) => {
          console.warn('⚠️ OpenAI VAD recheck failed:', err?.message || err);
        });
      }, OPENAI_VAD_RECHECK_INTERVAL_MS);
    } catch (err: any) {
      console.warn(`⚠️ [${source}] OpenAI VAD failed, using local fallback:`, err?.message || err);
      triggerAutoSubmit(`${source}_LocalFallback`);
    }
  }, [
    clearSilenceTimer,
    enableAutoSubmit,
    enableOpenAIVAD,
    openAIVADMinConfidence,
    silenceThreshold,
    triggerAutoSubmit,
  ]);

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
    
    console.log(`⏱️ EOU timer started: ${silenceThreshold}ms remaining`);
    
    silenceTimerRef.current = setTimeout(() => {
      validateWithOpenAIVAD('Silence_Timer').catch((err) => {
        console.warn('⚠️ OpenAI VAD timer check failed:', err?.message || err);
      });
    }, silenceThreshold);
  }, [silenceThreshold, clearSilenceTimer, validateWithOpenAIVAD]);

  // ============================================================================
  // Voice Event Handlers
  // ============================================================================

  const onSpeechStart = useCallback((_e: SpeechStartEvent) => {
    console.log('🎤 Speech started (iOS)');
    lastSpeechTimeRef.current = Date.now();
    clearSilenceTimer();
    openAIVadRequestSeqRef.current += 1;
  }, [clearSilenceTimer]);

  const onSpeechResults = useCallback((e: SpeechResultsEvent) => {
    const results = e.value || [];
    const finalResult = results[0] || '';
    
    if (finalResult) {
      // ✅ VOICEOVER FIX: Discard results during grace period
      const elapsed = Date.now() - sttStartTimeRef.current;
      if (elapsed < gracePeriodMsRef.current) {
        console.log(`♿ [Grace] Discarding result (${elapsed}ms < ${gracePeriodMsRef.current}ms):`, finalResult);
        return;
      }

      transcriptRef.current = finalResult;
      setTranscript(finalResult);
      lastSpeechTimeRef.current = Date.now();
      hasHeardSpeechRef.current = true;
      
      console.log("'📝 Final:'", `'${finalResult}'`);
      
      // Cancel any pending silence timer since we got new speech
      if (!hasAutoSubmittedRef.current) {
        startSilenceTimer();
      }
    }
  }, [startSilenceTimer]);

  const onSpeechPartialResults = useCallback((e: SpeechResultsEvent) => {
    const results = e.value || [];
    const partialResult = results[0] || '';
    
    if (partialResult) {
      // ✅ VOICEOVER FIX: Discard results during grace period
      const elapsed = Date.now() - sttStartTimeRef.current;
      if (elapsed < gracePeriodMsRef.current) {
        console.log(`♿ [Grace] Discarding partial (${elapsed}ms < ${gracePeriodMsRef.current}ms):`, partialResult);
        return;
      }

      transcriptRef.current = partialResult;
      setTranscript(partialResult);
      lastSpeechTimeRef.current = Date.now();
      hasHeardSpeechRef.current = true;
      
      console.log("'📝 Partial:'", `'${partialResult}'`);

      if (!hasAutoSubmittedRef.current) {
        startSilenceTimer();
      }
    }
  }, [startSilenceTimer]);

  const onSpeechEnd = useCallback((_e: SpeechEndEvent) => {
    console.log('🎤 Speech ended (iOS)');

    // ✅ VOICEOVER FIX: If no real transcript made it past the grace period,
    // don't trigger auto-submit (it was just VoiceOver noise).
    const hasRealTranscript = transcriptRef.current.trim().length > 0;

    console.log("'📊 iOS onSpeechEnd state:'", {
      hasAutoSubmitted: hasAutoSubmittedRef.current,
      isManualStop: isManualStopRef.current,
      hasTranscript: hasRealTranscript,
    });
    
    // ✅ FIX: Only trigger if not already auto-submitted and not manual stop
    if (!isManualStopRef.current && 
        !hasAutoSubmittedRef.current && 
        hasRealTranscript && 
        enableAutoSubmit && 
        onAutoSubmit) {
      validateWithOpenAIVAD('iOS_onSpeechEnd').catch((err) => {
        console.warn('⚠️ OpenAI VAD speech-end check failed:', err?.message || err);
      });
    }
  }, [enableAutoSubmit, onAutoSubmit, validateWithOpenAIVAD]);

  const onSpeechError = useCallback((e: SpeechErrorEvent) => {
    console.error('❌ Speech error:', e.error);
    setError(e.error?.message || 'Speech recognition error');
    clearSilenceTimer();
    openAIVadRequestSeqRef.current += 1;
    setIsListening(false);
    hasHeardSpeechRef.current = false;
  }, [clearSilenceTimer]);

  // ============================================================================
  // Setup Voice Listeners
  // ============================================================================

  useEffect(() => {
    // When disabled (e.g. glasses mode active), do NOT register listeners.
    // Another hook (useWakeWordSTT) owns the Voice singleton.
    if (disabled) {
      console.log('ℹ️ [STT] Disabled — skipping Voice listener registration');
      return;
    }

    Voice.onSpeechStart = onSpeechStart;
    Voice.onSpeechEnd = onSpeechEnd;
    Voice.onSpeechResults = onSpeechResults;
    Voice.onSpeechPartialResults = onSpeechPartialResults;
    Voice.onSpeechError = onSpeechError;

    return () => {
      if (!disabled) {
        Voice.destroy().then(Voice.removeAllListeners);
      }
      clearSilenceTimer();
    };
  }, [disabled, onSpeechStart, onSpeechEnd, onSpeechResults, onSpeechPartialResults, onSpeechError, clearSilenceTimer]);

  // ============================================================================
  // Public Methods
  // ============================================================================

  const startListening = useCallback(async (gracePeriodMs: number = 0) => {
    try {
      setError(null);
      setTranscript('');
      transcriptRef.current = '';
      isManualStopRef.current = false;
      
      // ✅ FIX: Reset auto-submit flag for new listening session
      hasAutoSubmittedRef.current = false;
      isAutoSubmittingRef.current = false;
      hasHeardSpeechRef.current = false;

      // ✅ VOICEOVER FIX: Set grace period for discarding early results
      gracePeriodMsRef.current = gracePeriodMs;
      
      console.log('🎤 Starting iOS voice with OpenAI VAD...');
      console.log("'⚙️ Auto-submit config:'", {
        enabled: enableAutoSubmit,
        threshold: `${silenceThreshold}ms`,
        openAIVAD: enableOpenAIVAD,
        hasCallback: !!onAutoSubmit,
        gracePeriodMs,
      });

      openAIVadRequestSeqRef.current += 1;

      // ✅ FIX: Force-destroy any existing Voice session BEFORE starting.
      // After emergency stop, Voice.cancel() doesn't always fully reset the
      // native iOS speech recognizer. Voice.destroy() does a hard reset.
      // This prevents "Speech recognition already started!" errors.
      try {
        await Voice.cancel();
      } catch { /* ignore — may not be active */ }
      try {
        await Voice.destroy();
      } catch { /* ignore */ }

      // Re-register listeners after destroy
      Voice.onSpeechStart = onSpeechStart;
      Voice.onSpeechEnd = onSpeechEnd;
      Voice.onSpeechResults = onSpeechResults;
      Voice.onSpeechPartialResults = onSpeechPartialResults;
      Voice.onSpeechError = onSpeechError;

      // ✅ VOICEOVER FIX: Record start time BEFORE Voice.start()
      sttStartTimeRef.current = Date.now();

      await Voice.start('en-US');
      setIsListening(true);
      
      console.log('✅ iOS voice started - waiting for speech...');
      if (gracePeriodMs > 0) {
        console.log(`♿ Grace period active: ${gracePeriodMs}ms (discarding VoiceOver noise)`);
      }

    } catch (err: any) {
      console.error('❌ Failed to start voice:', err);
      setError(err.message || 'Failed to start voice recognition');
      setIsListening(false);
    }
  }, [
    enableAutoSubmit,
    silenceThreshold,
    enableOpenAIVAD,
    onAutoSubmit,
    onSpeechStart,
    onSpeechEnd,
    onSpeechResults,
    onSpeechPartialResults,
    onSpeechError,
    startSilenceTimer,
  ]);

  const stopListening = useCallback(async (): Promise<string> => {
    try {
      console.log('🛑 Stopping STT...');
      isManualStopRef.current = true;
      openAIVadRequestSeqRef.current += 1;
      
      clearSilenceTimer();
      
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
  }, [clearSilenceTimer]);

  const cancelListening = useCallback(async () => {
    try {
      console.log('🛑 Canceling STT...');
      isManualStopRef.current = true;
      
      // ✅ FIX: Set auto-submitted flag to prevent any pending auto-submits
      hasAutoSubmittedRef.current = true;
      openAIVadRequestSeqRef.current += 1;
      
      clearSilenceTimer();
      
      // ✅ FIX: Force-destroy to ensure clean state for next start
      try { await Voice.cancel(); } catch { }
      try { await Voice.destroy(); } catch { }
      
      setIsListening(false);
      setTranscript('');
      transcriptRef.current = '';
    } catch (err: any) {
      console.error('❌ Failed to cancel voice:', err);
      setIsListening(false);
    }
  }, [clearSilenceTimer]);

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
