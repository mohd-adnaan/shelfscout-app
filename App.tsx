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
  const [isProcessing, setIsProcessing] = useState(false);
  const [isSpeaking, setIsSpeaking] = useState(false);

  const device = useCameraDevice('back');
  const { hasPermission: hasCameraPermission, requestPermission: requestCameraPermission } = useCameraPermission();
  const { hasPermission: hasMicPermission, requestPermission: requestMicPermission } = useMicrophonePermission();

  const cameraRef = useRef<Camera>(null);
  const { speak, stop: stopTTS } = useTTS();
  
  // Platform-specific STT hook
  const { 
    startListening: startSTT, 
    stopListening: stopSTT, 
    cancelListening: cancelSTT,
    isListening, 
    transcript 
  } = useSTT();

  const pulseAnim = useRef(new Animated.Value(1)).current;
  const opacityAnim = useRef(new Animated.Value(0.3)).current;

  const isEmergencyStopped = useRef(false);
  const isProcessingRef = useRef(false);
  const finalTranscriptRef = useRef('');

  const lastTapRef = useRef(0);
  const DOUBLE_TAP_DELAY = 300;

  // Sync transcript to ref for access in other functions
  useEffect(() => {
    if (transcript) {
      finalTranscriptRef.current = transcript;
    }
  }, [transcript]);

  useEffect(() => {
    const requestAndroidPermissions = async () => {
      if (Platform.OS === 'android') {
        try {
          await PermissionsAndroid.requestMultiple([
            PermissionsAndroid.PERMISSIONS.RECORD_AUDIO,
            PermissionsAndroid.PERMISSIONS.CAMERA,
          ]);
        } catch (err) {
          console.warn('Permission error:', err);
        }
      }
    };

    requestAndroidPermissions();
  }, []);

  useEffect(() => {
    const requestPermissions = async () => {
      if (!hasCameraPermission) {
        await requestCameraPermission();
      }
      if (!hasMicPermission) {
        await requestMicPermission();
      }
    };

    requestPermissions();
  }, [hasCameraPermission, hasMicPermission]);

  useEffect(() => {
    if (isListening) {
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
  }, [isListening]);

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
          return false;
        }
      } catch (err) {
        console.warn('❌ Permission error:', err);
        return false;
      }
    }
    return true;
  };

  const startListening = async () => {
    try {
      const hasPermission = await requestMicrophonePermission();
      if (!hasPermission) {
        Alert.alert('Permission Required', 'Microphone access is required for voice commands');
        return;
      }

      isEmergencyStopped.current = false;

      await stopTTS();
      finalTranscriptRef.current = '';

      audioFeedback.playEarcon('listening');
      playSound('start');

      await startSTT();
      console.log('✅ Voice recognition started');

      await audioFeedback.announceState('listening', false);

    } catch (error) {
      console.error('❌ Start listening error:', error);
    }
  };

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
        } catch (photoError) {
          console.error('❌ Photo error:', photoError);
        }
      }

      const finalTranscript = await stopSTT();
      console.log('🛑 Voice recognition stopped');
      console.log('📝 Final transcript:', finalTranscript);

      const finalText = finalTranscript.trim();
      if (finalText && !isProcessingRef.current && !isEmergencyStopped.current) {
        await handleVoiceCommand(finalText, photoPath);
      }
    } catch (error) {
      console.error('❌ Stop listening error:', error);
    }
  };

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
      
      audioFeedback.announceState('thinking', false);

      if (!photoPath) {
        throw new Error('No photo available');
      }

      if (isEmergencyStopped.current) {
        console.log('⚠️ Emergency stopped before request');
        return;
      }

      // Send to N8N (gets full text response)
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
      
      // ✅ SENTENCE-BY-SENTENCE TTS - Fast perceived response
      // Splits response into chunks and plays them sequentially
      // First chunk starts playing immediately
      await speachesSentenceChunker.synthesizeSpeechChunked(result.text);
      
      setIsSpeaking(false);
      
      audioFeedback.playEarcon('ready');
      
    } catch (error) {
      if (!isEmergencyStopped.current) {
        console.error('❌ Error:', error);
        await audioFeedback.announceError('Error processing request', true);
        Alert.alert('Error', 'Failed to process');
      }
    } finally {
      setIsProcessing(false);
      isProcessingRef.current = false;
    }
  };

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
    
    console.log('✅ Emergency stop complete');
  };

  const handleScreenTap = async () => {
    const now = Date.now();
    const timeSinceLastTap = now - lastTapRef.current;

    if (timeSinceLastTap < DOUBLE_TAP_DELAY) {
      console.log('👆👆 DOUBLE TAP');
      await emergencyStop();
      lastTapRef.current = 0;
      return;
    }

    lastTapRef.current = now;

    if (isSpeaking || isProcessing) {
      console.log('⚠️ Busy - double-tap to stop');
      return;
    }

    if (isListening) {
      console.log('🛑 Stop & process');
      await stopListeningAndProcess();
      return;
    }

    console.log('🎤 Start listening');
    await startListening();
  };

  if (!hasCameraPermission || !device) {
    return (
      <View style={styles.container}>
        <StatusBar barStyle="light-content" backgroundColor="#000" />
      </View>
    );
  }

  return (
    <TouchableWithoutFeedback onPress={handleScreenTap}>
      <View style={styles.container}>
        <StatusBar barStyle="light-content" backgroundColor="#000" />

        <Camera
          ref={cameraRef}
          style={StyleSheet.absoluteFill}
          device={device}
          isActive={true}
          photo={true}
        />

        <View style={styles.darkOverlay} />

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