/**
 * src/services/useContinuousMode.ts
 *
 * ARCHITECTURE: Fire-and-forget capture loop, decoupled TTS queue
 *
 * BEFORE (broken — sequential blocking):
 *   while(navigating) {
 *     await capture()
 *     await backend()     ← 5–7 s
 *     await speakTTS()    ← 3–7 s  ← THIS blocked the next backend call
 *     await cooldown()
 *   }
 *   → backend called every ~11 s (matches 7–10 s log gaps)
 *
 * AFTER v2 (setTimeout chain — eliminates wasted interval gap):
 *
 *   Problem with v1 (setInterval):
 *     setInterval fires at fixed T=0, 2, 4, 6… regardless of when response arrives.
 *     Response arrives at T=4.5s → isProcessingFrame clears → next tick T=6s.
 *     Up to 2s wasted every cycle. Actual gap = RTT + up to 2s = 6-8s.
 *
 *   Fix (setTimeout chain):
 *     capture → POST → response arrives → setTimeout(MIN_DELAY) → capture
 *     Next call fires MIN_DELAY ms after response, not at the next fixed tick.
 *     Actual gap = RTT + MIN_DELAY (no wasted interval).
 *
 *   ttsQueue (independent, plays responses as they arrive):
 *     plays one response at a time — never blocks the capture chain
 *
 *   → backend called every RTT + 300ms ≈ 4-5s (vs 6-8s before)
 */

import { useState, useRef, useCallback, useEffect } from 'react';
import { AccessibilityInfo } from 'react-native';
import { sendToWorkflow } from '../services/WorkflowService';
import { speachesSentenceChunker } from '../services/SpeachesSentenceChunker';
import { audioFeedback } from '../services/AudioFeedbackService';
import { useDeviceOrientation } from '../hooks/useDeviceOrientation';

// ============================================================================
// Configuration
// ============================================================================

const NAV_CONFIG = {
  /**
   * Minimum delay (ms) after a response arrives before the next capture fires.
   *
   * This is NOT a poll interval. The next call fires MIN_DELAY_AFTER_RESPONSE ms
   * after the previous response returns — not on a fixed wall-clock tick.
   * Eliminates the up-to-2s "missed tick" waste that setInterval caused.
   *
   * Gap = client RTT (upload + n8n + download) + MIN_DELAY_AFTER_RESPONSE
   * At ~4s RTT this gives ~4.3s between n8n calls (vs ~7-8s before).
   */
  MIN_DELAY_AFTER_RESPONSE: 300,

  /** Maximum retries before pausing navigation */
  MAX_CONSECUTIVE_ERRORS: 3,

  /** Delay before retry after hitting max errors (ms) */
  ERROR_RETRY_DELAY: 3000,

  /** Request timeout (ms) */
  REQUEST_TIMEOUT: 15000,

  DEBUG: __DEV__ || true,
};

// ============================================================================
// Types
// ============================================================================

interface ContinuousNavigationOptions {
  cameraRef: React.RefObject<any>;
  sessionId?: string;
  onInstructionAnnounced?: (text: string) => void;
  onStateChange?: (state: NavigationCycleState) => void;
  onError?: (error: Error) => void;
}

type NavigationCycleState =
  | 'idle'
  | 'capturing'
  | 'processing'
  | 'speaking'
  | 'cooldown';

interface NavigationStats {
  cyclesCompleted: number;
  totalRequestTime: number;
  avgRequestTime: number;
  errorsEncountered: number;
  photosCaputred: number;
}

// ============================================================================
// Hook Implementation
// ============================================================================

