// App.tsx - CyberSight Mobile Application

import React, { useState, useEffect, useRef, useCallback } from 'react';
import {
  StyleSheet,
  View,
  TouchableWithoutFeedback,
  TouchableOpacity,
  Text,
  Platform,
  PermissionsAndroid,
  Alert,
  Animated,
  Dimensions,
  StatusBar,
  AccessibilityInfo,
  NativeModules,
} from 'react-native';
import {
  Camera,
  useCameraDevice,
  useCameraPermission,
  useMicrophonePermission,
} from 'react-native-vision-camera';
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
import {
  initSounds,
  releaseSounds,
  playListenSound,
  playThinkingStarted,
  stopLatencyLoop,
  playSuccessChime,
  playErrorSound,
  prepareForRecording,
} from './src/utils/soundEffects';
import { audioFeedback } from './src/services/AudioFeedbackService';
import { speachesSentenceChunker } from './src/services/SpeachesSentenceChunker';
import { NAVIGATION_CONFIG, DETECTION_URL } from './src/utils/constants';
import { fixImageOrientation } from './src/services/fixImageOrientation';
import { SettingsProvider, useSettings } from './src/context/SettingsContext';
import SettingsScreen from './src/screens/SettingsScreen';
import { debugLogger } from './src/services/DebugLogger';
import { DebugOverlay } from './src/components/DebugOverlay';

const { width, height } = Dimensions.get('window');

// =============================================================================
// TIMING CONSTANTS
// =============================================================================
const CAMERA_REACTIVATION_DELAY_MS = 800;
const AUDIO_SESSION_RELEASE_DELAY_MS = 300;
const TTS_COMPLETION_BUFFER_MS = 500;

// =============================================================================
// PIPELINE PRE-FETCH CONFIGURATION
// =============================================================================
const PREFETCH_CONFIG = {
  ENABLED: true,
  MIN_TTS_TIME_BEFORE_PREFETCH: 3000,
  PREFETCH_TRIGGER_PERCENT: 75,
  PROGRESS_POLL_INTERVAL: 500,
  MIN_CYCLE_COOLDOWN: 300,
};

