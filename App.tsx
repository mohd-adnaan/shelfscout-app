/**
 * App.tsx - CyberSight Mobile Application
 * 
 */

import React, { useState, useEffect, useRef, useCallback } from 'react';
import {
  StyleSheet,
  View,
  TouchableWithoutFeedback,
  Platform,
  PermissionsAndroid,
  Alert,
  Animated,
  Dimensions,
  StatusBar,
  AccessibilityInfo,
  NativeModules,
} from 'react-native';
import { Camera, useCameraDevice, useCameraPermission, useMicrophonePermission } from 'react-native-vision-camera';
import { useTTS } from './src/hooks/useTTS';
import { useSTT } from './src/hooks/useSTT_Enhanced';
import {
  sendToWorkflow,
  isContinuousModeActive,
  getCurrentMode,
  startContinuousMode,
  stopContinuousMode,
  incrementContinuousMode,
  getCurrentLoopDelay,
  shouldPreventInfiniteLoop,
  updateLoopDelay,
  getSessionId,
  resetSessionId,
  determineActionMode,
} from './src/services/WorkflowService';
import { VoiceVisualizer } from './src/components/VoiceVisualizer';
import { playSound } from './src/utils/soundEffects';
import { audioFeedback } from './src/services/AudioFeedbackService';
import { speachesSentenceChunker } from './src/services/SpeachesSentenceChunker';
import { NAVIGATION_CONFIG } from './src/utils/constants';
import { fixImageOrientation } from './src/services/fixImageOrientation';
import { useContinuousNavigation } from './src/services/useContinuousMode';


const { width, height } = Dimensions.get('window');

// =============================================================================
// TIMING CONSTANTS
// =============================================================================
const CAMERA_REACTIVATION_DELAY_MS = 800;  // Wait for camera to fully initialize
const AUDIO_SESSION_RELEASE_DELAY_MS = 300; // Wait for audio session to release
const TTS_COMPLETION_BUFFER_MS = 500; // Buffer after TTS before next loop iteration

