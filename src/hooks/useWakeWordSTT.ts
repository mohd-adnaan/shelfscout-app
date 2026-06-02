/**
 * src/hooks/useWakeWordSTT.ts
 *
 * Wake-word activated Speech-to-Text for Meta glasses mode.
 *
 * When `useWearablesCamera` is ON this hook replaces the tap-to-speak flow.
 * It continuously listens via iOS native speech recognition (preferring the
 * selected glasses microphone route by default) and watches for the wake phrase
 * "hey shelfscout". Everything the user says AFTER the wake phrase is treated
 * as the query.
 *
 * Lifecycle:
 *   start() → iOS Voice.start() → partial/final results monitored
 *           → wake phrase detected → extract query text
 *           → silence detection (existing OpenAI VAD) → auto-submit query
 *           → pause during processing/TTS → resume after TTS completes
 *           → loop back to listening for next wake phrase
 *
 * iOS speech recognition terminates after ~60s of silence. The hook
 * auto-restarts transparently so the user perceives uninterrupted listening.
 */

import { useState, useRef, useCallback, useEffect } from 'react';
import Voice, {
  SpeechResultsEvent,
  SpeechErrorEvent,
  SpeechEndEvent,
  SpeechStartEvent,
} from '@react-native-voice/voice';
import { openAIVADService } from '../services/OpenAIVADService';
import { configureBluetoothRecordingSession } from '../utils/soundEffects';
import type { RecordingMicrophoneSource } from '../utils/soundEffects';

// ============================================================================
// Types
// ============================================================================

interface UseWakeWordSTTOptions {
  /** Callback fired with the extracted query (after wake phrase stripped) */
  onQueryDetected: (query: string) => void;
  /** Called when the wake phrase is first heard (before query is complete) */
  onWakeWordHeard?: () => void;
  /** Silence threshold in ms before auto-submitting the query (default: 1500) */
  silenceThreshold?: number;
  /** Enable OpenAI VAD validation (default: true) */
  enableOpenAIVAD?: boolean;
  /** Minimum OpenAI VAD confidence (default: 0.55) */
  openAIVADMinConfidence?: number;
  /** Whether the hook should be actively listening (master switch) */
  enabled: boolean;
  /** Preferred microphone source for wake-word listening in glasses mode */
  microphoneSource?: RecordingMicrophoneSource;
}

interface UseWakeWordSTTReturn {
  /** Whether the hook is currently listening for the wake word */
  isAwaitingWakeWord: boolean;
  /** Whether a query is being captured (wake word was heard) */
  isCapturingQuery: boolean;
  /** The current partial/final query text (after wake word strip) */
  queryTranscript: string;
  /** Debug: status line showing mic, voice state, errors */
  debugStatus: string;
  /** Debug: raw transcript from speech recognizer (before wake word strip) */
  debugRawTranscript: string;
  /** Pause listening (e.g. during TTS playback) */
  pause: () => Promise<void>;
  /** Resume listening after a pause */
  resume: () => Promise<void>;
  /** Force stop everything */
  stop: () => Promise<void>;
}

// ============================================================================
// Constants
// ============================================================================

const DEFAULT_SILENCE_THRESHOLD = 1500;
const OPENAI_VAD_RECHECK_INTERVAL_MS = 350;
const OPENAI_VAD_REQUEST_TIMEOUT_MS = 2500;

/**
 * Restart delay after iOS terminates a recognition session (~60s timeout).
 * Small enough to feel instant, large enough to avoid hammering the audio
 * session.
 */
const RESTART_DELAY_MS = 400;

/**
 * Maximum consecutive restart failures before giving up. Resets on
 * successful Voice.start().
 */
const MAX_RESTART_FAILURES = 5;

/**
 * Wake phrase variants the speech recognizer might produce.
 *
 * REAL-WORLD CALIBRATION (from device logs, BT mic via Ray-Ban Meta):
 * Apple's on-device speech recogniser frequently mis-hears "shelfscout":
 *   - "shelfscout" is not a dictionary word, so the recogniser substitutes
 *     phonetically similar tokens. Observed substitutions include:
 *       "shelf scout", "shell scout", "shelves", "shelves scout",
 *       "hey scout"  (← `shelf` gets dropped entirely; most common),
 *       "asian scout", "patient scout", "shell scout scott", "scout watson",
 *       "she scout", "shelf scott", "shell scott", "scout".
 *   - Sometimes the leading "hey" survives ("hey scout") and sometimes the
 *     "hey" gets merged with the next word ("asian", "patient").
 *
 * Strategy: list every commonly-observed variant. Matching is now
 * SUBSTRING (not prefix) to handle the case where the iOS recogniser
 * concatenates multiple utterances into one ever-growing FINAL transcript.
 */