// =============================================================================
// AppInner
// =============================================================================
function AppInner(): React.JSX.Element {

  // ── State ──────────────────────────────────────────────────────────────────
  const [isProcessing, setIsProcessing] = useState(false);
  const [isSpeaking, setIsSpeaking] = useState(false);
  const [isNavigation, setIsNavigation] = useState(false);
  const [isReaching, setIsReaching] = useState(false);
  const [screenReaderEnabled, setScreenReaderEnabled] = useState(false);
  const [reduceMotionEnabled, setReduceMotionEnabled] = useState(false);
  const [isCameraActive, setIsCameraActive] = useState(true);
  const [showSettings, setShowSettings] = useState(false);

  // ── Settings ───────────────────────────────────────────────────────────────
  const { settings, resolveReachingPipeline } = useSettings();
  // Ref always holds the latest settings — avoids stale closure in useCallback
  const settingsRef = useRef(settings);
  useEffect(() => { settingsRef.current = settings; }, [settings]);

  // ── Camera / Permissions ───────────────────────────────────────────────────
  const device = useCameraDevice('back');
  const { hasPermission: hasCameraPermission, requestPermission: requestCameraPermission } = useCameraPermission();
  const { hasPermission: hasMicPermission, requestPermission: requestMicPermission } = useMicrophonePermission();
  const cameraRef = useRef<Camera>(null);
  const containerRef = useRef<View>(null);

  // ── Audio / Speech ─────────────────────────────────────────────────────────
  const { speak, stop: stopTTS } = useTTS();

  // ── Internal Refs ──────────────────────────────────────────────────────────
  const isEmergencyStopped = useRef(false);
  const isProcessingRef = useRef(false);
  const finalTranscriptRef = useRef('');
  const abortControllerRef = useRef<AbortController | null>(null);
  const isCapturingPhotoRef = useRef(false);
  const isNavigationLoopRunning = useRef(false);
  const navigationLoopAbortRef = useRef(false);
  const isContinuousModeRunning = useRef(false);
  const continuousModeAbortRef = useRef(false);
  const lastImageDimensions = useRef<{ width: number; height: number }>({ width: 0, height: 0 });
  const prefetchedPhotoRef = useRef<string | null>(null);
  // Ref so handleAutoSubmit can call handleVoiceCommand without circular dep
  const handleVoiceCommandRef = useRef<(command: string, photoPath: string) => Promise<void>>(async () => { });
  // Ref so handleAutoSubmit (stable [] deps) can check screen reader state
  const screenReaderEnabledRef = useRef(false);

  // ── Animation ──────────────────────────────────────────────────────────────
  const pulseAnim = useRef(new Animated.Value(1)).current;
  const opacityAnim = useRef(new Animated.Value(0.3)).current;

  // ── Debug native modules on mount ──────────────────────────────────────────
  useEffect(() => {
    const { ReachingModule } = NativeModules;
    console.log('🔍 NativeModules keys:', Object.keys(NativeModules));
    console.log('🔍 ReachingModule:', ReachingModule);
    console.log('🔍 ReachingModule.startReaching:', ReachingModule?.startReaching);
  }, []);

  // ── Session / config log ───────────────────────────────────────────────────
  useEffect(() => {
    debugLogger.init(); // Install console interceptors for debug overlay
    console.log('🚀 CyberSight App Started');
    console.log('🆔 Session ID:', getSessionId());
    console.log('🔄 Navigation loop enabled:', NAVIGATION_CONFIG.ENABLE_NAVIGATION_LOOP);
  }, []);

  // ── Pre-warm TTS ───────────────────────────────────────────────────────────
  useEffect(() => {
    const timer = setTimeout(async () => {
      try {
        await speachesSentenceChunker.synthesizeSpeechChunked('');
        console.log('✅ TTS pre-warmed');
      } catch (e) {
        console.warn('⚠️ TTS pre-warm failed (non-critical):', e);
      }
    }, 1000);
    return () => clearTimeout(timer);
  }, []);

  // ── Accessibility ──────────────────────────────────────────────────────────
  useEffect(() => {
    (async () => {
      try {
        const [sr, rm] = await Promise.all([
          AccessibilityInfo.isScreenReaderEnabled(),
          AccessibilityInfo.isReduceMotionEnabled(),
        ]);
        setScreenReaderEnabled(sr);
        screenReaderEnabledRef.current = sr;
        setReduceMotionEnabled(rm);
        // NOTE: Do NOT announce here — VoiceOver will read the button's
        // accessibilityLabel automatically when focus lands on it.
        // A programmatic announcement creates double-speech:
        // "CyberSight is ready tap to speak button tap to start speaking"
      } catch (e) { console.error('❌ Accessibility check:', e); }
    })();

    const srSub = AccessibilityInfo.addEventListener('screenReaderChanged', (enabled: boolean) => {
      setScreenReaderEnabled(enabled);
      screenReaderEnabledRef.current = enabled;
    });
    const rmSub = AccessibilityInfo.addEventListener('reduceMotionChanged', setReduceMotionEnabled);
    return () => { srSub?.remove(); rmSub?.remove(); };
  }, []);

  // ── Sound Check ──────────────────────────────────────────────────────────
  useEffect(() => {
    initSounds().then(() => {
      console.log('✅ [App] Sound effects loaded');
    }).catch((err) => {
      console.error('❌ [App] Sound load failed:', err);
    });
  }, []);

  // ── Android permissions ────────────────────────────────────────────────────
  useEffect(() => {
    if (Platform.OS === 'android') {
      PermissionsAndroid.requestMultiple([
        PermissionsAndroid.PERMISSIONS.RECORD_AUDIO,
        PermissionsAndroid.PERMISSIONS.CAMERA,
      ]).then(results => {
        const ok =
          results['android.permission.RECORD_AUDIO'] === 'granted' &&
          results['android.permission.CAMERA'] === 'granted';
        if (!ok) Alert.alert('Permissions Required', 'Please enable camera and microphone permissions.');
      }).catch(e => console.warn('Permission error:', e));
    }
  }, []);

  useEffect(() => {
    if (!hasCameraPermission) requestCameraPermission();
    if (!hasMicPermission) requestMicPermission();
  }, [hasCameraPermission, hasMicPermission]);

  // ── Sync transcript ref ────────────────────────────────────────────────────
  useEffect(() => {
    if (transcript) finalTranscriptRef.current = transcript;
  }, [transcript]);

  // ── Disable camera during voice recognition ────────────────────────────────
  useEffect(() => {
    if (isListening) {
      console.log('📷 Disabling camera (voice recognition active)');
      setIsCameraActive(false);
    }
  }, [isListening]);

  // ── Pulse animation ────────────────────────────────────────────────────────
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
  // Camera capture helper
  // ============================================================================
  const reactivateCameraAndCapture = async (): Promise<string> => {
    console.log('📷 Reactivating camera for capture...');
    setIsCameraActive(true);

    await new Promise(resolve => setTimeout(resolve, CAMERA_REACTIVATION_DELAY_MS));

    if (!cameraRef.current) {
      console.error('❌ Camera ref not available after reactivation');
      return '';
    }

    try {
      const photo = await cameraRef.current.takePhoto({
        enableShutterSound: false,
        flash: 'off',
      });
      const fixedImage = await fixImageOrientation(photo.path);
      lastImageDimensions.current = {
        width: fixedImage.width || 0,
        height: fixedImage.height || 0,
      };
      console.log('✅ Photo captured & fixed:', fixedImage.uri,
        `(${fixedImage.width}×${fixedImage.height})`);
      return fixedImage.uri;
    } catch (error) {
      console.error('❌ Photo capture failed, retrying:', error);
      await new Promise(resolve => setTimeout(resolve, 500));
      try {
        const retry = await cameraRef.current.takePhoto({
          enableShutterSound: false,
        });
        return retry.path;
      } catch (e) {
        console.error('❌ Retry also failed:', e);
        return '';
      }
    }
  };

  // ============================================================================
  // iOS Reaching helper — shared by both reaching blocks
  // Accepts the full result + image dims, calls ReachingModule, resets state.
  // Returns true if reaching module was invoked.
  // ============================================================================
  const handleiOSReaching = useCallback(async (result: any): Promise<boolean> => {
    // ── Resolve user preference ───────────────────────────────────────────
    const pipeline = resolveReachingPipeline({
      reaching_ios: result.reaching_ios,
      reaching: result.reaching_flag,
    });

    if (pipeline !== 'arkit') {
      // User prefers standard pipeline or ARKit not available
      console.log(`🎯 [Reaching] Skipping ARKit — pipeline resolved to: ${pipeline}`);
      return false;
    }

    // ── Parse bbox ────────────────────────────────────────────────────────
    let bbox: number[] | null = null;
    const rawBbox = result.bbox;

    if (rawBbox && rawBbox !== 'none' && rawBbox !== 'null' && rawBbox !== '') {
      if (Array.isArray(rawBbox)) {
        bbox = rawBbox as number[];
      } else if (typeof rawBbox === 'string') {
        try {
          const s = (rawBbox as string).replace(/[\[\]]/g, '');
          bbox = s.split(',').map((v: string) => Number(v.trim()));
          if (bbox.some(isNaN)) { bbox = null; }
        } catch { bbox = null; }
      }
    }

    if (!bbox || bbox.length !== 4) {
      // reaching_ios=true but no valid bbox — guard with isSpeaking so
      // a tap during TTS routes to emergencyStop, NOT startListening (dead-loop fix)
      console.log('⚠️ [ARKit] reaching_ios=true but no valid bbox:', rawBbox);
      setIsSpeaking(true);
      await speachesSentenceChunker.synthesizeSpeechChunked(
        `I can detect the ${result.object || 'object'} in the scene, but I could not get precise coordinates for guidance. Try pointing your camera more directly at it and ask again.`
      );
      setIsSpeaking(false);                // ← release speaking guard
      // Clean transition to ready (matches the ARKit-success path below)
      setIsCameraActive(true);
      if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
      AccessibilityInfo.announceForAccessibility('Ready. Tap to speak.');
      return true; // Handled (but without ARKit)
    }

    console.log('🎯 [ARKit] Launching native reaching for:', result.object, 'bbox:', bbox);

    AccessibilityInfo.announceForAccessibility(
      `Guiding you to ${result.object || 'object'}. Follow the audio beeps. Tap anywhere when you have it.`
    );

    setIsCameraActive(false);
    setIsReaching(true);
    await new Promise(resolve => setTimeout(resolve, 500));

    try {
      const { ReachingModule } = NativeModules;
      if (ReachingModule?.startReaching) {
        const reachingResult = await ReachingModule.startReaching({
          bbox,
          object: result.object || 'object',
          depth: result.depth,
          imageWidth: lastImageDimensions.current.width,
          imageHeight: lastImageDimensions.current.height,
          detectionUrl: DETECTION_URL,
          mode: settingsRef.current.reachingMode,
          ttsRate: settingsRef.current.ttsRate,
          distanceUnit: settingsRef.current.distanceUnit,
        });

        console.log('✅ [ARKit] Native result:', reachingResult);

        // Manual exit: reason will be "user_confirmed" or "ar_error"
        const msg = reachingResult?.reason === 'user_confirmed'
          ? 'Reaching complete.'
          : reachingResult?.success
            ? `${result.object || 'Object'} reached!`
            : 'Reaching guidance ended.';
        AccessibilityInfo.announceForAccessibility(msg);
      } else {
        console.warn('⚠️ ReachingModule not available — native module not linked');
        AccessibilityInfo.announceForAccessibility(
          'Reaching module not available. Please rebuild the app.'
        );
      }
    } catch (e: any) {
      console.error('❌ [ARKit] Native module error:', e);
      AccessibilityInfo.announceForAccessibility(`Reaching error: ${e.message || 'Unknown error'}`);
    }

    resetSessionId();
    setIsReaching(false);
    setIsCameraActive(true);
    if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
    AccessibilityInfo.announceForAccessibility('Ready. Tap to speak.');
    return true;
  }, [resolveReachingPipeline]);

  // ============================================================================
  // CONTINUOUS LOOP
  // ============================================================================
  const runContinuousLoop = useCallback(async () => {
    if (!NAVIGATION_CONFIG.ENABLE_NAVIGATION_LOOP) {
      console.log('🔄 [ContinuousMode] Disabled in config');
      return;
    }
    if (isContinuousModeRunning.current) {
      console.log('🔄 [ContinuousMode] Already running');
      return;
    }

    console.log('🔄 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('🔄 [ContinuousMode] Starting EVENT-DRIVEN loop');
    console.log('🔄 [ContinuousMode] Pre-fetch:', PREFETCH_CONFIG.ENABLED ? 'ON' : 'OFF');

    isContinuousModeRunning.current = true;
    continuousModeAbortRef.current = false;
    prefetchedPhotoRef.current = null;
    let cycleCount = 0;

    const currentMode = getCurrentMode();
    AccessibilityInfo.announceForAccessibility(`${currentMode} started. Tap to stop.`);

    while (!continuousModeAbortRef.current && !isEmergencyStopped.current) {
      if (shouldPreventInfiniteLoop()) {
        AccessibilityInfo.announceForAccessibility('Stopped due to time limit.');
        break;
      }

      cycleCount++;
      const cycleStart = Date.now();
      console.log(`\n🔄 ═══ CYCLE #${cycleCount} START ═══`);

      try {
        incrementContinuousMode();

        // ── Capture ────────────────────────────────────────────────────────
        let photoPath = '';
        if (prefetchedPhotoRef.current) {
          photoPath = prefetchedPhotoRef.current;
          prefetchedPhotoRef.current = null;
          console.log('🔄 ✅ Using PRE-FETCHED photo');
        } else {
          photoPath = await reactivateCameraAndCapture();
        }

        if (continuousModeAbortRef.current || isEmergencyStopped.current) break;

        // ── Send to backend ────────────────────────────────────────────────
        setIsProcessing(true);
        const abortCtrl = new AbortController();
        abortControllerRef.current = abortCtrl;

        if (!screenReaderEnabledRef.current) {
          playThinkingStarted(); // ← start thinking SFX for this cycle
        }

        const loopMode = getCurrentMode();
        const result = await sendToWorkflow(
          {
            text: '',
            imageUri: photoPath || '',
            imageWidth: lastImageDimensions.current.width,
            imageHeight: lastImageDimensions.current.height,
            navigation: loopMode === 'navigation',
            reaching_flag: loopMode === 'reaching',
          },
          abortCtrl.signal
        );

        await stopLatencyLoop(); // ← stop thinking SFX when result arrives
        setIsProcessing(false);


        if (continuousModeAbortRef.current || isEmergencyStopped.current) break;

        console.log('🔄 Backend result:', {
          text: result.text?.substring(0, 50),
          navigation: result.navigation,
          reaching_flag: result.reaching_flag,
          reaching_ios: result.reaching_ios,
          bbox: result.bbox,
          loopDelay: result.loopDelay,
        });

        if (result.loopDelay) updateLoopDelay(result.loopDelay);

        // ── "Null" response detection ──────────────────────────────────────
        // The n8n synthesizer returns the literal string "Null" when Redis
        // fields are empty (e.g. guidance pipeline hasn't populated yet).
        // Detect it, log it, and clear text so downstream TTS blocks skip.
        const rawText = result.text;
        const isNullResponse =
          typeof rawText === 'string' &&
          rawText.trim().toLowerCase() === 'null';

        if (isNullResponse) {
          result.text = ''; // clear so every `if (result.text)` guard skips TTS
        }

        // ── Structured debug log (EVERY cycle) ────────────────────────────
        const cycleElapsed = Date.now() - cycleStart;
        debugLogger.logAPI(
          `🔄 Cycle #${cycleCount} | ${isNullResponse ? '⏭️ NULL' : '🔊 SPEAK'} | ${cycleElapsed}ms`,
          `mode=${loopMode} nav=${result.navigation} reach=${result.reaching_flag} ios=${result.reaching_ios} text="${(rawText || '').substring(0, 80)}"`,
        );

        if (isNullResponse) {
          console.log(`🔄 ⏭️ Cycle #${cycleCount} — "Null" response, skipping TTS, fast-polling…`);
        }

        // ── iOS ARKit reaching check (respects user preference) ───────────
        if (Platform.OS === 'ios' && result.reaching_ios === true) {
          // Check pipeline FIRST — determines whether to kill the loop or continue it
          const loopPipeline = resolveReachingPipeline({
            reaching_ios: result.reaching_ios,
            reaching: result.reaching_flag,
          });

          if (loopPipeline === 'arkit') {
            // ── ARKit path: speak, abort loop, hand off ──────────────────
            if (result.text) {
              setIsSpeaking(true);
              await speachesSentenceChunker.synthesizeSpeechChunked(result.text);
              setIsSpeaking(false);
            }
            isContinuousModeRunning.current = true; // keep until handoff complete
            continuousModeAbortRef.current = true;
            stopContinuousMode('iOS reaching takeover', false);
            const handled = await handleiOSReaching(result);
            if (handled) {
              setIsNavigation(false);
              setIsReaching(false);
              setIsProcessing(false);
              isContinuousModeRunning.current = false;
              return; // ★ ARKit handled — clean exit
            }
            // ARKit path but module unavailable — loop is already aborted, exit
            break;

          } else {
            // ── Standard pipeline: use reaching_completed to gate the loop ─
            if (result.reaching_completed === true) {
              // Backend says object reached — speak final message and reset
              if (result.text) {
                setIsSpeaking(true);
                await speachesSentenceChunker.synthesizeSpeechChunked(result.text);
                setIsSpeaking(false);
              }
              console.log('✅ [Reaching] reaching_completed=true — resetting session');
              resetSessionId();
              stopContinuousMode('reaching complete', true);
              break; // ★ Standard complete — clean exit
            }
            // reaching_completed=false → do NOT abort, fall through and loop again
            console.log('🔄 [Reaching] Standard mode — reaching_completed=false, continuing...');
          }
        }

        // ── Flag check ─────────────────────────────────────────────────────
        const navigationActive = result.navigation === true;
        const reachingActive = result.reaching_flag === true;
        const bothInactive = !navigationActive && !reachingActive;

        setIsNavigation(navigationActive);
        setIsReaching(reachingActive);

        if (bothInactive) {
          if (result.text) {
            setIsSpeaking(true);
            await speachesSentenceChunker.synthesizeSpeechChunked(result.text);
            setIsSpeaking(false);
          }
          AccessibilityInfo.announceForAccessibility('Task complete.');
          stopContinuousMode('both flags false', true);
          break;
        }

        // ── Mode transitions ───────────────────────────────────────────────
        if (navigationActive && !reachingActive && loopMode !== 'navigation') {
          startContinuousMode('navigation', result.loopDelay);
          AccessibilityInfo.announceForAccessibility('Switching to navigation.');
        } else if (reachingActive && !navigationActive && loopMode !== 'reaching') {
          startContinuousMode('reaching', result.loopDelay);
          AccessibilityInfo.announceForAccessibility('Switching to object guidance.');
        }

        // ── Speak + optional pre-fetch ─────────────────────────────────────
        if (result.text && !continuousModeAbortRef.current && !isEmergencyStopped.current) {
          setIsSpeaking(true);

          if (PREFETCH_CONFIG.ENABLED) {
            await Promise.all([
              speachesSentenceChunker.synthesizeSpeechChunked(result.text),

              (async () => {
                try {
                  await new Promise(r => setTimeout(r, PREFETCH_CONFIG.MIN_TTS_TIME_BEFORE_PREFETCH));
                  if (continuousModeAbortRef.current || isEmergencyStopped.current) return;

                  while (speachesSentenceChunker.isCurrentlyPlaying()) {
                    if (continuousModeAbortRef.current || isEmergencyStopped.current) return;
                    const progress = speachesSentenceChunker.getProgress();
                    if (progress.percentage >= PREFETCH_CONFIG.PREFETCH_TRIGGER_PERCENT) {
                      const path = await reactivateCameraAndCapture();
                      if (path) {
                        prefetchedPhotoRef.current = path;
                        console.log('🔮 [Prefetch] ✅ Photo ready for next cycle');
                      }
                      return;
                    }
                    await new Promise(r => setTimeout(r, PREFETCH_CONFIG.PROGRESS_POLL_INTERVAL));
                  }
                } catch (e) {
                  console.warn('🔮 [Prefetch] Error (non-fatal):', e);
                }
              })(),
            ]);
          } else {
            await speachesSentenceChunker.synthesizeSpeechChunked(result.text);
          }

          setIsSpeaking(false);
          await new Promise(resolve =>
            setTimeout(resolve, PREFETCH_CONFIG.ENABLED
              ? PREFETCH_CONFIG.MIN_CYCLE_COOLDOWN
              : TTS_COMPLETION_BUFFER_MS)
          );
        } else if (isNullResponse) {
          // ── Fast-poll: "Null" text — skip TTS, rapid 500ms cycle ─────────
          // This gives ~2 polls/sec so we catch the real response quickly.
          console.log(`🔄 ⏭️ Null fast-poll — waiting 500ms before next cycle`);
          await new Promise(resolve => setTimeout(resolve, 500));
        }

        const cycleMs = Date.now() - cycleStart;
        debugLogger.logAPI(
          `🔄 Cycle #${cycleCount} DONE | ${isNullResponse ? 'NULL→SKIP' : 'SPOKE'} | ${(cycleMs / 1000).toFixed(1)}s`,
        );
        console.log(`🔄 ═══ CYCLE #${cycleCount} DONE (${(cycleMs / 1000).toFixed(1)}s) ${isNullResponse ? '[NULL-SKIP]' : ''} ═══`);

      } catch (error: any) {
        console.error('🔄 [ContinuousMode] Error:', error);
        if (error.message?.includes('cancel')) break;
        AccessibilityInfo.announceForAccessibility(`Error: ${error.message}`);
        break;
      }
    }

    // ── Cleanup ────────────────────────────────────────────────────────────
    console.log('🔄 [ContinuousMode] Loop ended');
    await stopLatencyLoop();
    isContinuousModeRunning.current = false;
    stopContinuousMode('loop ended', false);
    setIsNavigation(false);
    setIsReaching(false);
    setIsProcessing(false);
    setIsSpeaking(false);
    setIsCameraActive(true);
    if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
    AccessibilityInfo.announceForAccessibility('Ready. Tap to speak.');
  }, [handleiOSReaching, resolveReachingPipeline]);

  // ============================================================================
  // Stop helpers
  // ============================================================================
  const stopContinuousModeLoop = useCallback(async () => {
    console.log('🛑 Stopping continuous mode');
    continuousModeAbortRef.current = true;

    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
      abortControllerRef.current = null;
    }

    await stopLatencyLoop();
    await speachesSentenceChunker.stop();
    stopContinuousMode('user interrupt', false);
    setIsNavigation(false);
    setIsReaching(false);
    setIsProcessing(false);
    setIsSpeaking(false);
    isContinuousModeRunning.current = false;
    setIsCameraActive(true);

    if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('cancel'); }
    AccessibilityInfo.announceForAccessibility('Stopped. Tap to speak.');
  }, []);

  const stopNavigation = useCallback(async () => {
    navigationLoopAbortRef.current = true;
    if (abortControllerRef.current) { abortControllerRef.current.abort(); abortControllerRef.current = null; }
    await speachesSentenceChunker.stop();
    stopContinuousMode('user interrupt', false);
    setIsNavigation(false);
    setIsProcessing(false);
    setIsSpeaking(false);
    isNavigationLoopRunning.current = false;
    setIsCameraActive(true);
    if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('cancel'); }
    AccessibilityInfo.announceForAccessibility('Navigation stopped. Tap to speak.');
  }, []);

  // ============================================================================
  // Handle Voice Command  ← defined BEFORE handleAutoSubmit so ref is stable
  // ============================================================================
  const handleVoiceCommand = useCallback(async (command: string, photoPath: string) => {
    if (isProcessingRef.current || isEmergencyStopped.current) return;

    if (isContinuousModeActive()) {
      const sid = resetSessionId();
      console.log('🔄 Previous continuous mode detected — new session:', sid);
    }

    const abortCtrl = new AbortController();
    abortControllerRef.current = abortCtrl;

    try {
      console.log('⚡ Processing:', command);
      isProcessingRef.current = true;
      setIsProcessing(true);

      try { await cancelSTT(); } catch { }

      // Skip earcons/SFX when VoiceOver is on — audio session conflicts
      if (!screenReaderEnabledRef.current) {
        audioFeedback.playEarcon('thinking');
        playThinkingStarted();
      }


      if (!photoPath) {
        console.warn('⚠️ No photo — voice-only mode');
        AccessibilityInfo.announceForAccessibility('Processing without photo.');
      }

      if (isEmergencyStopped.current) return;

      const result = await sendToWorkflow(
        {
          text: command,
          imageUri: photoPath || '',
          imageWidth: lastImageDimensions.current.width,
          imageHeight: lastImageDimensions.current.height,
          navigation: false,
          reaching_flag: false,
        },
        abortCtrl.signal
      );

      if (isEmergencyStopped.current) return;

      await stopLatencyLoop();
      //await playSuccessChime();          // ← plays jbl_success_sae.caf

      console.log('✅ Response:', {
        text: result.text.substring(0, 50) + '...',
        navigation: result.navigation,
        reaching_flag: result.reaching_flag,
        reaching_ios: result.reaching_ios,
        loopDelay: result.loopDelay,
      });

      setIsProcessing(false);
      setIsSpeaking(true);
      // Skip earcon when VoiceOver is on — it would overlap with TTS response
      if (!screenReaderEnabledRef.current) {
        audioFeedback.playEarcon('speaking');
      }



      if (isEmergencyStopped.current) return;

      await speachesSentenceChunker.synthesizeSpeechChunked(result.text);

      if (isEmergencyStopped.current) return;

      setIsSpeaking(false);
      finalTranscriptRef.current = '';

      // ── iOS ARKit reaching on first response (respects user preference) ──
      if (Platform.OS === 'ios' && result.reaching_ios === true) {
        const handled = await handleiOSReaching(result);
        if (handled) return; // ARKit took over or gave fallback message
        // If not handled (e.g. user prefers standard pipeline), fall through
      }

      // ── Continuous mode activation ─────────────────────────────────────
      const navigationActive = result.navigation === true;
      const reachingActive = result.reaching_flag === true;

      if (navigationActive || reachingActive) {
        const mode = navigationActive ? 'navigation' : 'reaching';
        console.log(`🔄 Backend requested ${mode} loop`);

        setIsNavigation(navigationActive);
        setIsReaching(reachingActive);

        stopContinuousMode('resetting for new loop', false);
        await new Promise(resolve => setTimeout(resolve, 100));
        startContinuousMode(mode, result.loopDelay);

        await runContinuousLoop();
        return;
      }

      // ── Normal (no continuous mode) ────────────────────────────────────
      setIsCameraActive(true);
      if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
      AccessibilityInfo.announceForAccessibility('Ready. Tap to speak.');

    } catch (error: any) {
      // ── Cancelled / aborted requests are silent ──────
      if (
        error.name === 'AbortError' ||
        error.message?.includes('aborted') ||
        error.message?.includes('cancel')
      ) {
        console.log('✅ Request cancelled');
        return;
      }

      if (!isEmergencyStopped.current) {
        console.error('❌ handleVoiceCommand error:', error);
        console.error('❌ Error detail:', error?.message, error?.code);

        await stopLatencyLoop();
        if (!screenReaderEnabledRef.current) {
          audioFeedback.playEarcon('cancel');
          playErrorSound();
        }

        await new Promise(resolve => setTimeout(resolve, 600));

        await speachesSentenceChunker.synthesizeSpeechChunked(
          'Error processing your request.'
        );

        setIsCameraActive(true);
        if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
        AccessibilityInfo.announceForAccessibility('Ready. Tap to speak.');
      }
    } finally {
      setIsProcessing(false);
      isProcessingRef.current = false;
      finalTranscriptRef.current = '';
      abortControllerRef.current = null;
    }
  }, [handleiOSReaching, runContinuousLoop]);

  // Keep ref in sync so handleAutoSubmit can call latest version
  useEffect(() => {
    handleVoiceCommandRef.current = handleVoiceCommand;
  }, [handleVoiceCommand]);

  // ============================================================================
  // Handle Auto-Submit (silence detection)
  // ============================================================================
  const handleAutoSubmit = useCallback(async (passedTranscript: string) => {
    console.log('🎯 Auto-submit triggered by silence detection');

    if (isCapturingPhotoRef.current || isProcessingRef.current || isEmergencyStopped.current) {
      console.log('⚠️ Already in-flight, skipping');
      return;
    }

    const finalText = (passedTranscript || finalTranscriptRef.current).trim();

    if (!finalText) {
      AccessibilityInfo.announceForAccessibility('No voice input detected. Tap to try again.');
      if (!screenReaderEnabledRef.current) { playErrorSound(); }
      return;
    }

    // ── VOICEOVER SAFETY NET ──────────────────────────────────────────────
    // Even with the STT delay, VoiceOver might still bleed into the mic.
    // Reject transcripts that are clearly VoiceOver UI text, not user speech.
    // Uses ref (not state) because handleAutoSubmit has stable [] deps.
    if (screenReaderEnabledRef.current) {
      const voPatterns = [
        'speak naturally', 'tap to stop', 'tap to speak', 'tap to interrupt',
        'cybersight is ready', 'cybersight is listening', 'cybersight is speaking',
        'cybersight is processing', 'processing your request', 'double tap to',
        'ready tap to speak', 'ready button', 'listening button',
        'thinking button', 'speaking button', 'navigating button',
        'button tap', 'ready tap', 'ready to speak',
        'please speak your command', 'please speak your',
      ];
      const lower = finalText.toLowerCase();
      if (voPatterns.some(p => lower.includes(p))) {
        console.log('♿ VoiceOver noise rejected:', finalText);
        // CRITICAL: Do NOT announce anything here. Any announceForAccessibility
        // call gets read by VoiceOver, the mic picks it up, and it becomes
        // the transcript for the NEXT listening session ("please speak your command").
        return;
      }
    }

    console.log('⚡ Processing:', finalText);
    setIsProcessing(true);
    isCapturingPhotoRef.current = true;
    if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('thinking'); }
    AccessibilityInfo.announceForAccessibility('Thinking');

    try {
      try { await cancelSTT(); } catch { }

      await new Promise(resolve => setTimeout(resolve, AUDIO_SESSION_RELEASE_DELAY_MS));

      if (isEmergencyStopped.current) {
        setIsProcessing(false);
        isCapturingPhotoRef.current = false;
        return;
      }

      let photoPath = '';
      try { photoPath = await reactivateCameraAndCapture(); } catch (e) { console.error('❌ Camera error:', e); }

      if (!photoPath) {
        AccessibilityInfo.announceForAccessibility(
          'Warning: Failed to capture photo. Continuing with voice only.'
        );
      }

      if (isEmergencyStopped.current) {
        setIsProcessing(false);
        isCapturingPhotoRef.current = false;
        return;
      }

      // Call via ref to avoid stale closure / circular dep
      await handleVoiceCommandRef.current(finalText, photoPath);

    } catch (error: any) {
      console.error('❌ Auto-submit error:', error);
      AccessibilityInfo.announceForAccessibility(`Error: ${error.message || error}`);
      setIsProcessing(false);
    } finally {
      isCapturingPhotoRef.current = false;
    }
  }, []); // stable — uses refs only

  // ============================================================================
  // STT hook
  // ============================================================================
  const {
    startListening: startSTT,
    stopListening: stopSTT,
    cancelListening: cancelSTT,
    isListening,
    transcript,
  } = useSTT({
    onAutoSubmit: handleAutoSubmit,
    enableAutoSubmit: true,
    silenceThreshold: 1500,
    enableRMSVAD: true,
  });

  // ── Re-entry guard for startListening ─────────────────────────────────────
  const isStartingRef = useRef(false);

  // ============================================================================
  // Start Listening
  // ============================================================================
  const startListening = async () => {
    // ── Re-entry guard: prevent multiple concurrent calls ────────────────
    // VoiceOver double-tap can fire handleScreenTap multiple times if the
    // user taps rapidly. Without this guard, each tap queues a startSTT().
    if (isStartingRef.current) {
      console.log('⚠️ startListening already in progress — ignoring');
      return;
    }
    isStartingRef.current = true;

    try {
      if (Platform.OS === 'android') {
        const granted = await PermissionsAndroid.request(
          PermissionsAndroid.PERMISSIONS.RECORD_AUDIO
        );
        if (granted !== PermissionsAndroid.RESULTS.GRANTED) {
          Alert.alert('Permission Required', 'Microphone access is required.');
          return;
        }
      }

      isEmergencyStopped.current = false;
      isCapturingPhotoRef.current = false;
      await stopTTS();
      finalTranscriptRef.current = '';

      // ── Audio feedback: Skip earcon/SFX when VoiceOver is on ──────────
      // VoiceOver owns the iOS audio session. Playing earcon sounds causes
      // audio session conflicts ("Failed to set properties, error: '!pri'")
      // producing glitchy/screamy artifacts. VoiceOver announcements replace
      // earcon feedback for blind users.
      if (!screenReaderEnabled) {
        audioFeedback.playEarcon('listening');
        playListenSound();

        // ✅ FIX: The earcon sets Sound.setCategory('Playback', false) which
        // locks the audio session in exclusive-playback mode. Voice.start()
        // needs PlayAndRecord. Reset the category BEFORE starting STT so the
        // mic can be acquired. PlayAndRecord allows the earcon to keep playing
        // while recording begins simultaneously.
        prepareForRecording();
      }

      // Delay to let audio session reconfigure after category switch
      await new Promise(resolve => setTimeout(resolve, 350));

      // ── Start STT immediately with grace period for VoiceOver ─────────
      // Instead of a long delay (which causes race conditions, stale labels,
      // and "Speech recognition already started!" errors), we start STT
      // right away but tell it to DISCARD any results arriving in the first
      // 2 seconds. VoiceOver reads the button label (~1.5s of speech) and
      // the mic picks it up — the grace period filters that noise out.
      const gracePeriodMs = screenReaderEnabled ? 3500 : 0;

      await startSTT(gracePeriodMs);
      console.log('✅ Voice recognition started');
    } catch (error) {
      console.error('❌ Start listening error:', error);
      if (screenReaderEnabled) {
        AccessibilityInfo.announceForAccessibility('Error starting voice. Tap to try again.');
      }
    } finally {
      isStartingRef.current = false;
    }
  };

  // ============================================================================
  // Manual Stop
  // ============================================================================
  const stopListeningManually = async () => {
    try {
      if (isCapturingPhotoRef.current || isProcessingRef.current || isEmergencyStopped.current) return;

      const finalTranscript = await stopSTT();
      const finalText = finalTranscript.trim();
      if (!finalText) { /* ... */ return; }

      // ── VoiceOver safety net ────────────────────────────────────────────
      if (isVoiceOverNoise(finalText)) {
        console.log('♿ VoiceOver noise rejected (manual stop):', finalText);
        // Silent discard — no announcement (would feed back into mic)
        return;
      }

      isCapturingPhotoRef.current = true;
      if (!screenReaderEnabled) { audioFeedback.playEarcon('thinking'); }
      AccessibilityInfo.announceForAccessibility('Thinking');

      await new Promise(resolve => setTimeout(resolve, AUDIO_SESSION_RELEASE_DELAY_MS));
      if (isEmergencyStopped.current) { isCapturingPhotoRef.current = false; return; }

      const photoPath = await reactivateCameraAndCapture();
      isCapturingPhotoRef.current = false;

      // ✅ DON'T set isProcessingRef here — handleVoiceCommand sets it itself
      await handleVoiceCommand(finalText, photoPath);
    } catch (error) {
      isCapturingPhotoRef.current = false;
      setIsProcessing(false);
      isProcessingRef.current = false;
    }
  };

  // ============================================================================
  // Emergency Stop
  // ============================================================================
  const emergencyStop = async () => {
    console.log('🚨 EMERGENCY STOP');
    isEmergencyStopped.current = true;
    isStartingRef.current = false; // ← release re-entry guard
    continuousModeAbortRef.current = true;

    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
      abortControllerRef.current = null;
    }

    await speachesSentenceChunker.stop();
    try { await cancelSTT(); } catch { }

    await new Promise(resolve => setTimeout(resolve, 300));

    setIsProcessing(false);
    setIsSpeaking(false);
    setIsNavigation(false);
    setIsReaching(false);
    isProcessingRef.current = false;
    finalTranscriptRef.current = '';
    isCapturingPhotoRef.current = false;
    isContinuousModeRunning.current = false;

    stopContinuousMode('emergency stop', false);
    setIsCameraActive(true);
    isEmergencyStopped.current = false;

    // Skip earcon when VoiceOver is on — audio session conflict
    if (!screenReaderEnabled) {
      audioFeedback.playEarcon('ready');
    }
    AccessibilityInfo.announceForAccessibility('Stopped. Tap to speak.');
    console.log('✅ Emergency stop complete');
  };

  // ============================================================================
  // Accessibility helpers
  // ============================================================================

  // ── VoiceOver Noise Filter ──────────────────────────────────────────────
  // When VoiceOver is on, it reads UI elements aloud. The mic can pick
  // this up and the speech recognizer treats it as user speech. This filter
  // rejects transcripts that match known VoiceOver UI text patterns.
  const isVoiceOverNoise = useCallback((text: string): boolean => {
    if (!screenReaderEnabled) return false;
    const patterns = [
      // Old labels (might still echo from previous announcement)
      'speak naturally', 'tap to stop', 'tap to speak', 'tap to interrupt',
      'cybersight is ready', 'cybersight is listening', 'cybersight is speaking',
      'cybersight is processing', 'processing your request', 'double tap to',
      // New simplified labels (VoiceOver reads these from the button)
      'ready tap to speak', 'ready button', 'listening button',
      'thinking button', 'speaking button', 'navigating button',
      'speaking tap', 'thinking tap', 'navigating tap',
      // Generic VoiceOver UI fragments
      'button tap', 'ready tap', 'ready to speak',
      // Our own rejection announcements (if they leaked)
      'please speak your command', 'please speak your',
    ];
    const lower = text.toLowerCase();
    return patterns.some(p => lower.includes(p));
  }, [screenReaderEnabled]);

  const getAccessibilityLabel = () => {
    // VoiceOver reads: {label}. {role}.
    // With accessibilityRole="button", VoiceOver appends "Button" automatically.
    // So "Ready. Tap to speak" → VoiceOver says "Ready. Tap to speak. Button."
    // Keep labels SHORT — no "CyberSight is" prefix (wastes time).
    if (isNavigation) return 'Navigating. Tap to stop';
    if (isSpeaking) return 'Speaking. Tap to stop';
    if (isProcessing) return 'Thinking';
    if (isListening) return 'Listening';
    return 'Ready. Tap to speak';
  };

  const getAccessibilityHint = () => {
    // Hints are read AFTER label + role, with a pause.
    // Only use for info NOT in the label.
    return '';
  };

  // ============================================================================
  // Handle Tap
  // ============================================================================
  const handleScreenTap = async () => {
    console.log('👆 TAP');

    if (isNavigation || isReaching || isContinuousModeRunning.current) {
      const mode = isNavigation ? 'navigation' : 'reaching';
      AccessibilityInfo.announceForAccessibility(`Stopping ${mode}.`);
      await stopContinuousModeLoop();
      return;
    }

    if (isSpeaking || isProcessing) {
      AccessibilityInfo.announceForAccessibility('Stopping.');
      await emergencyStop();
      return;
    }

    if (isListening) {
      AccessibilityInfo.announceForAccessibility('Thinking.');
      await stopListeningManually();
      return;
    }

    await startListening();
  };

  // ============================================================================
  // Render
  // ============================================================================
  if (!hasCameraPermission || !device) {
    return (
      <View
        style={styles.container}
        accessible={true}
        accessibilityLabel="Waiting for camera permission."
      >
        <StatusBar barStyle="light-content" backgroundColor="#000" />
      </View>
    );
  }

  // ── Settings overlay (full-screen, sits above everything) ─────────────────
  if (showSettings) {
    return (
      <View style={styles.container}>
        <StatusBar barStyle="light-content" backgroundColor="#0A0A0F" />
        <SettingsScreen onClose={() => setShowSettings(false)} />
        {settings.developerMode && <DebugOverlay />}
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <TouchableWithoutFeedback
        onPress={handleScreenTap}
        accessible={true}
        accessibilityLabel={getAccessibilityLabel()}
        accessibilityHint={getAccessibilityHint()}
        accessibilityRole="button"
        accessibilityState={{ busy: isProcessing || isNavigation, disabled: false }}
      >
        <View
          ref={containerRef}
          style={StyleSheet.absoluteFill}
          accessible={false}
          importantForAccessibility="no-hide-descendants"
        >
          <StatusBar barStyle="light-content" backgroundColor="#000" />

          {/* Camera */}
          <Camera
            ref={cameraRef}
            style={StyleSheet.absoluteFill}
            device={device}
            isActive={isCameraActive}
            photo={true}
            accessible={false}
            accessibilityElementsHidden={true}
          />

          <View
            style={styles.darkOverlay}
            accessible={false}
            importantForAccessibility="no-hide-descendants"
          />

          {/* Voice Visualizer */}
          <VoiceVisualizer
            isListening={isListening}
            isProcessing={isProcessing}
            isSpeaking={isSpeaking}
            isNavigation={isNavigation}
            isReaching={isReaching}
            transcript={transcript}
            pulseAnim={pulseAnim}
            opacityAnim={opacityAnim}
          />

          {/* ── Settings Gear Button (top-right) ── */}
          <TouchableOpacity
            style={styles.settingsGearButton}
            onPress={() => setShowSettings(true)}
            accessible={true}
            accessibilityRole="button"
            accessibilityLabel="Open settings"
            accessibilityHint="Double tap to open settings for voice speed and reaching pipeline"
            // Prevent the gear tap from also firing handleScreenTap
            onStartShouldSetResponder={() => true}
          >
            <Text style={styles.settingsGear} accessible={false}>⚙</Text>
          </TouchableOpacity>

        </View>
      </TouchableWithoutFeedback>

      {/* ── Debug Overlay (outside TouchableWithoutFeedback so touches work) ── */}
      {settings.developerMode && <DebugOverlay />}
    </View>
  );
}

// =============================================================================
// Root — wraps AppInner with SettingsProvider
// =============================================================================
function App(): React.JSX.Element {
  return (
    <SettingsProvider>
      <AppInner />
    </SettingsProvider>
  );
}

export default App;

// =============================================================================
// Styles
// =============================================================================
const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#000',
  },
  darkOverlay: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: 'rgba(0, 0, 0, 0.85)',
  },
  settingsGearButton: {
    position: 'absolute',
    top: Platform.OS === 'ios' ? 56 : 24,
    right: 20,
    width: 44,
    height: 44,
    borderRadius: 22,
    backgroundColor: 'rgba(255,255,255,0.08)',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.15)',
    alignItems: 'center',
    justifyContent: 'center',
    zIndex: 100,
  },
  settingsGear: {
    color: 'rgba(255,255,255,0.7)',
    fontSize: 20,
  },
});