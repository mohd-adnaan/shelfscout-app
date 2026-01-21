/**
 * App.tsx - FIXED VERSION v2
 * 
 * FIXES:
 * 1. Single tap to interrupt (removed double-tap requirement)
 * 2. Proper request cancellation using AbortController
 * 3. Emergency stop now cancels in-flight HTTP requests
 * 4. Old responses won't play after starting new query
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
  findNodeHandle,
} from 'react-native';
import { Camera, useCameraDevice, useCameraPermission, useMicrophonePermission } from 'react-native-vision-camera';
import { useTTS } from './src/hooks/useTTS';
import { useSTT } from './src/hooks/useSTT_Enhanced';
import { sendToWorkflow } from './src/services/WorkflowService';
import { VoiceVisualizer } from './src/components/VoiceVisualizer';
import { playSound } from './src/utils/soundEffects';
import { audioFeedback } from './src/services/AudioFeedbackService';
import { speachesSentenceChunker } from './src/services/SpeachesSentenceChunker';

const { width, height } = Dimensions.get('window');

function App(): React.JSX.Element {
  // ============================================================================
  // State Management
  // ============================================================================
  const [isProcessing, setIsProcessing] = useState(false);
  const [isSpeaking, setIsSpeaking] = useState(false);
  const [screenReaderEnabled, setScreenReaderEnabled] = useState(false);
  const [reduceMotionEnabled, setReduceMotionEnabled] = useState(false);

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
  // Internal State Management
  // ============================================================================
  const isEmergencyStopped = useRef(false);
  const isProcessingRef = useRef(false);
  const finalTranscriptRef = useRef('');
  
  // ✅ NEW: AbortController for cancelling HTTP requests
  const abortControllerRef = useRef<AbortController | null>(null);
  
  // ✅ REMOVED: lastTapRef (no longer needed - single tap only)
  const previousStateRef = useRef<string>('');

  // ============================================================================
  // Auto-Submit Handler
  // ============================================================================
  
  /**
   * Handle automatic submission when silence is detected
   * This is called by useSTT when user stops speaking
   */
  const handleAutoSubmit = useCallback(async () => {
    console.log('🎯 Auto-submit triggered by silence detection');
    
    // Capture photo and process
    try {
      console.log('📸 Capturing photo after silence detected...');

      let photoPath = '';
      if (cameraRef.current) {
        try {
          const photo = await cameraRef.current.takePhoto({
            qualityPrioritization: 'speed',
            enableShutterSound: true,
          });
          photoPath = photo.path;
          console.log('✅ Photo captured:', photoPath);
          
          audioFeedback.playEarcon('success');
        } catch (photoError) {
          console.error('❌ Photo capture failed:', photoError);
          
          AccessibilityInfo.announceForAccessibility(
            'Warning: Failed to capture photo. Continuing with voice command only.'
          );
          
          photoPath = '';
        }
      }

      // Get current transcript
      const finalText = finalTranscriptRef.current.trim();
      
      if (finalText && !isProcessingRef.current && !isEmergencyStopped.current) {
        AccessibilityInfo.announceForAccessibility('Processing your request');
        await handleVoiceCommand(finalText, photoPath);
      } else if (!finalText) {
        AccessibilityInfo.announceForAccessibility(
          'No voice input detected. Tap to try again.'
        );
        
        audioFeedback.playEarcon('error');
      }
    } catch (error) {
      console.error('❌ Auto-submit error:', error);
      
      const errorMessage = error instanceof Error 
        ? error.message 
        : 'Failed to process voice command';
      
      AccessibilityInfo.announceForAccessibility(
        `Error: ${errorMessage}`
      );
    }
  }, []);

  // ============================================================================
  // STT Hook with Auto-Submit
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
  // Animation Values (respect reduce motion)
  // ============================================================================
  const pulseAnim = useRef(new Animated.Value(1)).current;
  const opacityAnim = useRef(new Animated.Value(0.3)).current;

  // ============================================================================
  // WCAG 2.3.3 & 1.4.13: Check Accessibility Preferences
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
        
        console.log('♿ Accessibility:', {
          screenReader: isScreenReaderOn,
          reduceMotion: isReduceMotionOn,
        });

        if (isScreenReaderOn) {
          setTimeout(() => {
            AccessibilityInfo.announceForAccessibility(
              'CyberSight activated. Tap anywhere to start speaking. Speak your question naturally - the app will detect when you finish. Tap to interrupt.'
            );
          }, 1000);
        }
      } catch (error) {
        console.error('❌ Accessibility check error:', error);
      }
    };

    checkAccessibilityPreferences();

    const screenReaderSubscription = AccessibilityInfo.addEventListener(
      'screenReaderChanged',
      setScreenReaderEnabled
    );
    
    const reduceMotionSubscription = AccessibilityInfo.addEventListener(
      'reduceMotionChanged',
      setReduceMotionEnabled
    );

    return () => {
      screenReaderSubscription?.remove();
      reduceMotionSubscription?.remove();
    };
  }, []);

  // ============================================================================
  // WCAG 3.3.1: Request Android Permissions with Error Handling
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
            const missingPermissions = [];
            if (!audioGranted) missingPermissions.push('Microphone');
            if (!cameraGranted) missingPermissions.push('Camera');
            
            const errorMessage = `${missingPermissions.join(' and ')} permission required for CyberSight to function.`;
            
            AccessibilityInfo.announceForAccessibility(
              `Error: ${errorMessage} Please grant permissions in your device settings.`
            );
            
            Alert.alert(
              'Permissions Required',
              errorMessage + ' Please enable them in your device settings.',
              [{ text: 'OK', style: 'default' }]
            );
          }
        } catch (err) {
          console.warn('❌ Permission error:', err);
          
          AccessibilityInfo.announceForAccessibility(
            'Error requesting permissions. Please try again or check your device settings.'
          );
        }
      }
    };

    requestAndroidPermissions();
  }, []);

  // ============================================================================
  // Request iOS/General Permissions
  // ============================================================================
  useEffect(() => {
    const requestPermissions = async () => {
      try {
        if (!hasCameraPermission) {
          const granted = await requestCameraPermission();
          if (!granted) {
            AccessibilityInfo.announceForAccessibility(
              'Camera permission denied. CyberSight needs camera access to function.'
            );
          }
        }
        if (!hasMicPermission) {
          const granted = await requestMicPermission();
          if (!granted) {
            AccessibilityInfo.announceForAccessibility(
              'Microphone permission denied. CyberSight needs microphone access to function.'
            );
          }
        }
      } catch (error) {
        console.error('❌ Permission request error:', error);
        AccessibilityInfo.announceForAccessibility(
          'Error requesting permissions. Please check your device settings.'
        );
      }
    };

    requestPermissions();
  }, [hasCameraPermission, hasMicPermission]);

  // ============================================================================
  // Sync transcript to ref
  // ============================================================================
  useEffect(() => {
    if (transcript) {
      finalTranscriptRef.current = transcript;
    }
  }, [transcript]);

  // ============================================================================
  // WCAG 2.3.3: Animation respects reduce motion preference
  // ============================================================================
  useEffect(() => {
    if (isListening && !reduceMotionEnabled) {
      Animated.loop(
        Animated.sequence([
          Animated.parallel([
            Animated.timing(pulseAnim, {
              toValue: 1.3,
              duration: 1000,
              useNativeDriver: true,
            }),
            Animated.timing(opacityAnim, {
              toValue: 0.8,
              duration: 1000,
              useNativeDriver: true,
            }),
          ]),
          Animated.parallel([
            Animated.timing(pulseAnim, {
              toValue: 1,
              duration: 1000,
              useNativeDriver: true,
            }),
            Animated.timing(opacityAnim, {
              toValue: 0.3,
              duration: 1000,
              useNativeDriver: true,
            }),
          ]),
        ])
      ).start();
    } else {
      Animated.parallel([
        Animated.timing(pulseAnim, {
          toValue: 1,
          duration: 300,
          useNativeDriver: true,
        }),
        Animated.timing(opacityAnim, {
          toValue: 0.3,
          duration: 300,
          useNativeDriver: true,
        }),
      ]).start();
    }
  }, [isListening, reduceMotionEnabled]);

  // ============================================================================
  // WCAG 4.1.3: Announce state changes to screen reader
  // ============================================================================
  useEffect(() => {
    const currentState = getStateDescription();
    
    if (currentState !== previousStateRef.current && previousStateRef.current !== '') {
      if (isProcessing && !previousStateRef.current.includes('processing')) {
        // Thinking state is announced by VoiceVisualizer
      } else if (isSpeaking && !previousStateRef.current.includes('speaking')) {
        // Speaking state is announced by VoiceVisualizer
      }
    }
    
    previousStateRef.current = currentState;
  }, [isListening, isProcessing, isSpeaking]);

  // ============================================================================
  // Helper: Get state description for announcements
  // ============================================================================
  const getStateDescription = () => {
    if (isSpeaking) return 'speaking';
    if (isProcessing) return 'processing';
    if (isListening) return 'listening';
    return 'ready';
  };

  // ============================================================================
  // Helper: Get accessibility label for container
  // ============================================================================
  const getAccessibilityLabel = () => {
    const state = getStateDescription();
    
    if (isSpeaking) {
      return 'CyberSight is speaking. Tap anywhere to interrupt.';
    }
    if (isProcessing) {
      return 'CyberSight is processing your request. Tap anywhere to interrupt.';
    }
    if (isListening) {
      return `CyberSight is listening. ${transcript ? `You said: ${transcript}. ` : ''}Speak your question - the app will automatically detect when you finish. Or tap to stop now.`;
    }
    return 'CyberSight is ready. Tap anywhere to start speaking.';
  };

  // ============================================================================
  // Helper: Get accessibility hint
  // ============================================================================
  const getAccessibilityHint = () => {
    if (isSpeaking || isProcessing) {
      return 'Tap to stop and return to ready state';
    }
    if (isListening) {
      return 'Speak naturally. App will detect when you finish speaking and process automatically. Tap to stop immediately.';
    }
    return 'Tap once to start speaking your question to CyberSight';
  };

  // ============================================================================
  // WCAG 3.3.1: Request microphone permission with error handling
  // ============================================================================
  const requestMicrophonePermission = async () => {
    if (Platform.OS === 'android') {
      try {
        const granted = await PermissionsAndroid.request(
          PermissionsAndroid.PERMISSIONS.RECORD_AUDIO,
          {
            title: 'Microphone Permission',
            message: 'CyberSight needs access to your microphone for voice commands',
            buttonNeutral: 'Ask Me Later',
            buttonNegative: 'Cancel',
            buttonPositive: 'OK',
          }
        );
        
        if (granted === PermissionsAndroid.RESULTS.GRANTED) {
          console.log('🎤 Microphone permission granted');
          return true;
        } else {
          console.log('❌ Microphone permission denied');
          
          AccessibilityInfo.announceForAccessibility(
            'Microphone permission denied. CyberSight cannot record your voice without microphone access.'
          );
          return false;
        }
      } catch (err) {
        console.warn('❌ Permission error:', err);
        
        AccessibilityInfo.announceForAccessibility(
          'Error requesting microphone permission. Please check your device settings.'
        );
        return false;
      }
    }
    return true;
  };

  // ============================================================================
  // Start Listening Function
  // ============================================================================
  const startListening = async () => {
    try {
      const hasPermission = await requestMicrophonePermission();
      if (!hasPermission) {
        Alert.alert(
          'Permission Required',
          'Microphone access is required for voice commands. Please enable it in your device settings.',
          [{ text: 'OK', style: 'default' }]
        );
        return;
      }

      // ✅ NEW: Reset emergency stop flag
      isEmergencyStopped.current = false;

      await stopTTS();
      finalTranscriptRef.current = '';

      audioFeedback.playEarcon('listening');
      playSound('start');

      await new Promise(resolve => setTimeout(resolve, 100));
      await startSTT();
      console.log('✅ Voice recognition started with auto-submit');

      await audioFeedback.announceState('listening', false);

    } catch (error) {
      console.error('❌ Start listening error:', error);
      
      const errorMessage = error instanceof Error 
        ? error.message 
        : 'Failed to start voice recognition';
      
      AccessibilityInfo.announceForAccessibility(
        `Error: ${errorMessage}. Please try again.`
      );
      
      Alert.alert(
        'Voice Recognition Error',
        errorMessage + '. Please try again.',
        [{ text: 'OK', style: 'default' }]
      );
    }
  };

  // ============================================================================
  // Manual Stop (if user taps while listening)
  // ============================================================================
  const stopListeningManually = async () => {
    try {
      console.log('🛑 Manual stop requested');
      
      const finalTranscript = await stopSTT();
      console.log('📝 Manual stop - Final transcript:', finalTranscript);

      const finalText = finalTranscript.trim();
      if (finalText && !isProcessingRef.current && !isEmergencyStopped.current) {
        let photoPath = '';
        if (cameraRef.current) {
          try {
            const photo = await cameraRef.current.takePhoto({
              qualityPrioritization: 'speed',
              enableShutterSound: true,
            });
            photoPath = photo.path;
            console.log('✅ Photo captured (manual):', photoPath);
            audioFeedback.playEarcon('success');
          } catch (photoError) {
            console.error('❌ Photo capture failed:', photoError);
            photoPath = '';
          }
        }
        
        await handleVoiceCommand(finalText, photoPath);
      } else if (!finalText) {
        AccessibilityInfo.announceForAccessibility(
          'No voice input detected. Tap to try again.'
        );
        
        audioFeedback.playEarcon('error');
      }
    } catch (error) {
      console.error('❌ Manual stop error:', error);
    }
  };

  // ============================================================================
  // Handle Voice Command
  // ============================================================================
  const handleVoiceCommand = async (command: string, photoPath: string) => {
    if (isProcessingRef.current || isEmergencyStopped.current) {
      console.log('⚠️ Blocked - processing or emergency stopped');
      return;
    }

    // ✅ NEW: Create AbortController for this request
    const abortController = new AbortController();
    abortControllerRef.current = abortController;

    try {
      console.log('⚡ Processing command:', command);
      isProcessingRef.current = true;
      setIsProcessing(true);
      
      await cancelSTT();
      console.log('🛑 STT stopped to prevent TTS feedback');
      
      audioFeedback.playEarcon('thinking');
      playSound('processing');
      
      audioFeedback.announceState('thinking', false);

      if (!photoPath) {
        console.warn('⚠️ No photo available - continuing with voice-only mode');
        AccessibilityInfo.announceForAccessibility(
          'Processing voice command without photo.'
        );
      }

      // ✅ CRITICAL: Check if stopped before network request
      if (isEmergencyStopped.current) {
        console.log('⚠️ Emergency stopped before request');
        return;
      }

      console.log('📤 Sending to N8N workflow...');
      
      // ✅ NEW: Pass abort signal to sendToWorkflow
      const result = await sendToWorkflow(
        {
          text: command,
          imageUri: photoPath || '',
        },
        abortController.signal // Pass abort signal
      );

      // ✅ CRITICAL: Check if stopped after network request
      if (isEmergencyStopped.current) {
        console.log('⚠️ Emergency stopped - discarding response');
        return;
      }

      console.log('✅ N8N Response received:', result.text.substring(0, 50) + '...');
      
      // Transition to speaking
      setIsProcessing(false);
      setIsSpeaking(true);
      
      audioFeedback.playEarcon('speaking');
      
      // ✅ CRITICAL: Check again before TTS
      if (isEmergencyStopped.current) {
        console.log('⚠️ Emergency stopped - not speaking');
        return;
      }
      
      await speachesSentenceChunker.synthesizeSpeechChunked(result.text);
      
      // ✅ CRITICAL: Check after TTS complete
      if (isEmergencyStopped.current) {
        console.log('⚠️ Emergency stopped after TTS');
        return;
      }
      
      setIsSpeaking(false);
      finalTranscriptRef.current = '';
      
      audioFeedback.playEarcon('ready');
      
      AccessibilityInfo.announceForAccessibility(
        'Response complete. CyberSight is ready. Tap to speak.'
      );
      
    } catch (error: any) {
      // ✅ NEW: Check if error is due to abort
      if (error.name === 'AbortError' || error.message?.includes('aborted')) {
        console.log('✅ Request cancelled successfully');
        return;
      }
      
      if (!isEmergencyStopped.current) {
        console.error('❌ Error:', error);
        
        const errorMessage = error instanceof Error 
          ? error.message 
          : 'An unknown error occurred';
        
        const userMessage = errorMessage.includes('Network') 
          ? 'Network error. Please check your internet connection and try again.'
          : errorMessage.includes('timeout')
          ? 'Request timed out. The server took too long to respond. Please try again.'
          : `Error: ${errorMessage}. Please try again.`;
        
        await audioFeedback.announceError(userMessage, true);
        
        Alert.alert(
          'Error Processing Request',
          userMessage,
          [{ text: 'OK', style: 'default' }]
        );
      }
    } finally {
      setIsProcessing(false);
      isProcessingRef.current = false;
      finalTranscriptRef.current = '';
      
      // ✅ NEW: Clear abort controller
      abortControllerRef.current = null;
    }
  };

  // ============================================================================
  // Emergency Stop Function (Single Tap)
  // ============================================================================
  const emergencyStop = async () => {
    console.log('🚨 EMERGENCY STOP (Single Tap)');
    
    // ✅ NEW: Set flag FIRST to prevent any ongoing operations
    isEmergencyStopped.current = true;
    
    // ✅ NEW: Cancel in-flight HTTP request
    if (abortControllerRef.current) {
      console.log('🛑 Cancelling in-flight HTTP request');
      abortControllerRef.current.abort();
      abortControllerRef.current = null;
    }
    
    // Stop sentence chunker
    await speachesSentenceChunker.stop();
    
    // Cancel STT
    try {
      await cancelSTT();
    } catch (e) {
      console.warn('⚠️ Error canceling STT:', e);
    }
    
    await new Promise(resolve => setTimeout(resolve, 300));
    
    // Reset state
    setIsProcessing(false);
    setIsSpeaking(false);
    isProcessingRef.current = false;
    finalTranscriptRef.current = '';
    
    // ✅ NEW: Clear emergency flag AFTER cleanup
    isEmergencyStopped.current = false;
    
    audioFeedback.playEarcon('ready');
    
    AccessibilityInfo.announceForAccessibility(
      'Stopped. CyberSight is ready. Tap to speak.'
    );
    
    console.log('✅ Emergency stop complete');
  };

  // ============================================================================
  // ✅ NEW: Handle Screen Tap (Single Tap Only)
  // ============================================================================
  const handleScreenTap = async () => {
    console.log('👆 SINGLE TAP');
    
    // ✅ NEW: Single tap = immediate stop when busy
    if (isSpeaking || isProcessing) {
      console.log('🛑 Busy - stopping immediately (single tap)');
      
      AccessibilityInfo.announceForAccessibility('Stopping.');
      
      await emergencyStop();
      return;
    }

    if (isListening) {
      console.log('🛑 Manual stop while listening');
      
      AccessibilityInfo.announceForAccessibility('Stopping and processing now.');
      
      await stopListeningManually();
      return;
    }

    console.log('🎤 Start listening (with auto-submit)');
    
    await startListening();
  };

  // ============================================================================
  // WCAG 3.3.2: Handle permission denied state
  // ============================================================================
  if (!hasCameraPermission || !device) {
    return (
      <View 
        style={styles.container}
        accessible={true}
        accessibilityLabel="CyberSight is waiting for camera permission. Please grant camera access to continue."
        accessibilityRole="none"
      >
        <StatusBar barStyle="light-content" backgroundColor="#000" />
      </View>
    );
  }

  // ============================================================================
  // Main Render
  // ============================================================================
  return (
    <TouchableWithoutFeedback 
      onPress={handleScreenTap}
      accessible={true}
      accessibilityLabel={getAccessibilityLabel()}
      accessibilityHint={getAccessibilityHint()}
      accessibilityRole="button"
      accessibilityLiveRegion="polite"
      accessibilityState={{
        busy: isProcessing,
        disabled: false,
      }}
    >
      <View 
        ref={containerRef}
        style={styles.container}
        accessible={false}
        importantForAccessibility="no-hide-descendants"
      >
        <StatusBar barStyle="light-content" backgroundColor="#000" />

        <Camera
          ref={cameraRef}
          style={StyleSheet.absoluteFill}
          device={device}
          isActive={true}
          photo={true}
          accessible={false}
          accessibilityElementsHidden={true}
        />

        <View 
          style={styles.darkOverlay}
          accessible={false}
          importantForAccessibility="no-hide-descendants"
        />

        <VoiceVisualizer
          isListening={isListening}
          isProcessing={isProcessing}
          isSpeaking={isSpeaking}
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



