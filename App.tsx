/**
 * App.tsx - CyberSight Mobile Application
 * 
 * FIXED: Complete Navigation Loop Implementation (Jan 25, 2026)
 * 
 * NAVIGATION LOOP FLOW (per team discussion):
 * 1. User says "take me to the bottle"
 * 2. Backend processes, returns { text: "...", navigation: true }
 * 3. Frontend enters navigation loop:
 *    - Speak TTS response
 *    - Wait loopDelay ms
 *    - Capture photo
 *    - Send to backend with { navigation: true, transcript: "" }
 *    - Repeat until backend returns { navigation: false }
 * 4. User can tap to interrupt at any time
 * 
 * KEY FIX: Camera cannot run simultaneously with voice recognition on iOS.
 * The camera session gets corrupted when voice recognition is active.
 * Solution: Set camera isActive={false} while listening, reactivate for capture.
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
} from './src/services/WorkflowService';
import { VoiceVisualizer } from './src/components/VoiceVisualizer';
import { playSound } from './src/utils/soundEffects';
import { audioFeedback } from './src/services/AudioFeedbackService';
import { speachesSentenceChunker } from './src/services/SpeachesSentenceChunker';
import { NAVIGATION_CONFIG } from './src/utils/constants';

const { width, height } = Dimensions.get('window');

// =============================================================================
// TIMING CONSTANTS
// =============================================================================
const CAMERA_REACTIVATION_DELAY_MS = 800;  // Wait for camera to fully initialize
const AUDIO_SESSION_RELEASE_DELAY_MS = 300; // Wait for audio session to release
const TTS_COMPLETION_BUFFER_MS = 500; // Buffer after TTS before next loop iteration

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

  // ============================================================================
  // Animation
  // ============================================================================
  const pulseAnim = useRef(new Animated.Value(1)).current;
  const opacityAnim = useRef(new Animated.Value(0.3)).current;

  // ============================================================================
  // Log session info on mount
  // ============================================================================
  useEffect(() => {
    console.log('🚀 CyberSight App Started');
    console.log('🆔 Session ID:', getSessionId());
    console.log('🔄 Navigation loop enabled:', NAVIGATION_CONFIG.ENABLE_NAVIGATION_LOOP);
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
      });
      console.log('✅ Photo captured successfully:', photo.path);
      return photo.path;
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
   * Loop: capture photo → send to backend → speak TTS → wait → repeat
   * Until: backend returns navigation: false OR user taps to interrupt
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

    console.log('🔄 [NavLoop] Starting navigation loop');
    isNavigationLoopRunning.current = true;
    navigationLoopAbortRef.current = false;

    setIsNavigation(true);
    AccessibilityInfo.announceForAccessibility('Navigation started. Tap to stop.');

    while (!navigationLoopAbortRef.current && !isEmergencyStopped.current) {
      // Check for infinite loop prevention
      if (shouldPreventInfiniteLoop()) {
        console.log('🔄 [NavLoop] Stopping due to safety limits');
        AccessibilityInfo.announceForAccessibility('Navigation stopped due to time limit.');
        break;
      }

      try {
        incrementNavigationLoop();

        // Step 1: Wait for the configured delay
        const delay = getCurrentLoopDelay();
        console.log(`🔄 [NavLoop] Waiting ${delay}ms before next iteration`);
        await new Promise(resolve => setTimeout(resolve, delay));

        // Check if aborted during delay
        if (navigationLoopAbortRef.current || isEmergencyStopped.current) {
          console.log('🔄 [NavLoop] Aborted during delay');
          break;
        }

        // Step 2: Capture photo
        console.log('🔄 [NavLoop] Capturing photo...');
        const photoPath = await reactivateCameraAndCapture();

        if (!photoPath) {
          console.warn('🔄 [NavLoop] Failed to capture photo, continuing with voice-only');
        }

        // Check if aborted after photo capture
        if (navigationLoopAbortRef.current || isEmergencyStopped.current) {
          console.log('🔄 [NavLoop] Aborted after photo capture');
          break;
        }

        // Step 3: Send to backend with navigation=true and empty transcript
        console.log('🔄 [NavLoop] Sending to backend...');
        setIsProcessing(true);

        const abortController = new AbortController();
        abortControllerRef.current = abortController;

        const result = await sendToWorkflow(
          { text: '', imageUri: photoPath || '', navigation: true },
          abortController.signal
        );

        setIsProcessing(false);

        // Check if aborted after backend response
        if (navigationLoopAbortRef.current || isEmergencyStopped.current) {
          console.log('🔄 [NavLoop] Aborted after backend response');
          break;
        }

        console.log('🔄 [NavLoop] Backend response:', {
          text: result.text.substring(0, 50),
          navigation: result.navigation,
          loopDelay: result.loopDelay,
        });

        // Update loop delay if backend provided one
        if (result.loopDelay) {
          updateLoopDelay(result.loopDelay);
        }

        // Step 4: Check if backend wants to stop the loop
        if (!result.navigation) {
          console.log('🔄 [NavLoop] Backend signaled to stop (navigation: false)');

          // Speak the final response
          if (result.text) {
            setIsSpeaking(true);
            await speachesSentenceChunker.synthesizeSpeechChunked(result.text);
            setIsSpeaking(false);
          }

          AccessibilityInfo.announceForAccessibility('Navigation complete.');
          break;
        }

        // Step 5: Speak the TTS response
        if (result.text && !navigationLoopAbortRef.current && !isEmergencyStopped.current) {
          console.log('🔄 [NavLoop] Speaking response...');
          setIsSpeaking(true);
          await speachesSentenceChunker.synthesizeSpeechChunked(result.text);
          setIsSpeaking(false);

          // Small buffer after TTS completes
          await new Promise(resolve => setTimeout(resolve, TTS_COMPLETION_BUFFER_MS));
        }

      } catch (error: any) {
        console.error('🔄 [NavLoop] Error in iteration:', error);

        // Don't break on cancelled requests (user interrupt)
        if (error.message?.includes('cancel')) {
          console.log('🔄 [NavLoop] Request was cancelled');
          break;
        }

        // For other errors, announce and break
        AccessibilityInfo.announceForAccessibility(`Navigation error: ${error.message}`);
        break;
      }
    }

    // Cleanup
    console.log('🔄 [NavLoop] Loop ended');
    isNavigationLoopRunning.current = false;
    stopNavigationLoop('loop ended');
    setIsNavigation(false);
    setIsProcessing(false);
    setIsSpeaking(false);
    setIsCameraActive(true);

    audioFeedback.playEarcon('ready');
    AccessibilityInfo.announceForAccessibility('Ready. Tap to speak.');

  }, []);

  /**
   * Stop the navigation loop (called when user taps during navigation)
   */
  const stopNavigation = useCallback(async () => {
    console.log('🛑 Stopping navigation loop');
    navigationLoopAbortRef.current = true;

    // Cancel any pending request
    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
      abortControllerRef.current = null;
    }

    // Stop TTS
    await speachesSentenceChunker.stop();

    // Update state
    stopNavigationLoop('user interrupt');
    setIsNavigation(false);
    setIsProcessing(false);
    setIsSpeaking(false);
    isNavigationLoopRunning.current = false;

    // Re-enable camera
    setIsCameraActive(true);

    audioFeedback.playEarcon('cancel');
    AccessibilityInfo.announceForAccessibility('Navigation stopped. Tap to speak.');
  }, []);


  /**
 * Continuous loop (navigation OR reaching)
 * 
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

    console.log('🔄 [ContinuousMode] Starting loop');
    isContinuousModeRunning.current = true;
    continuousModeAbortRef.current = false;

    const currentMode = getCurrentMode();
    AccessibilityInfo.announceForAccessibility(`${currentMode} started. Tap to stop.`);

    while (!continuousModeAbortRef.current && !isEmergencyStopped.current) {
      // Safety check
      if (shouldPreventInfiniteLoop()) {
        console.log('🔄 [ContinuousMode] Stopping due to safety limits');
        AccessibilityInfo.announceForAccessibility('Stopped due to time limit.');
        break;
      }

      try {
        incrementContinuousMode();

        // Wait for delay
        const delay = getCurrentLoopDelay();
        console.log(`🔄 [ContinuousMode] Waiting ${delay}ms before next iteration`);
        await new Promise(resolve => setTimeout(resolve, delay));

        if (continuousModeAbortRef.current || isEmergencyStopped.current) {
          console.log('🔄 [ContinuousMode] Aborted during delay');
          break;
        }

        // Capture photo
        console.log('🔄 [ContinuousMode] Capturing photo...');
        const photoPath = await reactivateCameraAndCapture();

        if (!photoPath) {
          console.warn('🔄 [ContinuousMode] Failed to capture photo, continuing with voice-only');
        }

        if (continuousModeAbortRef.current || isEmergencyStopped.current) {
          console.log('🔄 [ContinuousMode] Aborted after photo capture');
          break;
        }

        // ======================================================================
        // Send request with CURRENT mode flags
        // ======================================================================
        console.log('🔄 [ContinuousMode] Sending to backend...');
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

        setIsProcessing(false);

        if (continuousModeAbortRef.current || isEmergencyStopped.current) {
          console.log('🔄 [ContinuousMode] Aborted after backend response');
          break;
        }

        console.log('🔄 [ContinuousMode] Backend response:', {
          text: result.text.substring(0, 50),
          navigation: result.navigation,
          reaching_flag: result.reaching_flag,
          loopDelay: result.loopDelay,
        });

        // Update loop delay if provided
        if (result.loopDelay) {
          updateLoopDelay(result.loopDelay);
        }

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

        // Speak the response
        if (result.text && !continuousModeAbortRef.current && !isEmergencyStopped.current) {
          console.log('🔄 [ContinuousMode] Speaking response...');
          setIsSpeaking(true);
          await speachesSentenceChunker.synthesizeSpeechChunked(result.text);
          setIsSpeaking(false);

          // Small buffer after TTS
          await new Promise(resolve => setTimeout(resolve, TTS_COMPLETION_BUFFER_MS));
        }

      } catch (error: any) {
        console.error('🔄 [ContinuousMode] Error in iteration:', error);

        // Don't break on cancelled requests
        if (error.message?.includes('cancel')) {
          console.log('🔄 [ContinuousMode] Request was cancelled');
          break;
        }

        // For other errors, announce and break
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
  setIsProcessing(true);
  isProcessingRef.current = true;
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

    console.log('✅ Audio session wait complete');  // NEW LOG

    if (isEmergencyStopped.current) {
      console.log('⚠️ Emergency stopped during wait');
      setIsProcessing(false);
      isProcessingRef.current = false;
      isCapturingPhotoRef.current = false;
      return;
    }

    console.log('📷 About to call reactivateCameraAndCapture...');  // NEW LOG

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
      isProcessingRef.current = false;
      isCapturingPhotoRef.current = false;
      return;
    }

    console.log('📤 About to call handleVoiceCommand...');  // NEW LOG
    await handleVoiceCommand(finalText, photoPath);
    console.log('✅ handleVoiceCommand complete');  // NEW LOG

  } catch (error) {
    console.error('❌ Auto-submit error:', error);
    console.error('❌ Error stack:', error.stack);  // NEW: Full stack trace
    AccessibilityInfo.announceForAccessibility(`Error: ${error.message || error}`);
    setIsProcessing(false);
    isProcessingRef.current = false;
  } finally {
    isCapturingPhotoRef.current = false;
    console.log('✅ Auto-submit finally block complete');  // NEW LOG
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

      await new Promise(resolve => setTimeout(resolve, 100));
      await startSTT();
      console.log('✅ Voice recognition started');
      await audioFeedback.announceState('listening', false);
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

    const abortController = new AbortController();
    abortControllerRef.current = abortController;

    try {
      console.log('⚡ Processing:', command);
      isProcessingRef.current = true;
      setIsProcessing(true);

      try { await cancelSTT(); } catch (e) { }

      audioFeedback.playEarcon('thinking');
      playSound('processing');
      audioFeedback.announceState('thinking', false);

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
          navigation: false,          // Initial request
          reaching_flag: false         // Initial request
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

        // Set up loop state
        startContinuousMode(mode, result.loopDelay);

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