const WAKE_PHRASES: string[] = [
  // Canonical forms
  'hey shelfscout',
  'hey shelf scout',
  'hey shelfscout,',
  'hey shelf scout,',
  'hey shellscout',
  'hi shelfscout',
  'hishelf scout',
  'hi shelfscout',
  'hi shelf scout',
  'hey she',
  'he she',
  'scout',
  'skout',
  'shelfcout',
  'shelves code',
  'Asian Scout',

  // "shelf" → "self" / "shell" / "shelves" substitutions
  'hey self scout',
  'hey self scout,',
  'hey shell scout',
  'hey shell scout,',
  'hey shelves scout',
  'hey shelves',
  'Hey Scout',
  'Hey Shell',
  'hey patient',


  // "hey" mis-merged with following word
  'asian scout',
  'patient scout',
  'a shelfscout',
  'a shelf scout',

  // "shelf" entirely dropped — most common mis-hearing in BT-mic logs
  'hey scout',
  'hey scott',
  'hey shell scott',
  'hey shell scott,',
  'he shall scout',
  'he shall scouts',
  'he shall scout Hazel Shell',
  'hey Shell',
  'hey Scott',
  'hey Shall',
  'he Scott',
  'scotland',
  'hi scott',
  'hi scount',
  'hi scout',


  // No-"hey" variants (when "hey" gets lost in BT compression)
  'shelfscout',
  'shelf scout',
  'shell scout',
  'shell scott',
  'shelves scout',
  'Haitian scout',
  'haitian',
];

/**
 * Minimum query length (after stripping the wake phrase) to be considered
 * valid. Prevents false positives from someone just saying "hey shelfscout"
 * with no actual question.
 */
const MIN_QUERY_LENGTH = 2;

/**
 * If the accumulated transcript exceeds this without a wake-word match, we
 * force-restart the recogniser. iOS sometimes keeps appending to a single
 * FINAL transcript across multiple utterances (observed in production logs:
 * one transcript grew past 200 chars over ~90 seconds of attempted wakes).
 * Force-restart clears the buffer so the next "hey shelfscout" actually
 * lands at position 0 of a fresh transcript.
 */
const MAX_NO_MATCH_TRANSCRIPT_LEN = 80;

// ============================================================================
// Helpers
// ============================================================================

/**
 * Search `text` for any wake phrase variant and return the substring that
 * follows the LAST occurrence (i.e. the user's query). Returns null if no
 * wake phrase variant is present anywhere in the transcript.
 *
 * Why "last occurrence" and not "first"?
 *   iOS STT accumulates a long transcript over time. If the user says the
 *   wake phrase twice (a retry), we want the query that follows the most
 *   recent wake — not stale text after the first one.
 *
 * Word-boundary aware: a phrase is only considered matched if it sits on
 * word boundaries, so "shelf" doesn't accidentally match inside "shelves".
 */
function stripWakePhrase(text: string): string | null {
  const lower = text.toLowerCase().trim();
  if (!lower) return null;

  let bestEndIndex = -1;     // position immediately AFTER the matched phrase
  let bestPhrase = '';

  for (const phrase of WAKE_PHRASES) {
    // Find the LAST occurrence of this phrase in the lower-cased transcript
    let idx = lower.lastIndexOf(phrase);
    while (idx !== -1) {
      // Word-boundary check: char before must not be alphanumeric, char
      // after must not be alphanumeric (or end-of-string).
      const charBefore = idx === 0 ? ' ' : lower[idx - 1];
      const charAfter = lower[idx + phrase.length] ?? ' ';
      const isWordBoundaryBefore = !/[a-z0-9]/.test(charBefore);
      const isWordBoundaryAfter = !/[a-z0-9]/.test(charAfter);

      if (isWordBoundaryBefore && isWordBoundaryAfter) {
        const endIdx = idx + phrase.length;
        if (endIdx > bestEndIndex) {
          bestEndIndex = endIdx;
          bestPhrase = phrase;
        }
        break; // we already have the LAST occurrence of THIS phrase
      }
      // Not a word boundary, look earlier in the string for another match
      idx = lower.lastIndexOf(phrase, idx - 1);
    }
  }

  if (bestEndIndex === -1) return null;

  // Extract whatever comes after the matched wake phrase as the query.
  // Use the original-case `text` so user words keep their casing.
  let rest = text.substring(bestEndIndex).replace(/^[,\s.!?]+/, '').trim();
  console.log(`🎯 [WakeWord] Matched phrase "${bestPhrase}" → query: "${rest}"`);
  return rest;
}

