/**
 * useContinuousNavigation_v2.ts
 * 
 * OPTIMIZED: Event-Driven "Capture-After-TTS" Navigation Loop
 * 
 * PROBLEM (Old Timer-Driven Approach):
 * 
 *   T=0s    Photo A → backend         (user at position 1)
 *   T=2.5s  Photo B → backend         (user still at position 1)
 *   T=5s    Photo C → backend         (user still at position 1)
 *   T=6s    Response A → TTS starts   (user hears guidance)
 *   T=9s    TTS ends → user MOVES     (user now at position 2)
 *   T=8.5s  Response B → TTS plays    ← STALE! Photo B was from position 1!
 * 
 *   Result: User always gets guidance for where they WERE, not where they ARE.
 *   Photos B, C, D are wasted compute — they're all from the same position.
 * 
 * (Event-Driven Approach):
 * 
 *   T=0s    Photo A → backend         (user at position 1)
 *   T=6s    Response A arrives → TTS  (user hears: "turn left")
 *   T=9s    TTS ends → user has moved → Capture Photo B → backend
 *   T=15s   Response B arrives → TTS  (user hears: "continue straight")
 *   T=18s   TTS ends → user has moved → Capture Photo C → backend
 * 
 *   Result: Every photo reflects user's CURRENT position after acting on guidance.
 *   No wasted backend calls. No stale responses.
 * 
 */

import { useState, useRef, useCallback, useEffect } from 'react';
import { AccessibilityInfo, Platform } from 'react-native';
import { sendToWorkflow } from '../services/WorkflowService';
import { speachesSentenceChunker } from '../services/SpeachesSentenceChunker';
import { audioFeedback } from '../services/AudioFeedbackService';

// ============================================================================
// Configuration
// ============================================================================

const NAV_CONFIG = {
  /** Minimum delay between cycles to prevent rapid-fire (ms) */
  MIN_CYCLE_DELAY: 500,

  /** Maximum retries before pausing navigation */
  MAX_CONSECUTIVE_ERRORS: 3,

  /** Delay before retry after error (ms) */
  ERROR_RETRY_DELAY: 3000,

  /** Request timeout (ms) - slightly longer than normal for navigation */
  REQUEST_TIMEOUT: 15000,

  /** Enable pipeline pre-fetch (capture photo ~1s before TTS ends) */
  ENABLE_PREFETCH: false, // Set to true when ready to test

  /** How early to pre-capture before TTS ends (ms) */
  PREFETCH_LEAD_TIME: 1000,

  /** Debug logging */
  DEBUG: __DEV__ || true,
};

// ============================================================================
// Types
// ============================================================================

interface ContinuousNavigationOptions {
  /** Camera ref for capturing photos */
  cameraRef: React.RefObject<any>;

  /** Session ID for backend continuity */
  sessionId?: string;

  /** Called when navigation instruction is announced */
  onInstructionAnnounced?: (text: string) => void;

  /** Called when navigation state changes */
  onStateChange?: (state: NavigationCycleState) => void;

  /** Called on error */
  onError?: (error: Error) => void;
}

type NavigationCycleState =
  | 'idle'           // Not navigating
  | 'capturing'      // Taking photo
  | 'processing'     // Waiting for backend
  | 'speaking'       // TTS playing
  | 'cooldown';      // Brief pause before next cycle

interface NavigationStats {
  cyclesCompleted: number;
  totalRequestTime: number;
  totalSpeakTime: number;
  avgCycleTime: number;
  errorsEncountered: number;
  photosCaputred: number;
  wastedCaptures: number; // Always 0 with event-driven approach!
}

// ============================================================================
// Hook Implementation
// ============================================================================