// =============================================================================
// ★★★ NEW: PIPELINE PRE-FETCH CONFIGURATION ★★★
// =============================================================================
const PREFETCH_CONFIG = {
  /** Enable pipeline pre-fetch (capture photo during TTS) */
  ENABLED: true,

  /** 
   * Minimum TTS play time before attempting pre-fetch (ms)
   * Don't try to pre-fetch if TTS is very short 
   */
  MIN_TTS_TIME_BEFORE_PREFETCH: 3000,

  /** 
   * TTS progress percentage at which to trigger pre-fetch (0-100)
   * 75% means: when 3 of 4 chunks are done, capture next photo
   */
  PREFETCH_TRIGGER_PERCENT: 75,

  /**
   * Poll interval for checking TTS progress (ms)
   */
  PROGRESS_POLL_INTERVAL: 500,

  /**
   * Minimum cooldown between cycles (ms)
   * Even with pre-fetch, give a brief pause
   */
  MIN_CYCLE_COOLDOWN: 300,
};
function App(): React.JSX.Element {
  // ============================================================================
  // State Management
  // ============================================================================
  const [isProcessing, setIsProcessing] = useState(false);
  const [isSpeaking, setIsSpeaking] = useState(false);
  const [isNavigation, setIsNavigation] = useState(false);
  const [isReaching, setIsReaching] = useState(false);
  const [screenReaderEnabled, setScreenReaderEnabled] = useState(false);
  const [reduceMotionEnabled, setReduceMotionEnabled] = useState(false);
  const isContinuousModeRunning = useRef(false);
  const continuousModeAbortRef = useRef(false);

  const [isCameraActive, setIsCameraActive] = useState(true);

  // ============================================================================
  // Camera & Permissions
  // ============================================================================
  const device = useCameraDevice('back');
  const { hasPermission: hasCameraPermission, requestPermission: requestCameraPermission } = useCameraPermission();
  const { hasPermission: hasMicPermission, requestPermission: requestMicPermission } = useMicrophonePermission();

  const cameraRef = useRef<Camera>(null);
  const containerRef = useRef<View>(null);

  // ============================================================================
  // Audio/Speech Services
  // ============================================================================
  const { speak, stop: stopTTS } = useTTS();

  // ============================================================================
  // Internal State Management (Refs for synchronous access)
  // ============================================================================
  const isEmergencyStopped = useRef(false);
  const isProcessingRef = useRef(false);
  const finalTranscriptRef = useRef('');
  const abortControllerRef = useRef<AbortController | null>(null);
  const isCapturingPhotoRef = useRef(false);
  const isNavigationLoopRunning = useRef(false); // Track if loop is actively running
  const navigationLoopAbortRef = useRef(false); // Signal to stop navigation loop
  const lastImageDimensions = useRef<{ width: number; height: number }>({ width: 0, height: 0 });
  const prefetchedPhotoRef = useRef<string | null>(null);
  // ============================================================================
  // Animation
  // ============================================================================
  const pulseAnim = useRef(new Animated.Value(1)).current;
  const opacityAnim = useRef(new Animated.Value(0.3)).current;

  useEffect(() => {
    const { ReachingModule } = NativeModules;
    console.log('🔍 NativeModules keys:', Object.keys(NativeModules));
    console.log('🔍 ReachingModule:', ReachingModule);
    console.log('🔍 ReachingModule.startReaching:', ReachingModule?.startReaching);
  }, []);

  // ============================================================================
  // Log session info on mount
  // ============================================================================
  useEffect(() => {
    console.log('🚀 CyberSight App Started');
    console.log('🆔 Session ID:', getSessionId());
    console.log('🔄 Navigation loop enabled:', NAVIGATION_CONFIG.ENABLE_NAVIGATION_LOOP);
  }, []);

  // ============================================================================
  // Pre-warm TTS Service on App Launch (Fix first-tap delay)
  // ============================================================================
  useEffect(() => {
    const prewarmTTS = async () => {
      try {
        console.log('Pre-warming TTS service...');
        // Use the actual TTS service that's already imported
        await speachesSentenceChunker.synthesizeSpeechChunked('');
        console.log('TTS service pre-warmed and ready');
      } catch (error) {
        console.warn('⚠️ TTS pre-warm failed (non-critical):', error);
        // Non-critical - will initialize on first real use
      }
    };

    // Pre-warm after 1 second delay (let app fully load first)
    const timer = setTimeout(prewarmTTS, 1000);
    return () => clearTimeout(timer);
  }, []);

  // ============================================================================
  // Reactivate Camera and Capture Photo
  // ============================================================================
  const reactivateCameraAndCapture = async (): Promise<string> => {
    console.log('📷 Reactivating camera for capture...');

    console.log('📷 Camera ref exists:', !!cameraRef.current);
    console.log('📷 Camera active state:', isCameraActive);

    // Step 1: Make sure camera is active
    setIsCameraActive(true);

    // Step 2: Wait for camera to fully initialize
    console.log(`⏳ Waiting ${CAMERA_REACTIVATION_DELAY_MS}ms for camera to initialize...`);
    await new Promise(resolve => setTimeout(resolve, CAMERA_REACTIVATION_DELAY_MS));

    // Step 3: Check if camera ref is available
    if (!cameraRef.current) {
      console.error('❌ Camera ref not available after reactivation');
      return '';
    }

    // Step 4: Take photo
    try {
      console.log('📸 Taking photo...');
      const photo = await cameraRef.current.takePhoto({
        qualityPrioritization: 'speed',
        enableShutterSound: true,
        flash: 'off',
      });

      const fixedImage = await fixImageOrientation(photo.path);

      // Store dimensions for ReachingModule bbox normalization
      lastImageDimensions.current = {
        width: fixedImage.width || 0,
        height: fixedImage.height || 0
      };
      console.log('✅ Photo captured & orientation fixed:', fixedImage.uri,
        `(${fixedImage.width}×${fixedImage.height})`);
      return fixedImage.uri;
    } catch (error) {
      console.error('❌ Photo capture failed:', error);

      // Retry once with longer delay
      console.log('🔄 Retrying with longer delay...');
      await new Promise(resolve => setTimeout(resolve, 500));

      try {
        const retryPhoto = await cameraRef.current.takePhoto({
          qualityPrioritization: 'speed',
          enableShutterSound: false,
        });
        console.log('✅ Photo captured on retry:', retryPhoto.path);
        return retryPhoto.path;
      } catch (retryError) {
        console.error('❌ Retry also failed:', retryError);
        return '';
      }
    }
  };

  // ============================================================================
  // NAVIGATION LOOP IMPLEMENTATION
  // ============================================================================

  /**
   * Run the navigation loop
   * 
   * capture → send → speak(+prefetch) → cooldown → [use prefetched OR capture] → send → speak    
   */
  const runContinuousLoop = useCallback(async () => {
    if (!NAVIGATION_CONFIG.ENABLE_NAVIGATION_LOOP) {
      console.log('🔄 [ContinuousMode] Disabled in config');
      return;
    }

    if (isContinuousModeRunning.current) {
      console.log('🔄 [ContinuousMode] Loop already running');
      return;
    }

    console.log('🔄 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('🔄 [ContinuousMode] Starting EVENT-DRIVEN loop');
    console.log('🔄 [ContinuousMode] Pre-fetch:', PREFETCH_CONFIG.ENABLED ? 'ON' : 'OFF');
    console.log('🔄 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

    isContinuousModeRunning.current = true;
    continuousModeAbortRef.current = false;
    prefetchedPhotoRef.current = null;
    let cycleCount = 0;

    const currentMode = getCurrentMode();
    AccessibilityInfo.announceForAccessibility(`${currentMode} started. Tap to stop.`);

    while (!continuousModeAbortRef.current && !isEmergencyStopped.current) {
      // Safety check
      if (shouldPreventInfiniteLoop()) {
        console.log('🔄 [ContinuousMode] Stopping due to safety limits');
        AccessibilityInfo.announceForAccessibility('Stopped due to time limit.');
        break;
      }

      cycleCount++;
      const cycleStart = Date.now();
      console.log(`\n🔄 ═══ CYCLE #${cycleCount} START ═══`);

      try {
        incrementContinuousMode();

        // ================================================================
        // STEP 1: CAPTURE PHOTO (or use pre-fetched)
        // ================================================================
        // ★ KEY CHANGE: No delay before capture! Photo is taken NOW,
        // at user's CURRENT position (after they moved from last guidance)
        // ================================================================
        let photoPath = '';

        if (prefetchedPhotoRef.current) {
          // ★ Use pre-fetched photo from previous TTS cycle
          photoPath = prefetchedPhotoRef.current;
          prefetchedPhotoRef.current = null;
          console.log('🔄 [Cycle] ✅ Using PRE-FETCHED photo (saved ~800ms)');
        } else {
          // Fresh capture (first cycle, or pre-fetch was disabled/failed)
          console.log('🔄 [Cycle] 📸 Capturing FRESH photo at current position...');
          photoPath = await reactivateCameraAndCapture();
        }

        if (!photoPath) {
          console.warn('🔄 [Cycle] ⚠️ No photo, continuing voice-only');
        }

        if (continuousModeAbortRef.current || isEmergencyStopped.current) {
          console.log('🔄 [Cycle] Aborted after capture');
          break;
        }

        // ================================================================
        // STEP 2: SEND TO BACKEND (wait for response)
        // ================================================================
        // ★ KEY CHANGE: We WAIT for this response. No new photos during wait.
        // The photo we just sent IS the user's current view.
        // ================================================================
        console.log('🔄 [Cycle] 📤 Sending to backend...');
        const backendStart = Date.now();
        setIsProcessing(true);

        const abortController = new AbortController();
        abortControllerRef.current = abortController;

        const currentMode = getCurrentMode();
        const result = await sendToWorkflow(
          {
            text: '',
            imageUri: photoPath || '',
            navigation: currentMode === 'navigation',
            reaching_flag: currentMode === 'reaching'
          },
          abortController.signal
        );

        const backendMs = Date.now() - backendStart;
        setIsProcessing(false);

        if (continuousModeAbortRef.current || isEmergencyStopped.current) {
          console.log('🔄 [Cycle] Aborted after backend response');
          break;
        }

        console.log(`🔄 [Cycle] ✅ Backend responded in ${backendMs}ms:`, {
          text: result.text?.substring(0, 50),
          navigation: result.navigation,
          reaching_flag: result.reaching_flag,
          reaching_ios: result.reaching_ios,
          bbox: result.bbox,
          depth: result.depth,
          object: result.object,
          loopDelay: result.loopDelay,
        });

        // Update loop delay if provided
        if (result.loopDelay) {
          updateLoopDelay(result.loopDelay);
        }

        // ======================================================================
        // ★★★ iOS REACHING PRIORITY CHECK ★★★
        // ======================================================================

        if (Platform.OS === 'ios' && result.reaching_ios === true) {
          let bbox: number[] | null = null;

          if (result.bbox) {
            if (Array.isArray(result.bbox)) {
              bbox = result.bbox;
            } else if (typeof result.bbox === 'string') {
              try {
                const s = (result.bbox as string).replace('[', '').replace(']', '');
                bbox = s.split(',').map((v: string) => Number(v.trim()));
              } catch (e) {
                console.warn('Failed to parse bbox');
              }
            }
          }

          if (bbox && bbox.length === 4) {
            console.log('🎯 [iOS Reaching] TAKING OVER - PRIORITY!');
            console.log('📦 [iOS Reaching] bbox:', bbox);
            console.log('🏷️ [iOS Reaching] object:', result.object);

            // 1. Speak the response first
            if (result.text) {
              console.log('🔊 Speaking before reaching handover...');
              setIsSpeaking(true);
              await speachesSentenceChunker.synthesizeSpeechChunked(result.text);
              setIsSpeaking(false);
            }

            // 2. Stop the continuous loop
            console.log('🛑 Stopping continuous loop for iOS reaching takeover');
            isContinuousModeRunning.current = false;
            continuousModeAbortRef.current = true;
            stopContinuousMode('iOS reaching takeover', false);

            // 3. Announce to user
            AccessibilityInfo.announceForAccessibility(
              `Guiding you to ${result.object || 'object'}. Follow the audio beeps.`
            );

            // 4. ★★★ DEACTIVATE RN CAMERA + CALL THE NATIVE MODULE ★★★
            // CRITICAL: RN VisionCamera and native AVCaptureSession conflict
            setIsCameraActive(false);
            await new Promise(resolve => setTimeout(resolve, 500));

            try {
              const { ReachingModule } = NativeModules;

              if (ReachingModule?.startReaching) {
                console.log('🎯 [iOS Reaching] Calling native ReachingModule.startReaching...');

                const reachingResult = await ReachingModule.startReaching({
                  bbox: bbox,
                  object: result.object || 'object',
                  depth: result.depth,
                  imageWidth: lastImageDimensions.current.width,
                  imageHeight: lastImageDimensions.current.height,
                });

                console.log('✅ [iOS Reaching] Native module result:', reachingResult);

                if (reachingResult?.success) {
                  // Success! Object was reached
                  AccessibilityInfo.announceForAccessibility(
                    `${result.object || 'Object'} reached successfully!`
                  );
                } else {
                  // Reaching was cancelled or failed
                  AccessibilityInfo.announceForAccessibility(
                    'Reaching guidance ended.'
                  );
                }
              } else {
                console.warn('⚠️ ReachingModule not available - native module not linked');
                AccessibilityInfo.announceForAccessibility(
                  'Reaching module not available. Please rebuild the app.'
                );
              }
            } catch (reachingError: any) {
              console.error('❌ [iOS Reaching] Native module error:', reachingError);
              AccessibilityInfo.announceForAccessibility(
                `Reaching error: ${reachingError.message || 'Unknown error'}`
              );
            }

            // 5. Reset session and update UI state
            resetSessionId();
            setIsNavigation(false);
            setIsReaching(false);
            setIsProcessing(false);
            setIsCameraActive(true);

            audioFeedback.playEarcon('ready');
            AccessibilityInfo.announceForAccessibility('Ready. Tap to speak.');

            return; // ★★★ EXIT THE LOOP ★★★
          }
          else {
            // reaching_ios=true but no valid bbox in continuous loop
            console.log('⚠️ [iOS Reaching Loop] No valid bbox, falling through to flag check');
            // Let the code fall through to the flag check below
            // which will handle both-flags-false termination
          }
        }

        // ======================================================================
        // END iOS Reaching Priority Check
        // ======================================================================

        // ======================================================================
        // CRITICAL: Check BOTH flags
        // ======================================================================
        const navigationActive = result.navigation === true;
        const reachingActive = result.reaching_flag === true;
        const bothInactive = !navigationActive && !reachingActive;

        console.log('🔄 [ContinuousMode] Flag status:', {
          navigation: navigationActive,
          reaching: reachingActive,
          bothInactive,
        });

        // Update UI state
        setIsNavigation(navigationActive);
        setIsReaching(reachingActive);

        // ======================================================================
        // Check if BOTH flags are false → STOP and RESET SESSION
        // ======================================================================
        if (bothInactive) {
          console.log('🔄 [ContinuousMode] *** BOTH FLAGS FALSE - STOPPING AND RESETTING SESSION ***');

          // Speak final response if any
          if (result.text) {
            setIsSpeaking(true);
            await speachesSentenceChunker.synthesizeSpeechChunked(result.text);
            setIsSpeaking(false);
          }

          AccessibilityInfo.announceForAccessibility('Task complete.');

          // Stop continuous mode WITH session reset
          stopContinuousMode('both flags false', true);  // true = reset session
          break;
        }

        // ======================================================================
        // Handle mode transitions (one flag true, other false)
        // ======================================================================
        if (navigationActive && !reachingActive && currentMode !== 'navigation') {
          console.log('🔄 [ContinuousMode] Switching to navigation mode');
          startContinuousMode('navigation', result.loopDelay);
          AccessibilityInfo.announceForAccessibility('Switching to navigation.');
        } else if (reachingActive && !navigationActive && currentMode !== 'reaching') {
          console.log('🔄 [ContinuousMode] Switching to reaching mode');
          startContinuousMode('reaching', result.loopDelay);
          AccessibilityInfo.announceForAccessibility('Switching to object guidance.');
        }

        if (result.text && !continuousModeAbortRef.current && !isEmergencyStopped.current) {
          console.log('🔄 [Cycle] 🔊 Speaking response...');
          setIsSpeaking(true);

          if (PREFETCH_CONFIG.ENABLED) {
            // ★ PIPELINE MODE: TTS + Pre-fetch run concurrently
            console.log('🔄 [Cycle] 🔮 Pipeline pre-fetch ACTIVE');

            prefetchedPhotoRef.current = null; // Clear any old pre-fetch

            await Promise.all([
              // ── Task A: Play TTS (blocks until all chunks done) ──
              speachesSentenceChunker.synthesizeSpeechChunked(result.text),

              // ── Task B: Pre-fetch photo at ~75% TTS progress ──
              (async () => {
                try {
                  // Wait minimum time before checking progress
                  await new Promise(r => setTimeout(r, PREFETCH_CONFIG.MIN_TTS_TIME_BEFORE_PREFETCH));

                  // Abort if loop was stopped during wait
                  if (continuousModeAbortRef.current || isEmergencyStopped.current) return;

                  // Poll TTS progress until we hit the trigger threshold
                  while (speachesSentenceChunker.isCurrentlyPlaying()) {
                    if (continuousModeAbortRef.current || isEmergencyStopped.current) return;

                    const progress = speachesSentenceChunker.getProgress();

                    if (progress.percentage >= PREFETCH_CONFIG.PREFETCH_TRIGGER_PERCENT) {
                      console.log(`🔮 [Prefetch] TTS at ${progress.percentage}% (${progress.current}/${progress.total}) — capturing next photo!`);

                      const prefetchPath = await reactivateCameraAndCapture();

                      if (prefetchPath) {
                        prefetchedPhotoRef.current = prefetchPath;
                        console.log('🔮 [Prefetch] ✅ Photo pre-fetched and ready for next cycle');
                      } else {
                        console.log('🔮 [Prefetch] ⚠️ Pre-fetch capture failed, will capture fresh next cycle');
                      }
                      return; // Done pre-fetching
                    }

                    // Keep polling
                    await new Promise(r => setTimeout(r, PREFETCH_CONFIG.PROGRESS_POLL_INTERVAL));
                  }

                  // TTS ended before we could pre-fetch (very short response)
                  console.log('🔮 [Prefetch] TTS ended before pre-fetch trigger — will capture fresh');
                } catch (prefetchError) {
                  console.warn('🔮 [Prefetch] Error during pre-fetch (non-fatal):', prefetchError);
                  // Pre-fetch failure is non-fatal — next cycle will just capture fresh
                }
              })(),
            ]);

          } else {
            // ★ NON-PIPELINE MODE: Just play TTS, then capture fresh next cycle
            await speachesSentenceChunker.synthesizeSpeechChunked(result.text);
          }

          setIsSpeaking(false);

          // Brief cooldown after TTS (let audio session settle)
          const cooldown = PREFETCH_CONFIG.ENABLED
            ? PREFETCH_CONFIG.MIN_CYCLE_COOLDOWN
            : TTS_COMPLETION_BUFFER_MS;
          await new Promise(resolve => setTimeout(resolve, cooldown));
        }

        // ================================================================
        // ★ NO DELAY BEFORE NEXT CAPTURE ★
        // ================================================================
        // Old code had: await new Promise(resolve => setTimeout(resolve, delay));
        // This is REMOVED. The next iteration starts immediately with a fresh
        // capture (or uses the pre-fetched photo). The natural pacing comes from:
        //   backend response time (~6s) + TTS time (~3s) + cooldown (~0.3s)
        // which is already ~9.3s per cycle — no artificial delay needed.
        // ================================================================

        const cycleMs = Date.now() - cycleStart;
        console.log(`🔄 ═══ CYCLE #${cycleCount} DONE (${(cycleMs / 1000).toFixed(1)}s) ═══`);
        console.log(`🔄 [Stats] Prefetched photo ready: ${prefetchedPhotoRef.current ? 'YES ✅' : 'NO (will capture fresh)'}`);

      } catch (error: any) {
        console.error('🔄 [ContinuousMode] Error in iteration:', error);

        if (error.message?.includes('cancel')) {
          console.log('🔄 [ContinuousMode] Request was cancelled');
          break;
        }

        AccessibilityInfo.announceForAccessibility(`Error: ${error.message}`);
        break;
      }
    }


    // Cleanup
    console.log('🔄 [ContinuousMode] Loop ended');
    isContinuousModeRunning.current = false;
    stopContinuousMode('loop ended', false);  // false = don't reset session on natural end
    setIsNavigation(false);
    setIsReaching(false);
    setIsProcessing(false);
    setIsSpeaking(false);
    setIsCameraActive(true);

    audioFeedback.playEarcon('ready');
    AccessibilityInfo.announceForAccessibility('Ready. Tap to speak.');

  }, [isNavigation, isReaching]);


  /**
  * NAVIGATION LOOP (legacy — kept for backwards compat, delegates to runContinuousLoop)
  */
  const runNavigationLoop = useCallback(async () => {
    if (!NAVIGATION_CONFIG.ENABLE_NAVIGATION_LOOP) {
      console.log('🔄 [NavLoop] Navigation loop is disabled in config');
      return;
    }

    if (isNavigationLoopRunning.current) {
      console.log('🔄 [NavLoop] Loop already running');
      return;
    }

    console.log('🔄 [NavLoop] Delegating to runContinuousLoop');
    // Delegate to the unified continuous loop
    startContinuousMode('navigation');
    await runContinuousLoop();
  }, [runContinuousLoop]);

  /**
   * Stop the navigation loop
   */
  const stopNavigation = useCallback(async () => {
    console.log('🛑 Stopping navigation loop');
    navigationLoopAbortRef.current = true;

    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
      abortControllerRef.current = null;
    }

    await speachesSentenceChunker.stop();

    stopContinuousMode('user interrupt', false);
    setIsNavigation(false);
    setIsProcessing(false);
    setIsSpeaking(false);
    isNavigationLoopRunning.current = false;

    setIsCameraActive(true);

    audioFeedback.playEarcon('cancel');
    AccessibilityInfo.announceForAccessibility('Navigation stopped. Tap to speak.');
  }, []);


  /**
   * Stop the continuous mode loop (called when user taps during continuous mode)
   */
  const stopContinuousModeLoop = useCallback(async () => {
    console.log('🛑 Stopping continuous mode');
    continuousModeAbortRef.current = true;

    // Cancel any pending request
    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
      abortControllerRef.current = null;
    }

    // Stop TTS
    await speachesSentenceChunker.stop();

    // Update state (DON'T reset session on user interrupt)
    stopContinuousMode('user interrupt', false);  // false = preserve session
    setIsNavigation(false);
    setIsReaching(false);
    setIsProcessing(false);
    setIsSpeaking(false);
    isContinuousModeRunning.current = false;

    // Re-enable camera
    setIsCameraActive(true);

    audioFeedback.playEarcon('cancel');
    AccessibilityInfo.announceForAccessibility('Stopped. Tap to speak.');
  }, []);



  // ============================================================================
  // Auto-Submit Handler (Silence Detection)
  // ============================================================================
  const handleAutoSubmit = useCallback(async () => {
    console.log('🎯 Auto-submit triggered by silence detection');

    if (isCapturingPhotoRef.current) {
      console.log('⚠️ Photo capture already in progress');
      return;
    }

    if (isProcessingRef.current || isEmergencyStopped.current) {
      console.log('⚠️ Already processing or stopped');
      return;
    }

    const finalText = finalTranscriptRef.current.trim();
    if (!finalText) {
      console.log('⚠️ No transcript available');
      AccessibilityInfo.announceForAccessibility('No voice input detected. Tap to try again.');
      audioFeedback.playEarcon('error');
      return;
    }

    console.log('⚡ Processing:', finalText);

    // Only set UI state, NOT the ref
    setIsProcessing(true);
    // isProcessingRef.current = true;  // Let handleVoiceCommand set this!
    isCapturingPhotoRef.current = true;

    audioFeedback.playEarcon('thinking');
    AccessibilityInfo.announceForAccessibility('Processing your request');

    try {
      console.log('🛑 Stopping STT...');
      try {
        await cancelSTT();
        console.log('✅ STT cancelled');
      } catch (e) {
        console.warn('⚠️ STT cancel error (may already be stopped)');
      }

      console.log(`⏳ Waiting ${AUDIO_SESSION_RELEASE_DELAY_MS}ms for audio session to release...`);
      await new Promise(resolve => setTimeout(resolve, AUDIO_SESSION_RELEASE_DELAY_MS));

      console.log('✅ Audio session wait complete');

      if (isEmergencyStopped.current) {
        console.log('⚠️ Emergency stopped during wait');
        setIsProcessing(false);
        // ✅ No need to reset isProcessingRef since we didn't set it
        isCapturingPhotoRef.current = false;
        return;
      }

      console.log('📷 About to call reactivateCameraAndCapture...');

      let photoPath = '';
      try {
        photoPath = await reactivateCameraAndCapture();
        console.log('✅ Camera reactivation complete, photo:', photoPath ? 'captured' : 'failed');
      } catch (cameraError) {
        console.error('❌ Camera reactivation error:', cameraError);
        photoPath = '';
      }

      if (!photoPath) {
        console.warn('⚠️ No photo captured, continuing voice-only');
        AccessibilityInfo.announceForAccessibility(
          'Warning: Failed to capture photo. Continuing with voice command only.'
        );
      }

      if (isEmergencyStopped.current) {
        console.log('⚠️ Emergency stopped after photo');
        setIsProcessing(false);
        isCapturingPhotoRef.current = false;
        return;
      }

      console.log('📤 About to call handleVoiceCommand...');

      // ✅ handleVoiceCommand will set isProcessingRef.current = true itself
      await handleVoiceCommand(finalText, photoPath);

      console.log('✅ handleVoiceCommand complete');

    } catch (error) {
      console.error('❌ Auto-submit error:', error);
      console.error('❌ Error stack:', error.stack);
      AccessibilityInfo.announceForAccessibility(`Error: ${error.message || error}`);
      setIsProcessing(false);
      // ✅ No need to reset isProcessingRef - handleVoiceCommand manages it
    } finally {
      isCapturingPhotoRef.current = false;
      console.log('✅ Auto-submit finally block complete');
    }
  }, [handleVoiceCommand]);

  // ============================================================================
  // STT Hook
  // ============================================================================
  const {
    startListening: startSTT,
    stopListening: stopSTT,
    cancelListening: cancelSTT,
    isListening,
    transcript
  } = useSTT({
    onAutoSubmit: handleAutoSubmit,
    enableAutoSubmit: true,
    silenceThreshold: 1500,
    enableRMSVAD: true,
  });

  // ============================================================================
  // Accessibility Setup
  // ============================================================================
  useEffect(() => {
    const checkAccessibilityPreferences = async () => {
      try {
        const [isScreenReaderOn, isReduceMotionOn] = await Promise.all([
          AccessibilityInfo.isScreenReaderEnabled(),
          AccessibilityInfo.isReduceMotionEnabled(),
        ]);
        setScreenReaderEnabled(isScreenReaderOn);
        setReduceMotionEnabled(isReduceMotionOn);

        if (isScreenReaderOn) {
          setTimeout(() => {
            AccessibilityInfo.announceForAccessibility(
              'CyberSight activated. Tap anywhere to start speaking.'
            );
          }, 1000);
        }
      } catch (error) {
        console.error('❌ Accessibility check error:', error);
      }
    };
    checkAccessibilityPreferences();

    const screenReaderSub = AccessibilityInfo.addEventListener('screenReaderChanged', setScreenReaderEnabled);
    const reduceMotionSub = AccessibilityInfo.addEventListener('reduceMotionChanged', setReduceMotionEnabled);
    return () => {
      screenReaderSub?.remove();
      reduceMotionSub?.remove();
    };
  }, []);

  // ============================================================================
  // Permissions
  // ============================================================================
  useEffect(() => {
    const requestAndroidPermissions = async () => {
      if (Platform.OS === 'android') {
        try {
          const results = await PermissionsAndroid.requestMultiple([
            PermissionsAndroid.PERMISSIONS.RECORD_AUDIO,
            PermissionsAndroid.PERMISSIONS.CAMERA,
          ]);
          const audioGranted = results['android.permission.RECORD_AUDIO'] === 'granted';
          const cameraGranted = results['android.permission.CAMERA'] === 'granted';
          if (!audioGranted || !cameraGranted) {
            Alert.alert('Permissions Required', 'Please enable camera and microphone permissions.');
          }
        } catch (err) {
          console.warn('Permission error:', err);
        }
      }
    };
    requestAndroidPermissions();
  }, []);

  useEffect(() => {
    const requestPermissions = async () => {
      if (!hasCameraPermission) await requestCameraPermission();
      if (!hasMicPermission) await requestMicPermission();
    };
    requestPermissions();
  }, [hasCameraPermission, hasMicPermission]);

  // ============================================================================
  // Sync transcript
  // ============================================================================
  useEffect(() => {
    if (transcript) {
      finalTranscriptRef.current = transcript;
    }
  }, [transcript]);

  // ============================================================================
  // Disable camera when listening starts, enable when stops
  // ============================================================================
  useEffect(() => {
    if (isListening) {
      console.log('📷 Disabling camera (voice recognition active)');
      setIsCameraActive(false);
    }
  }, [isListening]);

  // ============================================================================
  // Animation
  // ============================================================================
  useEffect(() => {
    if ((isListening || isNavigation) && !reduceMotionEnabled) {
      Animated.loop(
        Animated.sequence([
          Animated.parallel([
            Animated.timing(pulseAnim, { toValue: 1.3, duration: 1000, useNativeDriver: true }),
            Animated.timing(opacityAnim, { toValue: 0.8, duration: 1000, useNativeDriver: true }),
          ]),
          Animated.parallel([
            Animated.timing(pulseAnim, { toValue: 1, duration: 1000, useNativeDriver: true }),
            Animated.timing(opacityAnim, { toValue: 0.3, duration: 1000, useNativeDriver: true }),
          ]),
        ])
      ).start();
    } else {
      Animated.parallel([
        Animated.timing(pulseAnim, { toValue: 1, duration: 300, useNativeDriver: true }),
        Animated.timing(opacityAnim, { toValue: 0.3, duration: 300, useNativeDriver: true }),
      ]).start();
    }
  }, [isListening, isNavigation, reduceMotionEnabled]);

  // ============================================================================
  // Helpers
  // ============================================================================
  const getStateDescription = () => {
    if (isNavigation) return 'navigation';
    if (isSpeaking) return 'speaking';
    if (isProcessing) return 'processing';
    if (isListening) return 'listening';
    return 'ready';
  };

  const getAccessibilityLabel = () => {
    if (isNavigation) return 'CyberSight is navigating. Tap to stop.';
    if (isSpeaking) return 'CyberSight is speaking. Tap to interrupt.';
    if (isProcessing) return 'CyberSight is processing. Tap to interrupt.';
    if (isListening) return `CyberSight is listening. ${transcript ? `You said: ${transcript}. ` : ''}Tap to stop.`;
    return 'CyberSight is ready. Tap to speak.';
  };

  const getAccessibilityHint = () => {
    if (isNavigation) return 'Tap to stop navigation';
    if (isSpeaking || isProcessing) return 'Tap to stop';
    if (isListening) return 'Speak naturally. Tap to stop.';
    return 'Tap to start speaking';
  };

  // ============================================================================
  // Start Listening
  // ============================================================================
  const startListening = async () => {
    try {
      if (Platform.OS === 'android') {
        const granted = await PermissionsAndroid.request(PermissionsAndroid.PERMISSIONS.RECORD_AUDIO);
        if (granted !== PermissionsAndroid.RESULTS.GRANTED) {
          Alert.alert('Permission Required', 'Microphone access is required.');
          return;
        }
      }

      isEmergencyStopped.current = false;
      isCapturingPhotoRef.current = false;
      await stopTTS();
      finalTranscriptRef.current = '';

      audioFeedback.playEarcon('listening');
      playSound('start');

      await audioFeedback.announceState('listening', false);
      await new Promise(resolve => setTimeout(resolve, 100));

      await startSTT();
      console.log('✅ Voice recognition started');
    } catch (error) {
      console.error('❌ Start listening error:', error);
      AccessibilityInfo.announceForAccessibility(`Error: ${error}. Please try again.`);
    }
  };

  // ============================================================================
  // Manual Stop
  // ============================================================================
  const stopListeningManually = async () => {
    try {
      console.log('🛑 Manual stop requested');

      if (isCapturingPhotoRef.current) {
        console.log('⚠️ Already capturing');
        return;
      }

      if (isProcessingRef.current || isEmergencyStopped.current) {
        return;
      }

      const finalTranscript = await stopSTT();
      console.log('📝 Final transcript:', finalTranscript);

      const finalText = finalTranscript.trim();
      if (!finalText) {
        AccessibilityInfo.announceForAccessibility('No voice input. Tap to try again.');
        audioFeedback.playEarcon('error');
        return;
      }

      // ✅ FIX: Set processing state IMMEDIATELY
      console.log('⚡ Processing:', finalText);
      setIsProcessing(true);
      isProcessingRef.current = true;
      isCapturingPhotoRef.current = true;

      // ✅ FIX: Play thinking earcon immediately
      audioFeedback.playEarcon('thinking');
      AccessibilityInfo.announceForAccessibility('Processing your request');

      // Wait for audio session
      console.log(`⏳ Waiting ${AUDIO_SESSION_RELEASE_DELAY_MS}ms for audio session...`);
      await new Promise(resolve => setTimeout(resolve, AUDIO_SESSION_RELEASE_DELAY_MS));

      if (isEmergencyStopped.current) {
        isCapturingPhotoRef.current = false;
        setIsProcessing(false);
        isProcessingRef.current = false;
        return;
      }

      // Reactivate camera and capture
      const photoPath = await reactivateCameraAndCapture();

      // ✅ FIX: No success earcon
      if (!photoPath) {
        AccessibilityInfo.announceForAccessibility(
          'Warning: Failed to capture photo. Continuing with voice only.'
        );
      }

      isCapturingPhotoRef.current = false;
      await handleVoiceCommand(finalText, photoPath);
    } catch (error) {
      console.error('❌ Manual stop error:', error);
      isCapturingPhotoRef.current = false;
      setIsProcessing(false);
      isProcessingRef.current = false;
    }
  };

  // ============================================================================
  // Handle Voice Command
  // ============================================================================
  const handleVoiceCommand = async (command: string, photoPath: string) => {
    if (isProcessingRef.current || isEmergencyStopped.current) return;

    const wasInContinuousMode = isContinuousModeActive();
    if (wasInContinuousMode) {
      console.log('🔄 Previous continuous mode detected, resetting session for new command');
      const newSessionId = resetSessionId();
      console.log('🆔 New session started:', newSessionId);
    }

    const abortController = new AbortController();
    abortControllerRef.current = abortController;

    try {
      console.log('⚡ Processing:', command);
      isProcessingRef.current = true;
      setIsProcessing(true);

      try { await cancelSTT(); } catch (e) { }

      audioFeedback.playEarcon('thinking');
      playSound('processing');
      await audioFeedback.announceState('thinking', false);

      if (!photoPath) {
        console.warn('⚠️ No photo - voice-only mode');
        AccessibilityInfo.announceForAccessibility('Processing without photo.');
      }

      if (isEmergencyStopped.current) return;

      console.log('📤 Sending to workflow...');

      // =========================================================================
      // Send INITIAL request with BOTH flags FALSE
      // =========================================================================
      const result = await sendToWorkflow(
        {
          text: command,
          imageUri: photoPath || '',
          imageWidth: lastImageDimensions.current.width,
          imageHeight: lastImageDimensions.current.height,
          navigation: false,
          reaching_flag: false
        },
        abortController.signal
      );

      if (isEmergencyStopped.current) return;

      console.log('✅ Response:', {
        text: result.text.substring(0, 50) + '...',
        navigation: result.navigation,
        reaching_flag: result.reaching_flag,
        loopDelay: result.loopDelay,
      });

      setIsProcessing(false);
      setIsSpeaking(true);
      audioFeedback.playEarcon('speaking');

      if (isEmergencyStopped.current) return;

      // Speak the response
      await speachesSentenceChunker.synthesizeSpeechChunked(result.text);

      if (isEmergencyStopped.current) return;

      setIsSpeaking(false);
      finalTranscriptRef.current = '';


      // =========================================================================
      // ★★★ CHECK FOR iOS REACHING ON FIRST RESPONSE ★★★
      // =========================================================================
      if (Platform.OS === 'ios' && result.reaching_ios === true) {
        let bbox: number[] | null = null;

        // Parse bbox — skip if 'none' / 'null' / missing
        const rawBbox = result.bbox;
        if (rawBbox && rawBbox !== 'none' && rawBbox !== 'null' && rawBbox !== '') {
          if (Array.isArray(rawBbox)) {
            bbox = rawBbox as number[];
          } else if (typeof rawBbox === 'string') {
            try {
              const s = (rawBbox as string).replace(/[\[\]]/g, '');
              bbox = s.split(',').map((v: string) => Number(v.trim()));
              if (bbox.some(isNaN)) {
                console.warn('⚠️ bbox contains NaN, discarding');
                bbox = null;
              }
            } catch (e) {
              console.warn('Failed to parse bbox:', e);
              bbox = null;
            }
          }
        } else {
          console.log('⚠️ [iOS Reaching Loop] bbox missing/none:', rawBbox);
        }

        if (bbox && bbox.length === 4) {
          console.log('🎯 [iOS Reaching] First response has reaching_ios=true!');

          AccessibilityInfo.announceForAccessibility(
            `Guiding you to ${result.object || 'object'}. Follow the audio beeps.`
          );

          // CRITICAL: Deactivate RN camera BEFORE native VC takes over
          setIsCameraActive(false);
          setIsReaching(true);
          await new Promise(resolve => setTimeout(resolve, 500));

          try {
            const { ReachingModule } = NativeModules;

            if (ReachingModule?.startReaching) {
              console.log('🎯 [iOS Reaching] Calling native ReachingModule.startReaching...');

              const reachingResult = await ReachingModule.startReaching({
                bbox: bbox,
                object: result.object || 'object',
                depth: result.depth,
                imageWidth: lastImageDimensions.current.width,
                imageHeight: lastImageDimensions.current.height,
              });

              console.log('✅ [iOS Reaching] Result:', reachingResult);

              if (reachingResult?.success) {
                AccessibilityInfo.announceForAccessibility(
                  `${result.object || 'Object'} reached successfully!`
                );
              } else {
                AccessibilityInfo.announceForAccessibility('Reaching guidance ended.');
              }
            } else {
              console.warn('⚠️ ReachingModule not available');
            }
          } catch (reachingError: any) {
            console.error('❌ [iOS Reaching] Error:', reachingError);
          }

          // Reset and return to ready
          resetSessionId();
          setIsReaching(false);
          setIsCameraActive(true);
          audioFeedback.playEarcon('ready');
          AccessibilityInfo.announceForAccessibility('Ready. Tap to speak.');
          return;  // Don't enter continuous loop
        }
        else {
          // reaching_ios=true but no valid bbox — object detected but can't be precisely located
          console.log('⚠️ [iOS Reaching] reaching_ios=true but no valid bbox:', result.bbox);
          console.log('⚠️ [iOS Reaching] The backend detected the object but Qwen could not produce coordinates');
          // The response text already gave directional info to the user
          // Don't fall through to continuous loop — it will just get empty response
          setIsCameraActive(true);
          audioFeedback.playEarcon('ready');
          await speachesSentenceChunker.synthesizeSpeechChunked(
            `I can detect the ${result.object || 'object'} in the scene, but I could not get precise coordinates for ARKit reaching guidance. Try pointing your camera more directly at it and ask again.`
          );
          AccessibilityInfo.announceForAccessibility('Ready. Tap to speak.');
          return;
        }
      }
      // =========================================================================
      // CHECK FOR CONTINUOUS MODE ACTIVATION (either flag true)
      // =========================================================================
      const navigationActive = result.navigation === true;
      const reachingActive = result.reaching_flag === true;

      if (navigationActive || reachingActive) {
        const mode = navigationActive ? 'navigation' : 'reaching';
        console.log(`🔄 Backend requested ${mode} loop, starting...`);

        // Update state
        setIsNavigation(navigationActive);
        setIsReaching(reachingActive);

        // ✅ FIX: Reset the continuous mode state BEFORE starting
        // This clears any counters/timers from the initial request
        stopContinuousMode('resetting for new loop', false);  // false = don't reset session

        // Small delay to ensure clean state
        await new Promise(resolve => setTimeout(resolve, 100));

        // Set up loop state (now with fresh counters)
        startContinuousMode(mode, result.loopDelay);

        console.log('🔄 Starting fresh continuous loop...');

        // Run the continuous loop
        await runContinuousLoop();

        // Loop has ended, we're done
        return;
      }

      // Normal response (no continuous mode) - return to ready state
      setIsCameraActive(true);

      audioFeedback.playEarcon('ready');
      AccessibilityInfo.announceForAccessibility('Response complete. Tap to speak.');

    } catch (error: any) {
      if (error.name === 'AbortError' || error.message?.includes('aborted') || error.message?.includes('cancel')) {
        console.log('✅ Request cancelled');
        return;
      }

      if (!isEmergencyStopped.current) {
        console.error('❌ Error:', error);
        await audioFeedback.announceError(`Error: ${error.message}`, true);
        Alert.alert('Error', error.message);
      }
    } finally {
      setIsProcessing(false);
      isProcessingRef.current = false;
      finalTranscriptRef.current = '';
      abortControllerRef.current = null;
    }
  };

  // ============================================================================
  // Emergency Stop
  // ============================================================================
  const emergencyStop = async () => {
    console.log('🚨 EMERGENCY STOP');
    isEmergencyStopped.current = true;
    continuousModeAbortRef.current = true;  // NEW: Also abort continuous mode

    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
      abortControllerRef.current = null;
    }

    await speachesSentenceChunker.stop();
    try { await cancelSTT(); } catch (e) { }

    await new Promise(resolve => setTimeout(resolve, 300));

    setIsProcessing(false);
    setIsSpeaking(false);
    setIsNavigation(false);
    setIsReaching(false);  // NEW
    isProcessingRef.current = false;
    finalTranscriptRef.current = '';
    isCapturingPhotoRef.current = false;
    isContinuousModeRunning.current = false;  // NEW

    // Stop continuous mode (preserve session on emergency stop)
    stopContinuousMode('emergency stop', false);  // false = preserve session

    // Re-enable camera
    setIsCameraActive(true);

    isEmergencyStopped.current = false;

    audioFeedback.playEarcon('ready');
    AccessibilityInfo.announceForAccessibility('Stopped. Tap to speak.');
    console.log('✅ Emergency stop complete');
  };

  // ============================================================================
  // Handle Tap
  // ============================================================================
  const handleScreenTap = async () => {
    console.log('👆 TAP');

    // If in continuous mode (navigation OR reaching), stop it
    if (isNavigation || isReaching || isContinuousModeRunning.current) {
      const mode = isNavigation ? 'navigation' : 'reaching';
      console.log(`🛑 Stopping ${mode}`);
      AccessibilityInfo.announceForAccessibility(`Stopping ${mode}.`);
      await stopContinuousModeLoop();
      return;
    }

    // If speaking or processing, emergency stop
    if (isSpeaking || isProcessing) {
      console.log('🛑 Stopping');
      AccessibilityInfo.announceForAccessibility('Stopping.');
      await emergencyStop();
      return;
    }

    // If listening, manual stop
    if (isListening) {
      console.log('🛑 Manual stop');
      AccessibilityInfo.announceForAccessibility('Processing now.');
      await stopListeningManually();
      return;
    }

    // Otherwise, start listening
    console.log('🎤 Starting');
    await startListening();
  };

  // ============================================================================
  // Render
  // ============================================================================
  if (!hasCameraPermission || !device) {
    return (
      <View style={styles.container} accessible={true} accessibilityLabel="Waiting for camera permission.">
        <StatusBar barStyle="light-content" backgroundColor="#000" />
      </View>
    );
  }

  return (
    <TouchableWithoutFeedback
      onPress={handleScreenTap}
      accessible={true}
      accessibilityLabel={getAccessibilityLabel()}
      accessibilityHint={getAccessibilityHint()}
      accessibilityRole="button"
      accessibilityLiveRegion="polite"
      accessibilityState={{ busy: isProcessing || isNavigation, disabled: false }}
    >
      <View ref={containerRef} style={styles.container} accessible={false} importantForAccessibility="no-hide-descendants">
        <StatusBar barStyle="light-content" backgroundColor="#000" />

        {/* Camera - isActive controlled by state */}
        <Camera
          ref={cameraRef}
          style={StyleSheet.absoluteFill}
          device={device}
          isActive={isCameraActive}
          photo={true}
          accessible={false}
          accessibilityElementsHidden={true}
        />

        <View style={styles.darkOverlay} accessible={false} importantForAccessibility="no-hide-descendants" />

        {/* Voice Visualizer - now with isNavigation prop */}
        <VoiceVisualizer
          isListening={isListening}
          isProcessing={isProcessing}
          isSpeaking={isSpeaking}
          isNavigation={isNavigation}
          isReaching={isReaching}  // NEW
          transcript={transcript}
          pulseAnim={pulseAnim}
          opacityAnim={opacityAnim}
        />
      </View>
    </TouchableWithoutFeedback>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#000',
  },
  darkOverlay: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: 'rgba(0, 0, 0, 0.85)',
  },
});

export default App;