/**
 * Check if a partial transcript contains the beginning of a wake phrase,
 * even if it's incomplete (e.g. just "hey" or "hey shelf").
 */
function containsPartialWakePhrase(text: string): boolean {
  const lower = text.toLowerCase().trim();
  // Check if any wake phrase starts with what we have
  return WAKE_PHRASES.some(phrase => phrase.startsWith(lower) && lower.length >= 3);
}

// ============================================================================
// Hook Implementation
// ============================================================================

export const useWakeWordSTT = (options: UseWakeWordSTTOptions): UseWakeWordSTTReturn => {
  const {
    onQueryDetected,
    onWakeWordHeard,
    enabled,
    microphoneSource = 'wearables',
    silenceThreshold = DEFAULT_SILENCE_THRESHOLD,
    enableOpenAIVAD = true,
    openAIVADMinConfidence = 0.55,
  } = options;

  // ── State ──────────────────────────────────────────────────────────────
  const [isAwaitingWakeWord, setIsAwaitingWakeWord] = useState(false);
  const [isCapturingQuery, setIsCapturingQuery] = useState(false);
  const [queryTranscript, setQueryTranscript] = useState('');
  const [debugStatus, setDebugStatus] = useState('Initializing...');
  const [debugRawTranscript, setDebugRawTranscript] = useState('');

  // ── Refs ───────────────────────────────────────────────────────────────
  const enabledRef = useRef(enabled);
  const microphoneSourceRef = useRef<RecordingMicrophoneSource>(microphoneSource);
  const isPausedRef = useRef(false);
  const isActiveRef = useRef(false);    // Voice.start() is live
  const isRestartingRef = useRef(false); // prevents overlapping restarts
  const restartFailCountRef = useRef(0);
  const wakeWordDetectedRef = useRef(false);
  const queryTextRef = useRef('');
  const lastSpeechTimeRef = useRef(Date.now());
  const silenceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const hasSubmittedRef = useRef(false);
  const openAIVadSeqRef = useRef(0);

  // Callback refs to avoid stale closures
  const onQueryDetectedRef = useRef(onQueryDetected);
  const onWakeWordHeardRef = useRef(onWakeWordHeard);
  useEffect(() => { onQueryDetectedRef.current = onQueryDetected; }, [onQueryDetected]);
  useEffect(() => { onWakeWordHeardRef.current = onWakeWordHeard; }, [onWakeWordHeard]);
  useEffect(() => { enabledRef.current = enabled; }, [enabled]);
  useEffect(() => { microphoneSourceRef.current = microphoneSource; }, [microphoneSource]);

  // Handler refs — populated after handler definitions, used in startRecognition
  // to re-register listeners right before Voice.start()
  const handleSpeechStartRef = useRef<(e: SpeechStartEvent) => void>(() => {});
  const handleSpeechEndRef = useRef<(e: SpeechEndEvent) => void>(() => {});
  const handleSpeechResultsRef = useRef<(e: SpeechResultsEvent) => void>(() => {});
  const handleSpeechPartialResultsRef = useRef<(e: SpeechResultsEvent) => void>(() => {});
  const handleSpeechErrorRef = useRef<(e: SpeechErrorEvent) => void>(() => {});

  // ── Silence timer management ───────────────────────────────────────────

  const clearSilenceTimer = useCallback(() => {
    if (silenceTimerRef.current) {
      clearTimeout(silenceTimerRef.current);
      silenceTimerRef.current = null;
    }
  }, []);

  // ── Submit query ───────────────────────────────────────────────────────

  const submitQuery = useCallback((source: string) => {
    if (hasSubmittedRef.current) {
      console.log(`⚠️ [WakeWord/${source}] Already submitted, ignoring`);
      return;
    }

    const query = queryTextRef.current.trim();
    if (query.length < MIN_QUERY_LENGTH) {
      console.log(`⚠️ [WakeWord/${source}] Query too short: "${query}"`);
      return;
    }

    hasSubmittedRef.current = true;
    clearSilenceTimer();

    console.log(`🎯 [WakeWord] QUERY SUBMITTED via ${source}: "${query}"`);
    setIsCapturingQuery(false);
    setQueryTranscript('');

    // Pause listening while the query is being processed.
    // The caller (App.tsx) will call resume() when TTS completes.
    isPausedRef.current = true;

    // Stop current recognition before handing off
    Voice.cancel().catch(() => {});
    isActiveRef.current = false;
    setIsAwaitingWakeWord(false);

    onQueryDetectedRef.current(query);
  }, [clearSilenceTimer]);

  // ── OpenAI VAD validation ──────────────────────────────────────────────

  const validateWithOpenAIVAD = useCallback(async (source: string) => {
    if (hasSubmittedRef.current) return;

    const query = queryTextRef.current.trim();
    if (query.length < MIN_QUERY_LENGTH) return;

    const silenceDurationMs = Date.now() - lastSpeechTimeRef.current;
    if (silenceDurationMs < silenceThreshold) return;

    if (!enableOpenAIVAD || !openAIVADService.isConfigured()) {
      console.log(`⚠️ [WakeWord/${source}] OpenAI VAD unavailable, local fallback`);
      submitQuery(`${source}_LocalFallback`);
      return;
    }

    const seq = ++openAIVadSeqRef.current;

    try {
      const result = await Promise.race([
        openAIVADService.detectEndOfUtterance({
          transcript: query,
          silenceDurationMs,
          silenceThresholdMs: silenceThreshold,
        }),
        new Promise<never>((_, reject) =>
          setTimeout(() => reject(new Error('timeout')), OPENAI_VAD_REQUEST_TIMEOUT_MS)
        ),
      ]);

      if (seq !== openAIVadSeqRef.current || hasSubmittedRef.current) return;

      if (result.shouldAutoSubmit && result.confidence >= openAIVADMinConfidence) {
        console.log('✅ [WakeWord] OpenAI VAD confirmed end-of-utterance:', result);
        submitQuery('OpenAI_VAD');
        return;
      }

      console.log('⏳ [WakeWord] OpenAI VAD: continue, scheduling recheck');
      clearSilenceTimer();
      silenceTimerRef.current = setTimeout(() => {
        validateWithOpenAIVAD('Recheck').catch(e =>
          console.warn('⚠️ [WakeWord] Recheck failed:', e?.message)
        );
      }, OPENAI_VAD_RECHECK_INTERVAL_MS);
    } catch (err: any) {
      console.warn(`⚠️ [WakeWord/${source}] VAD error, local fallback:`, err?.message);
      submitQuery(`${source}_LocalFallback`);
    }
  }, [clearSilenceTimer, enableOpenAIVAD, openAIVADMinConfidence, silenceThreshold, submitQuery]);

  // ── Silence timer trigger ──────────────────────────────────────────────

  const startSilenceTimer = useCallback(() => {
    clearSilenceTimer();
    if (hasSubmittedRef.current) return;

    silenceTimerRef.current = setTimeout(() => {
      validateWithOpenAIVAD('SilenceTimer').catch(e =>
        console.warn('⚠️ [WakeWord] Silence timer VAD failed:', e?.message)
      );
    }, silenceThreshold);
  }, [clearSilenceTimer, silenceThreshold, validateWithOpenAIVAD]);

  // ── Core: start / restart recognition ──────────────────────────────────

  const startRecognition = useCallback(async () => {
    if (isPausedRef.current || !enabledRef.current) return;
    if (isRestartingRef.current) return;

    isRestartingRef.current = true;
    setDebugStatus('Configuring audio...');

    try {
      // Clean up any lingering session
      try { await Voice.cancel(); } catch { /* ignore */ }
      try { await Voice.destroy(); } catch { /* ignore */ }

      const requestedMicSource = microphoneSourceRef.current;
      const audioResult = await configureBluetoothRecordingSession(requestedMicSource);
      const micInfo = audioResult.inputPort || 'unknown';
      const micType = audioResult.inputType || '?';
      const activeSource = audioResult.source || requestedMicSource;
      const fallbackSuffix = audioResult.fallbackReason
        ? ` fallback: ${audioResult.fallbackReason}`
        : '';
      setDebugStatus(`Mic: ${activeSource} - ${micInfo} (${micType})${fallbackSuffix}`);
      console.log('🎤 [WakeWord] Audio session configured:', JSON.stringify(audioResult));

      // Small delay to let audio session settle after category switch
      await new Promise(r => setTimeout(r, 350));

      // Re-register OUR listeners right before Voice.start()
      Voice.onSpeechStart = handleSpeechStartRef.current;
      Voice.onSpeechEnd = handleSpeechEndRef.current;
      Voice.onSpeechResults = handleSpeechResultsRef.current;
      Voice.onSpeechPartialResults = handleSpeechPartialResultsRef.current;
      Voice.onSpeechError = handleSpeechErrorRef.current;

      setDebugStatus(`Starting Voice... (mic: ${activeSource} - ${micInfo})`);
      await Voice.start('en-US');
      isActiveRef.current = true;
      restartFailCountRef.current = 0;

      if (!wakeWordDetectedRef.current) {
        setIsAwaitingWakeWord(true);
      }

      setDebugStatus(`✅ Listening (mic: ${activeSource} - ${micInfo})`);
      setDebugRawTranscript('');
      console.log('✅ [WakeWord] Voice recognition started');
    } catch (err: any) {
      const errMsg = err?.message || String(err);
      setDebugStatus(`❌ Voice.start FAILED: ${errMsg}`);
      console.error('❌ [WakeWord] Voice.start failed:', errMsg);
      restartFailCountRef.current++;
      isActiveRef.current = false;

      if (restartFailCountRef.current < MAX_RESTART_FAILURES && enabledRef.current && !isPausedRef.current) {
        const delay = RESTART_DELAY_MS * Math.min(restartFailCountRef.current, 3);
        setDebugStatus(`❌ Failed, retry #${restartFailCountRef.current} in ${delay}ms`);
        setTimeout(() => {
          isRestartingRef.current = false;
          startRecognition();
        }, delay);
        return;
      } else {
        setDebugStatus(`❌ GAVE UP after ${restartFailCountRef.current} failures: ${errMsg}`);
      }
    }

    isRestartingRef.current = false;
  }, []);

  // ── Voice event handlers ───────────────────────────────────────────────

  const handleSpeechStart = useCallback((_e: SpeechStartEvent) => {
    console.log('🎤 [WakeWord] ━━ onSpeechStart — mic is receiving audio');
    setDebugStatus('🎤 Mic hearing speech...');
    lastSpeechTimeRef.current = Date.now();
    clearSilenceTimer();
    openAIVadSeqRef.current++;
  }, [clearSilenceTimer]);

  const handleSpeechResults = useCallback((e: SpeechResultsEvent) => {
    const results = e.value || [];
    const text = results[0] || '';
    if (!text) return;

    lastSpeechTimeRef.current = Date.now();

    // Show raw transcript on screen for debugging
    setDebugRawTranscript(text);
    console.log(`🎤 [WakeWord] FINAL: "${text}"`);

    if (!wakeWordDetectedRef.current) {
      // ── Waiting for wake word ─────────────────────────────────────────
      const query = stripWakePhrase(text);
      if (query !== null) {
        // Wake phrase found!
        console.log('🎤 [WakeWord] Wake phrase detected! Query so far:', `"${query}"`);
        wakeWordDetectedRef.current = true;
        hasSubmittedRef.current = false;
        queryTextRef.current = query;
        setIsCapturingQuery(true);
        setIsAwaitingWakeWord(false);
        setQueryTranscript(query);
        onWakeWordHeardRef.current?.();

        if (query.length >= MIN_QUERY_LENGTH) {
          startSilenceTimer();
        }
      } else {
        // No wake phrase found — show what was heard on screen
        setDebugStatus(`Heard: "${text.substring(0, 40)}" (no wake match)`);
        console.log(`🎤 [WakeWord] No wake match in: "${text.toLowerCase().trim()}"`);

        // ── Anti-bloat: force-restart on runaway transcript ──────────────
        // iOS sometimes keeps appending to a single FINAL transcript across
        // multiple utterances. Once it grows large with no match, future
        // "hey shelfscout" attempts are buried in the middle and never make
        // it to the start of a fresh recognition session. Cancel now so
        // handleSpeechEnd fires and triggers a clean restart with an empty
        // buffer.
        if (text.length >= MAX_NO_MATCH_TRANSCRIPT_LEN) {
          console.log(
            `🔄 [WakeWord] Transcript too long (${text.length} chars) without match — force-restarting recogniser`
          );
          setDebugStatus('Resetting recogniser…');
          Voice.cancel().catch(() => {});
          isActiveRef.current = false;
          // handleSpeechEnd will auto-restart via its RESTART_DELAY_MS timer
        }
      }
    } else {
      // ── Capturing query (wake word already detected) ─────────────────
      // The full recognized text includes the wake phrase, so strip it.
      const query = stripWakePhrase(text);
      if (query !== null && query.length > 0) {
        queryTextRef.current = query;
        setQueryTranscript(query);

        if (!hasSubmittedRef.current && query.length >= MIN_QUERY_LENGTH) {
          startSilenceTimer();
        }
      }
    }
  }, [startSilenceTimer]);

  const handleSpeechPartialResults = useCallback((e: SpeechResultsEvent) => {
    const results = e.value || [];
    const text = results[0] || '';
    if (!text) return;

    lastSpeechTimeRef.current = Date.now();

    // Show raw partial transcript on screen
    setDebugRawTranscript(text);
    setDebugStatus(`Hearing: "${text.substring(0, 50)}"`);
    console.log(`🎤 [WakeWord] PARTIAL: "${text}"`);

    if (!wakeWordDetectedRef.current) {
      // Check if partial results contain the wake phrase + query
      const query = stripWakePhrase(text);
      if (query !== null && query.length >= MIN_QUERY_LENGTH) {
        console.log('🎤 [WakeWord] Wake phrase in partial! Query:', `"${query}"`);
        wakeWordDetectedRef.current = true;
        hasSubmittedRef.current = false;
        queryTextRef.current = query;
        setIsCapturingQuery(true);
        setIsAwaitingWakeWord(false);
        setQueryTranscript(query);
        onWakeWordHeardRef.current?.();
        startSilenceTimer();
      } else if (text.length >= MAX_NO_MATCH_TRANSCRIPT_LEN) {
        // ── Anti-bloat: same runaway-transcript guard for partials ───────
        // If we keep seeing huge partials with no match, force a clean
        // restart. Without this, FINAL might never fire and partials grow
        // unbounded.
        console.log(
          `🔄 [WakeWord] Partial transcript too long (${text.length} chars) without match — force-restarting`
        );
        setDebugStatus('Resetting recogniser…');
        Voice.cancel().catch(() => {});
        isActiveRef.current = false;
      }
    } else {
      // Update query text from partial
      const query = stripWakePhrase(text);
      if (query !== null && query.length > 0) {
        queryTextRef.current = query;
        setQueryTranscript(query);
        if (!hasSubmittedRef.current) {
          startSilenceTimer();
        }
      }
    }
  }, [startSilenceTimer]);

  const handleSpeechEnd = useCallback((_e: SpeechEndEvent) => {
    console.log('🎤 [WakeWord] onSpeechEnd (iOS timeout or natural end)');
    setDebugStatus('Speech ended, restarting...');
    isActiveRef.current = false;

    if (wakeWordDetectedRef.current && !hasSubmittedRef.current) {
      // We were capturing a query — validate and submit
      const query = queryTextRef.current.trim();
      if (query.length >= MIN_QUERY_LENGTH) {
        validateWithOpenAIVAD('onSpeechEnd').catch(e =>
          console.warn('⚠️ [WakeWord] SpeechEnd VAD failed:', e?.message)
        );
      } else {
        // Query too short — reset and restart
        console.log('⚠️ [WakeWord] Query too short on speech end, restarting');
        wakeWordDetectedRef.current = false;
        queryTextRef.current = '';
        setIsCapturingQuery(false);
        setQueryTranscript('');
      }
    }

    // Auto-restart for continuous listening (iOS kills recognition ~60s)
    if (enabledRef.current && !isPausedRef.current && !hasSubmittedRef.current) {
      setTimeout(() => {
        if (enabledRef.current && !isPausedRef.current) {
          startRecognition();
        }
      }, RESTART_DELAY_MS);
    }
  }, [startRecognition, validateWithOpenAIVAD]);

  const handleSpeechError = useCallback((e: SpeechErrorEvent) => {
    const errMsg = e.error?.message || String(e.error || 'unknown');
    setDebugStatus(`⚠️ Error: ${errMsg}`);
    console.warn('❌ [WakeWord] Speech error:', errMsg);
    isActiveRef.current = false;

    // Auto-restart unless paused/disabled
    if (enabledRef.current && !isPausedRef.current) {
      setTimeout(() => {
        if (enabledRef.current && !isPausedRef.current) {
          startRecognition();
        }
      }, RESTART_DELAY_MS);
    }
  }, [startRecognition]);

  // ── Register Voice listeners & keep handler refs in sync ────────────────

  useEffect(() => {
    // Keep refs in sync so startRecognition() always re-registers latest handlers
    handleSpeechStartRef.current = handleSpeechStart;
    handleSpeechEndRef.current = handleSpeechEnd;
    handleSpeechResultsRef.current = handleSpeechResults;
    handleSpeechPartialResultsRef.current = handleSpeechPartialResults;
    handleSpeechErrorRef.current = handleSpeechError;

    if (!enabled) return;

    // Set listeners on the Voice singleton
    Voice.onSpeechStart = handleSpeechStart;
    Voice.onSpeechEnd = handleSpeechEnd;
    Voice.onSpeechResults = handleSpeechResults;
    Voice.onSpeechPartialResults = handleSpeechPartialResults;
    Voice.onSpeechError = handleSpeechError;

    return () => {
      clearSilenceTimer();
      // Don't call Voice.destroy() here — startRecognition manages the lifecycle.
      // Calling destroy in effect cleanup causes a race where React re-runs
      // effects and destroys our active recognition session.
    };
  }, [
    enabled,
    handleSpeechStart,
    handleSpeechEnd,
    handleSpeechResults,
    handleSpeechPartialResults,
    handleSpeechError,
    clearSilenceTimer,
  ]);

  // ── Auto-start / auto-stop based on enabled prop ───────────────────────

  useEffect(() => {
    if (enabled && !isPausedRef.current) {
      // Reset state for fresh start
      wakeWordDetectedRef.current = false;
      queryTextRef.current = '';
      hasSubmittedRef.current = false;
      setIsCapturingQuery(false);
      setQueryTranscript('');
      startRecognition();
    } else if (!enabled) {
      isPausedRef.current = false;
      Voice.cancel().catch(() => {});
      Voice.destroy().catch(() => {});
      isActiveRef.current = false;
      setIsAwaitingWakeWord(false);
      setIsCapturingQuery(false);
      setQueryTranscript('');
      clearSilenceTimer();
    }
  }, [enabled, startRecognition, clearSilenceTimer]);

  // ── Public API ─────────────────────────────────────────────────────────

  const pause = useCallback(async () => {
    console.log('⏸️ [WakeWord] Pausing');
    isPausedRef.current = true;
    clearSilenceTimer();
    openAIVadSeqRef.current++;

    try { await Voice.cancel(); } catch { /* ignore */ }
    isActiveRef.current = false;
    setIsAwaitingWakeWord(false);
    // Don't clear isCapturingQuery/queryTranscript — we may resume
  }, [clearSilenceTimer]);

  const resume = useCallback(async () => {
    console.log('▶️ [WakeWord] Resuming');
    isPausedRef.current = false;

    // Reset for next wake word
    wakeWordDetectedRef.current = false;
    queryTextRef.current = '';
    hasSubmittedRef.current = false;
    setIsCapturingQuery(false);
    setQueryTranscript('');

    if (enabledRef.current) {
      // Small delay to let TTS audio session fully release
      await new Promise(r => setTimeout(r, 500));

      // Re-assert the selected recording session before restarting Voice.
      // TTS playback switches the session back to Playback mode.
      await configureBluetoothRecordingSession(microphoneSourceRef.current);
      await new Promise(r => setTimeout(r, 200));

      await startRecognition();
    }
  }, [startRecognition]);

  const stop = useCallback(async () => {
    console.log('🛑 [WakeWord] Stopping');
    isPausedRef.current = true;
    clearSilenceTimer();
    openAIVadSeqRef.current++;

    try { await Voice.cancel(); } catch { /* ignore */ }
    try { await Voice.destroy(); } catch { /* ignore */ }
    isActiveRef.current = false;

    wakeWordDetectedRef.current = false;
    queryTextRef.current = '';
    hasSubmittedRef.current = false;
    setIsAwaitingWakeWord(false);
    setIsCapturingQuery(false);
    setQueryTranscript('');
  }, [clearSilenceTimer]);

  return {
    isAwaitingWakeWord,
    isCapturingQuery,
    queryTranscript,
    debugStatus,
    debugRawTranscript,
    pause,
    resume,
    stop,
  };
};