export const useContinuousNavigation = (options: ContinuousNavigationOptions) => {
  const {
    cameraRef,
    sessionId,
    onInstructionAnnounced,
    onStateChange,
    onError,
  } = options;

  // ---- State ----
  const [isNavigating, setIsNavigating] = useState(false);
  const [cycleState, setCycleState] = useState<NavigationCycleState>('idle');
  const [lastInstruction, setLastInstruction] = useState('');
  const [stats, setStats] = useState<NavigationStats>({
    cyclesCompleted: 0,
    totalRequestTime: 0,
    totalSpeakTime: 0,
    avgCycleTime: 0,
    errorsEncountered: 0,
    photosCaputred: 0,
    wastedCaptures: 0,
  });

  // ---- Refs (mutable state for async loop) ----
  const isNavigatingRef = useRef(false);
  const abortControllerRef = useRef<AbortController | null>(null);
  const consecutiveErrorsRef = useRef(0);
  const cycleCountRef = useRef(0);
  const statsRef = useRef<NavigationStats>({
    cyclesCompleted: 0,
    totalRequestTime: 0,
    totalSpeakTime: 0,
    avgCycleTime: 0,
    errorsEncountered: 0,
    photosCaputred: 0,
    wastedCaptures: 0,
  });

  // ---- Helpers ----
  const log = useCallback((msg: string) => {
    if (NAV_CONFIG.DEBUG) {
      console.log(`🧭 [NavLoop] ${msg}`);
    }
  }, []);

  const updateCycleState = useCallback((state: NavigationCycleState) => {
    setCycleState(state);
    onStateChange?.(state);
  }, [onStateChange]);

  // ============================================================================
  // STEP 1: Capture Photo
  // ============================================================================
  const capturePhoto = useCallback(async (): Promise<string | null> => {
    try {
      if (!cameraRef.current) {
        log('⚠️ No camera ref available');
        return null;
      }

      log('📸 Capturing photo...');
      const photo = await cameraRef.current.takePhoto({
        qualityPrioritization: 'speed',
        enableShutterSound: false, // Silent for continuous mode
      });

      statsRef.current.photosCaputred++;
      log(`📸 Photo captured: ${photo.path}`);
      return photo.path;
    } catch (error) {
      log(`❌ Photo capture failed: ${error}`);
      return null;
    }
  }, [cameraRef, log]);

  // ============================================================================
  // STEP 2: Send to Backend
  // ============================================================================
  const sendToBackend = useCallback(async (
    photoPath: string,
    signal: AbortSignal
  ): Promise<string | null> => {
    try {
      log('📤 Sending to backend...');
      const startTime = Date.now();

      const result = await sendToWorkflow(
        {
          text: 'navigation', // Navigation mode command
          imageUri: photoPath,
          // Include session_id for continuity
        },
        signal
      );

      const elapsed = Date.now() - startTime;
      statsRef.current.totalRequestTime += elapsed;
      log(`✅ Backend responded in ${elapsed}ms: "${result.text.substring(0, 60)}..."`);

      return result.text;
    } catch (error: any) {
      if (signal.aborted || error.message?.includes('cancel')) {
        log('🛑 Request cancelled (expected)');
        return null;
      }
      throw error;
    }
  }, [log]);

  // ============================================================================
  // STEP 3: Speak Response (TTS)
  // ============================================================================
  const speakResponse = useCallback(async (text: string): Promise<void> => {
    try {
      log('🔊 Speaking response...');
      const startTime = Date.now();

      // Use sentence chunker for better UX
      await speachesSentenceChunker.synthesizeSpeechChunked(text);

      const elapsed = Date.now() - startTime;
      statsRef.current.totalSpeakTime += elapsed;
      log(`🔊 TTS finished in ${elapsed}ms`);
    } catch (error: any) {
      if (error.message?.includes('cancel') || error.message?.includes('stop')) {
        log('🛑 TTS cancelled (expected)');
        return;
      }
      throw error;
    }
  }, [log]);

  // ============================================================================
  // CORE: Single Navigation Cycle
  // ============================================================================
  /**
   * Executes one complete navigation cycle:
   *   capture → backend → TTS → done
   * 
   * Returns true if cycle completed successfully, false if stopped/errored.
   */
  const executeOneCycle = useCallback(async (): Promise<boolean> => {
    if (!isNavigatingRef.current) return false;

    const cycleNum = ++cycleCountRef.current;
    const cycleStartTime = Date.now();
    log(`\n━━━ Cycle #${cycleNum} START ━━━`);

    try {
      // ── PHASE 1: Capture ──────────────────────────────────────────
      updateCycleState('capturing');
      const photoPath = await capturePhoto();

      if (!isNavigatingRef.current) return false; // Check after async

      if (!photoPath) {
        log('⚠️ No photo - skipping cycle');
        return true; // Not a fatal error, try again
      }

      // ── PHASE 2: Backend Request ─────────────────────────────────
      updateCycleState('processing');
      
      const abortController = new AbortController();
      abortControllerRef.current = abortController;

      const responseText = await sendToBackend(photoPath, abortController.signal);

      if (!isNavigatingRef.current) return false; // Check after async

      if (!responseText) {
        log('⚠️ No response text - skipping announcement');
        return true;
      }

      // ── PHASE 3: TTS ─────────────────────────────────────────────
      updateCycleState('speaking');
      setLastInstruction(responseText);
      onInstructionAnnounced?.(responseText);

      audioFeedback.playEarcon('speaking');
      await speakResponse(responseText);

      if (!isNavigatingRef.current) return false; // Check after async

      // ── PHASE 4: Cycle Complete ───────────────────────────────────
      const cycleTime = Date.now() - cycleStartTime;
      statsRef.current.cyclesCompleted++;
      statsRef.current.avgCycleTime = 
        statsRef.current.totalRequestTime / statsRef.current.cyclesCompleted;
      
      consecutiveErrorsRef.current = 0; // Reset error counter on success
      
      log(`━━━ Cycle #${cycleNum} DONE (${(cycleTime / 1000).toFixed(1)}s) ━━━\n`);
      return true;

    } catch (error: any) {
      if (!isNavigatingRef.current) return false;

      consecutiveErrorsRef.current++;
      statsRef.current.errorsEncountered++;
      
      log(`❌ Cycle #${cycleNum} ERROR: ${error.message}`);
      onError?.(error);

      // Too many errors? Pause and notify user
      if (consecutiveErrorsRef.current >= NAV_CONFIG.MAX_CONSECUTIVE_ERRORS) {
        log(`🚨 ${NAV_CONFIG.MAX_CONSECUTIVE_ERRORS} consecutive errors - pausing`);
        AccessibilityInfo.announceForAccessibility(
          'Navigation paused due to errors. Retrying shortly.'
        );
        await new Promise(r => setTimeout(r, NAV_CONFIG.ERROR_RETRY_DELAY));
        consecutiveErrorsRef.current = 0; // Reset and try again
      }

      return true; // Continue loop (don't stop on error)
    }
  }, [
    capturePhoto, sendToBackend, speakResponse,
    updateCycleState, onInstructionAnnounced, onError, log
  ]);

  // ============================================================================
  // MAIN LOOP: Event-Driven Navigation
  // ============================================================================
  /**
   * The main navigation loop. Unlike the old timer-based approach,
   * this is EVENT-DRIVEN:
   * 
   *   while(navigating) {
   *     await capturePhoto()   // FRESH photo at current position
   *     await sendToBackend()  // Wait for response
   *     await playTTS()        // Wait for user to hear it
   *     // User moves based on guidance
   *     // Loop back → capture NEW photo at NEW position
   *   }
   * 
   * No setInterval. No stale photos. No wasted compute.
   */
  const navigationLoop = useCallback(async () => {
    log('🚀 Navigation loop STARTED');

    // Brief initial delay for camera/audio to settle
    await new Promise(r => setTimeout(r, 500));

    AccessibilityInfo.announceForAccessibility(
      'Continuous navigation started. Walk slowly and listen for guidance.'
    );

    while (isNavigatingRef.current) {
      const success = await executeOneCycle();

      if (!isNavigatingRef.current) break;

      // Brief cooldown between cycles
      updateCycleState('cooldown');
      log(`⏳ Cooldown ${NAV_CONFIG.MIN_CYCLE_DELAY}ms before next cycle...`);
      await new Promise(r => setTimeout(r, NAV_CONFIG.MIN_CYCLE_DELAY));
    }

    log('🛑 Navigation loop ENDED');
    updateCycleState('idle');
  }, [executeOneCycle, updateCycleState, log]);

  // ============================================================================
  // Public API: Start / Stop
  // ============================================================================

  const startNavigation = useCallback(async () => {
    if (isNavigatingRef.current) {
      log('⚠️ Already navigating');
      return;
    }

    log('🟢 Starting continuous navigation');
    isNavigatingRef.current = true;
    setIsNavigating(true);
    consecutiveErrorsRef.current = 0;
    cycleCountRef.current = 0;
    statsRef.current = {
      cyclesCompleted: 0,
      totalRequestTime: 0,
      totalSpeakTime: 0,
      avgCycleTime: 0,
      errorsEncountered: 0,
      photosCaputred: 0,
      wastedCaptures: 0,
    };

    audioFeedback.playEarcon('listening');

    // Start the loop (fire and forget - it manages itself)
    navigationLoop().catch(err => {
      log(`❌ Navigation loop crashed: ${err}`);
      stopNavigation();
    });
  }, [navigationLoop, log]);

  const stopNavigation = useCallback(async () => {
    log('🔴 Stopping continuous navigation');
    isNavigatingRef.current = false;
    setIsNavigating(false);
    updateCycleState('idle');

    // Cancel any in-flight request
    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
      abortControllerRef.current = null;
    }

    // Stop TTS if playing
    try {
      await speachesSentenceChunker.stop();
    } catch (e) {
      log(`⚠️ Error stopping TTS: ${e}`);
    }

    // Update stats snapshot
    setStats({ ...statsRef.current });

    AccessibilityInfo.announceForAccessibility(
      'Navigation stopped. CyberSight is ready.'
    );
    audioFeedback.playEarcon('ready');
  }, [updateCycleState, log]);

  // ============================================================================
  // Cleanup on unmount
  // ============================================================================
  useEffect(() => {
    return () => {
      if (isNavigatingRef.current) {
        isNavigatingRef.current = false;
        abortControllerRef.current?.abort();
      }
    };
  }, []);

  // ============================================================================
  // Return
  // ============================================================================
  return {
    // Controls
    startNavigation,
    stopNavigation,

    // State
    isNavigating,
    cycleState,
    lastInstruction,

    // Debug
    stats,
  };
};

export default useContinuousNavigation;