export const useContinuousNavigation = (options: ContinuousNavigationOptions) => {
  const { cameraRef, onInstructionAnnounced, onStateChange, onError } = options;

  // ---- State ----
  const [isNavigating, setIsNavigating] = useState(false);
  const [cycleState, setCycleState] = useState<NavigationCycleState>('idle');
  const [lastInstruction, setLastInstruction] = useState('');
  const [stats, setStats] = useState<NavigationStats>({
    cyclesCompleted: 0,
    totalRequestTime: 0,
    avgRequestTime: 0,
    errorsEncountered: 0,
    photosCaputred: 0,
  });

  const { isStraightRef } = useDeviceOrientation();

  // ---- Refs ----
  const isNavigatingRef = useRef(false);
  const lastOrientationWarningTimeRef = useRef(0);

  /**
   * isProcessingFrameRef — mirrors the same flag in Swift reaching acquisition.
   * Prevents concurrent backend calls. Set true before POST, false when response
   * returns (or on error). The poll loop checks this before firing.
   */
  const isProcessingFrameRef = useRef(false);

  const abortControllerRef = useRef<AbortController | null>(null);
  const consecutiveErrorsRef = useRef(0);
  // setTimeout handle for the self-chaining capture loop (replaces setInterval)
  const nextCaptureTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  /**
   * ttsQueueRef — responses waiting to be spoken.
   * The TTS drain loop reads from this queue independently of capture.
   */
  const ttsQueueRef = useRef<string[]>([]);
  const isSpeakingRef = useRef(false);

  const statsRef = useRef<NavigationStats>({
    cyclesCompleted: 0,
    totalRequestTime: 0,
    avgRequestTime: 0,
    errorsEncountered: 0,
    photosCaputred: 0,
  });

  // ---- Helpers ----
  const log = useCallback((msg: string) => {
    if (NAV_CONFIG.DEBUG) console.log(`🧭 [NavLoop] ${msg}`);
  }, []);

  const updateCycleState = useCallback(
    (state: NavigationCycleState) => {
      setCycleState(state);
      onStateChange?.(state);
    },
    [onStateChange],
  );

  // ============================================================================
  // TTS DRAIN LOOP
  // Runs independently. Plays queued responses one at a time.
  // Never blocks the capture loop.
  // ============================================================================
  const drainTTSQueue = useCallback(async () => {
    if (isSpeakingRef.current) return; // already draining
    isSpeakingRef.current = true;

    while (isNavigatingRef.current && ttsQueueRef.current.length > 0) {
      // Always take the LATEST response — discard stale ones if queue piled up
      const text = ttsQueueRef.current.pop()!;
      ttsQueueRef.current = []; // discard any others that queued while we were processing

      log(`🔊 Speaking: "${text.substring(0, 60)}…"`);
      updateCycleState('speaking');
      setLastInstruction(text);
      onInstructionAnnounced?.(text);

      audioFeedback.playEarcon('speaking');

      try {
        await speachesSentenceChunker.synthesizeSpeechChunked(text);
      } catch (e: any) {
        if (!e.message?.includes('cancel') && !e.message?.includes('stop')) {
          log(`⚠️ TTS error (non-fatal): ${e.message}`);
        }
      }

      log('🔊 TTS done');
    }

    isSpeakingRef.current = false;

    // Return to 'processing' state indicator so UI reflects capture loop state
    if (isNavigatingRef.current) {
      updateCycleState('processing');
    }
  }, [log, updateCycleState, onInstructionAnnounced]);

  // ============================================================================
  // SINGLE CAPTURE + SEND  (self-chaining via setTimeout in finally)
  //
  // Pattern:
  //   captureAndSend() runs once, completes (success or error), then schedules
  //   itself again via setTimeout(captureAndSend, MIN_DELAY_AFTER_RESPONSE).
  //   This means the next call fires exactly MIN_DELAY ms after the response
  //   arrives — NOT on a fixed wall-clock tick the way setInterval would.
  // ============================================================================
  const captureAndSend = useCallback(async () => {
    if (!isNavigatingRef.current) return;
    if (isProcessingFrameRef.current) {
      log('⏭️ Frame skipped — previous request still in-flight');
      return;
    }

    if (!isStraightRef.current) {
      log('⚠️ Phone orientation incorrect. Skipping capture cycle.');
      
      const now = Date.now();
      if (now - lastOrientationWarningTimeRef.current > 5000) {
        ttsQueueRef.current.push('Please hold your phone straight up, with the camera facing forward.');
        drainTTSQueue();
        lastOrientationWarningTimeRef.current = now;
      }
      
      if (isNavigatingRef.current) {
        nextCaptureTimeoutRef.current = setTimeout(
          captureAndSend,
          NAV_CONFIG.MIN_DELAY_AFTER_RESPONSE
        );
      }
      return;
    }

    isProcessingFrameRef.current = true;
    updateCycleState('capturing');

    let photoPath: string | null = null;

    // ── Capture ──────────────────────────────────────────────────────────────
    try {
      if (!cameraRef.current) {
        log('⚠️ No camera ref');
        isProcessingFrameRef.current = false;
        return;
      }

      const photo = await cameraRef.current.takePhoto({
        qualityPrioritization: 'speed',
        enableShutterSound: false,
      });
      photoPath = photo.path;
      statsRef.current.photosCaputred++;
      log(`📸 Captured: ${photoPath}`);
    } catch (err) {
      log(`❌ Capture failed: ${err}`);
      isProcessingFrameRef.current = false;
      return;
    }

    if (!isNavigatingRef.current) {
      isProcessingFrameRef.current = false;
      return;
    }

    updateCycleState('processing');

    // ── Backend POST ──────────────────────────────────────────────────────────
    const startTime = Date.now();
    const abort = new AbortController();
    abortControllerRef.current = abort;

    try {
      log('📤 POSTing to backend…');

      const result = await sendToWorkflow(
        { text: 'navigation', imageUri: photoPath, navigation: true },
        abort.signal,
      );

      if (!isNavigatingRef.current) {
        isProcessingFrameRef.current = false;
        return;
      }

      const elapsed = Date.now() - startTime;
      statsRef.current.totalRequestTime += elapsed;
      statsRef.current.cyclesCompleted++;
      statsRef.current.avgRequestTime =
        statsRef.current.totalRequestTime / statsRef.current.cyclesCompleted;

      log(`✅ Response in ${elapsed}ms: "${(result.text || '').substring(0, 60)}…"`);

      consecutiveErrorsRef.current = 0;

      // Push to TTS queue and drain (non-blocking)
      if (result.text?.trim()) {
        ttsQueueRef.current.push(result.text);
        drainTTSQueue(); // fire-and-forget — does not block the next poll
      }
    } catch (err: any) {
      if (
        !isNavigatingRef.current ||
        abort.signal.aborted ||
        err.message?.includes('cancel')
      ) {
        isProcessingFrameRef.current = false;
        return;
      }

      consecutiveErrorsRef.current++;
      statsRef.current.errorsEncountered++;
      log(`❌ Request error: ${err.message}`);
      onError?.(err);

      if (consecutiveErrorsRef.current >= NAV_CONFIG.MAX_CONSECUTIVE_ERRORS) {
        log(`🚨 ${NAV_CONFIG.MAX_CONSECUTIVE_ERRORS} consecutive errors — pausing ${NAV_CONFIG.ERROR_RETRY_DELAY}ms`);
        AccessibilityInfo.announceForAccessibility(
          'Navigation paused due to errors. Retrying shortly.',
        );
        await new Promise(r => setTimeout(r, NAV_CONFIG.ERROR_RETRY_DELAY));
        consecutiveErrorsRef.current = 0;
      }
    } finally {
      // Clear the in-flight flag regardless of outcome.
      isProcessingFrameRef.current = false;

      // ── Self-chain: schedule next capture ──────────────────────────────────
      // Fires MIN_DELAY_AFTER_RESPONSE ms after THIS response returned.
      // Because we schedule here (not from a fixed-tick setInterval), there is
      // no "missed interval" waste — the next call is always exactly MIN_DELAY
      // after we're done, not at the next arbitrary wall-clock boundary.
      if (isNavigatingRef.current) {
        nextCaptureTimeoutRef.current = setTimeout(
          captureAndSend,
          NAV_CONFIG.MIN_DELAY_AFTER_RESPONSE,
        );
      }
    }
  }, [cameraRef, drainTTSQueue, updateCycleState, onError, log]);

  // ============================================================================
  // PUBLIC API: startNavigation
  // Kicks off the first captureAndSend(); the chain is self-perpetuating.
  // ============================================================================
  const startNavigation = useCallback(async () => {
    if (isNavigatingRef.current) {
      log('⚠️ Already navigating');
      return;
    }

    log(`🟢 Starting navigation — min delay after response: ${NAV_CONFIG.MIN_DELAY_AFTER_RESPONSE}ms`);
    isNavigatingRef.current = true;
    isProcessingFrameRef.current = false;
    isSpeakingRef.current = false;
    ttsQueueRef.current = [];
    consecutiveErrorsRef.current = 0;

    statsRef.current = {
      cyclesCompleted: 0,
      totalRequestTime: 0,
      avgRequestTime: 0,
      errorsEncountered: 0,
      photosCaputred: 0,
    };

    setIsNavigating(true);
    updateCycleState('capturing');
    // Brief settle delay (camera/audio)
    await new Promise(r => setTimeout(r, 500));

    AccessibilityInfo.announceForAccessibility(
      'Continuous navigation started. Walk slowly and listen for guidance.',
    );

    // Kick off the first cycle — the finally block schedules subsequent ones
    captureAndSend();
  }, [captureAndSend, updateCycleState, log]);

  // ============================================================================
  // PUBLIC API: stopNavigation
  // ============================================================================
  const stopNavigation = useCallback(async () => {
    log('🔴 Stopping navigation');
    isNavigatingRef.current = false;
    ttsQueueRef.current = [];

    // Cancel any pending next-capture timeout
    if (nextCaptureTimeoutRef.current) {
      clearTimeout(nextCaptureTimeoutRef.current);
      nextCaptureTimeoutRef.current = null;
    }

    abortControllerRef.current?.abort();
    abortControllerRef.current = null;

    try {
      await speachesSentenceChunker.stop();
    } catch (e) {
      log(`⚠️ TTS stop error: ${e}`);
    }

    setIsNavigating(false);
    updateCycleState('idle');
    setStats({ ...statsRef.current });

    AccessibilityInfo.announceForAccessibility('Navigation stopped. CyberSight is ready.');
    audioFeedback.playEarcon('ready');
  }, [updateCycleState, log]);

  // ============================================================================
  // Cleanup on unmount
  // ============================================================================
  useEffect(() => {
    return () => {
      if (nextCaptureTimeoutRef.current) clearTimeout(nextCaptureTimeoutRef.current);
      if (isNavigatingRef.current) {
        isNavigatingRef.current = false;
        abortControllerRef.current?.abort();
      }
    };
  }, []);

  return {
    startNavigation,
    stopNavigation,
    isNavigating,
    cycleState,
    lastInstruction,
    stats,
  };
};

export default useContinuousNavigation;
