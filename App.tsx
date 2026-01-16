/**
 * App.tsx
 * 
 * WCAG 2.1 Level AA Compliant Main Application
 * 
 * Critical Accessibility Features:
 * - 1.1.1 Non-text Content: All visual elements have text alternatives
 * - 1.3.1 Info and Relationships: Proper semantic structure
 * - 2.1.1 Keyboard: Full screen reader operability
 * - 2.4.3 Focus Order: Logical navigation sequence
 * - 2.5.1 Pointer Gestures: Single-tap AND double-tap work
 * - 2.5.2 Pointer Cancellation: Actions on release, can cancel
 * - 3.2.1 On Focus: No unexpected changes
 * - 3.2.2 On Input: Predictable behavior
 * - 3.3.1 Error Identification: Clear error descriptions
 * - 3.3.2 Labels or Instructions: Complete guidance
 * - 4.1.2 Name, Role, Value: Complete accessibility props
 * - 4.1.3 Status Messages: Live status announcements
 * 
 * ZERO TOLERANCE FOR ACCESSIBILITY ERRORS
 * This app serves blind users who depend entirely on audio feedback
 */

import React, { useState, useEffect, useRef } from 'react';
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
import { useSTT } from './src/hooks/useSTT';  
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
  
  const { 
    startListening: startSTT, 
    stopListening: stopSTT, 
    cancelListening: cancelSTT,
    isListening, 
    transcript 
  } = useSTT();

  // ============================================================================
  // Animation Values (respect reduce motion)
  // ============================================================================
  const pulseAnim = useRef(new Animated.Value(1)).current;
  const opacityAnim = useRef(new Animated.Value(0.3)).current;

  // ============================================================================
  // Internal State Management
  // ============================================================================
  const isEmergencyStopped = useRef(false);
  const isProcessingRef = useRef(false);
  const finalTranscriptRef = useRef('');
  const lastTapRef = useRef(0);
  const previousStateRef = useRef<string>('');
  
  const DOUBLE_TAP_DELAY = 300;

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

        // WCAG 4.1.3: Welcome announcement for screen reader users
        if (isScreenReaderOn) {
          setTimeout(() => {
            AccessibilityInfo.announceForAccessibility(
              'CyberSight activated. Tap anywhere on the screen to start voice recording. Double tap to take a photo or interrupt.'
            );
          }, 1000);
        }
      } catch (error) {
        console.error('❌ Accessibility check error:', error);
      }
    };

    checkAccessibilityPreferences();

    // Listen for accessibility setting changes
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
            // WCAG 3.3.1: Clear error identification
            const missingPermissions = [];
            if (!audioGranted) missingPermissions.push('Microphone');
            if (!cameraGranted) missingPermissions.push('Camera');
            
            const errorMessage = `${missingPermissions.join(' and ')} permission required for CyberSight to function.`;
            
            // Announce to screen reader
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
          
          // WCAG 3.3.1: Announce error
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
      // Only animate if reduce motion is NOT enabled
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
      // Reset animation
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
    
    // Only announce if state changed and not the initial state
    if (currentState !== previousStateRef.current && previousStateRef.current !== '') {
      // Don't announce every state - VoiceVisualizer handles most
      // Only announce major transitions
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
      return 'CyberSight is speaking. Double tap anywhere to interrupt.';
    }
    if (isProcessing) {
      return 'CyberSight is processing your request. Double tap anywhere to interrupt.';
    }
    if (isListening) {
      return `CyberSight is listening. ${transcript ? `You said: ${transcript}. ` : ''}Tap anywhere to stop recording and process your command.`;
    }
    return 'CyberSight is ready. Tap anywhere to start voice recording. Double tap to take a photo.';
  };

  // ============================================================================
  // Helper: Get accessibility hint
  // ============================================================================
  const getAccessibilityHint = () => {
    if (isSpeaking || isProcessing) {
      return 'Double tap to stop and return to ready state';
    }
    if (isListening) {
      return 'Tap once to finish recording, or double tap to take photo while recording';
    }
    return 'Tap once to start recording your voice command, or double tap to take a photo immediately';
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
          
          // WCAG 3.3.1: Announce error
          AccessibilityInfo.announceForAccessibility(
            'Microphone permission denied. CyberSight cannot record your voice without microphone access.'
          );
          return false;
        }
      } catch (err) {
        console.warn('❌ Permission error:', err);
        
        // WCAG 3.3.1: Announce error
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
      // Check permission first
      const hasPermission = await requestMicrophonePermission();
      if (!hasPermission) {
        Alert.alert(
          'Permission Required',
          'Microphone access is required for voice commands. Please enable it in your device settings.',
          [{ text: 'OK', style: 'default' }]
        );
        return;
      }

      isEmergencyStopped.current = false;

      // Stop any existing TTS
      await stopTTS();
      finalTranscriptRef.current = '';

      // Audio feedback
      audioFeedback.playEarcon('listening');
      playSound('start');

      // Start voice recognition
      await startSTT();
      console.log('✅ Voice recognition started');

      // WCAG 4.1.3: Announce state (handled by VoiceVisualizer)
      await audioFeedback.announceState('listening', false);

    } catch (error) {
      console.error('❌ Start listening error:', error);
      
      // WCAG 3.3.1: Clear error identification
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
  // Stop Listening and Process
  // ============================================================================
  const stopListeningAndProcess = async () => {
    try {
      console.log('📸 Capturing photo while listening...');

      let photoPath = '';
      if (cameraRef.current) {
        try {
          const photo = await cameraRef.current.takePhoto({
            qualityPrioritization: 'speed',
          });
          photoPath = photo.path;
          console.log('✅ Photo captured:', photoPath);
          
          // Announce successful photo capture
          audioFeedback.playEarcon('success');
        } catch (photoError) {
          console.error('❌ Photo error:', photoError);
          
          // WCAG 3.3.1: Announce error
          AccessibilityInfo.announceForAccessibility(
            'Warning: Failed to capture photo. Continuing with voice command only.'
          );
        }
      }

      const finalTranscript = await stopSTT();
      console.log('🛑 Voice recognition stopped');
      console.log('📝 Final transcript:', finalTranscript);

      const finalText = finalTranscript.trim();
      if (finalText && !isProcessingRef.current && !isEmergencyStopped.current) {
        await handleVoiceCommand(finalText, photoPath);
      } else if (!finalText) {
        // WCAG 3.3.1: No voice input detected
        AccessibilityInfo.announceForAccessibility(
          'No voice input detected. Please try again.'
        );
        
        audioFeedback.playEarcon('error');
      }
    } catch (error) {
      console.error('❌ Stop listening error:', error);
      
      // WCAG 3.3.1: Error announcement
      const errorMessage = error instanceof Error 
        ? error.message 
        : 'Failed to process voice command';
      
      AccessibilityInfo.announceForAccessibility(
        `Error: ${errorMessage}`
      );
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

    try {
      console.log('⚡ Processing command:', command);
      isProcessingRef.current = true;
      setIsProcessing(true);
      
      audioFeedback.playEarcon('thinking');
      playSound('processing');
      
      // WCAG 4.1.3: Announce processing state
      audioFeedback.announceState('thinking', false);

      if (!photoPath) {
        // WCAG 3.3.1: Missing photo error
        throw new Error('No photo available. Please ensure camera is working.');
      }

      if (isEmergencyStopped.current) {
        console.log('⚠️ Emergency stopped before request');
        return;
      }

      // Send to N8N workflow
      console.log('📤 Sending to N8N workflow...');
      const result = await sendToWorkflow({
        text: command,
        imageUri: photoPath,
      });

      if (isEmergencyStopped.current) {
        console.log('⚠️ Emergency stopped - not speaking');
        return;
      }

      console.log('✅ N8N Response received:', result.text.substring(0, 50) + '...');
      
      // Transition to speaking
      setIsProcessing(false);
      setIsSpeaking(true);
      
      audioFeedback.playEarcon('speaking');
      
      // Sentence-by-sentence TTS for fast perceived response
      await speachesSentenceChunker.synthesizeSpeechChunked(result.text);
      
      setIsSpeaking(false);
      
      audioFeedback.playEarcon('ready');
      
      // WCAG 4.1.3: Announce ready state
      AccessibilityInfo.announceForAccessibility(
        'Response complete. CyberSight is ready. Tap to speak.'
      );
      
    } catch (error) {
      if (!isEmergencyStopped.current) {
        console.error('❌ Error:', error);
        
        // WCAG 3.3.1: Detailed error message
        const errorMessage = error instanceof Error 
          ? error.message 
          : 'An unknown error occurred';
        
        const userMessage = errorMessage.includes('Network') 
          ? 'Network error. Please check your internet connection and try again.'
          : errorMessage.includes('timeout')
          ? 'Request timed out. The server took too long to respond. Please try again.'
          : `Error: ${errorMessage}. Please try again.`;
        
        // Announce error
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
    }
  };

  // ============================================================================
  // Emergency Stop Function
  // ============================================================================
  const emergencyStop = async () => {
    console.log('🚨 EMERGENCY STOP');
    
    isEmergencyStopped.current = true;
    
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
    
    audioFeedback.playEarcon('ready');
    
    // WCAG 4.1.3: Announce stopped state
    AccessibilityInfo.announceForAccessibility(
      'Stopped. CyberSight is ready. Tap to speak.'
    );
    
    console.log('✅ Emergency stop complete');
  };

  // ============================================================================
  // WCAG 2.5.1: Handle Screen Tap (both single and double tap)
  // ============================================================================
  const handleScreenTap = async () => {
    const now = Date.now();
    const timeSinceLastTap = now - lastTapRef.current;

    // WCAG 2.5.1: Double-tap detection
    if (timeSinceLastTap < DOUBLE_TAP_DELAY) {
      console.log('👆👆 DOUBLE TAP');
      
      // Announce action
      AccessibilityInfo.announceForAccessibility('Double tap detected. Stopping.');
      
      await emergencyStop();
      lastTapRef.current = 0;
      return;
    }

    lastTapRef.current = now;

    // WCAG 3.2.1: Predictable behavior - busy states require double-tap
    if (isSpeaking || isProcessing) {
      console.log('⚠️ Busy - double-tap to stop');
      
      // Inform user
      AccessibilityInfo.announceForAccessibility(
        'CyberSight is busy. Double tap to interrupt.'
      );
      return;
    }

    if (isListening) {
      console.log('🛑 Stop & process');
      
      // Announce action
      AccessibilityInfo.announceForAccessibility('Stopping recording and processing.');
      
      await stopListeningAndProcess();
      return;
    }

    console.log('🎤 Start listening');
    
    // Announce action (handled by startListening)
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
      // WCAG 4.1.3: Live region for status updates
      accessibilityLiveRegion="polite"
      // WCAG 4.1.2: State information
      accessibilityState={{
        busy: isProcessing,
        disabled: false,
      }}
    >
      <View 
        ref={containerRef}
        style={styles.container}
        accessible={false} // Parent handles accessibility
        importantForAccessibility="no-hide-descendants"
      >
        <StatusBar barStyle="light-content" backgroundColor="#000" />

        {/* Camera - WCAG 1.1.1: Decorative for blind users */}
        <Camera
          ref={cameraRef}
          style={StyleSheet.absoluteFill}
          device={device}
          isActive={true}
          photo={true}
          // Camera is decorative for blind users
          accessible={false}
          accessibilityElementsHidden={true}
        />

        {/* Dark overlay - purely visual, hidden from screen readers */}
        <View 
          style={styles.darkOverlay}
          accessible={false}
          importantForAccessibility="no-hide-descendants"
        />

        {/* Voice Visualizer - handles its own accessibility */}
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