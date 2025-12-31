import React, { useState, useEffect } from 'react';
import {
  View,
  StyleSheet,
  TouchableOpacity,
  Text,
  Alert,
  ActivityIndicator,
} from 'react-native';
import { Camera } from 'react-native-vision-camera';
import VoiceButton from '../components/VoiceButton';
import VisualFeedback from '../components/VisualFeedback';
import { useVoiceRecognition } from '../hooks/useVoiceRecognition';
import { useCamera } from '../hooks/useCamera';
import { useTTS } from '../hooks/useTTS';
import { sendToWorkflow } from '../services/WorkflowService';
import { requestPermissions } from '../services/PermissionService';
import { COLORS } from '../utils/constants';

const MainScreen: React.FC = () => {
  const [isRecording, setIsRecording] = useState(false);
  const [isProcessing, setIsProcessing] = useState(false);
  const [isSpeaking, setIsSpeaking] = useState(false);
  const [hasPermissions, setHasPermissions] = useState(false);
  const [currentTranscript, setCurrentTranscript] = useState('');
  
  const { startRecognition, stopRecognition, cancelRecognition } = useVoiceRecognition();
  const { device, cameraRef, capturePhoto } = useCamera();
  const { speak, stop: stopTTS } = useTTS();

  useEffect(() => {
    initializePermissions();
  }, []);

  const initializePermissions = async () => {
    const granted = await requestPermissions();
    setHasPermissions(granted);
    
    if (!granted) {
      Alert.alert(
        'Permissions Required',
        'ShelfScout needs microphone and camera access to function properly.'
      );
    }
  };

  const handlePress = async () => {
    if (!hasPermissions) {
      Alert.alert(
        'Permissions Required',
        'Please grant microphone and camera permissions to use ShelfScout.'
      );
      return;
    }

    // If currently speaking, stop TTS and return to ready state
    if (isSpeaking) {
      console.log('🛑 Tap during speaking - stopping TTS');
      await stopTTS();
      setIsSpeaking(false);
      return;
    }

    // If currently processing, ignore tap
    if (isProcessing) {
      console.log('⚠️ Ignoring tap - currently processing');
      return;
    }

    if (isRecording) {
      // Stop recording and process
      console.log('🛑 Stop & process');
      setIsRecording(false);
      await stopRecognition();
      if (currentTranscript) {
        await processVoiceCommand(currentTranscript);
      }
    } else {
      // Start recording
      console.log('🎤 Start listening');
      setIsRecording(true);
      setCurrentTranscript('');
      startRecognition(
        handleSpeechResult,
        handleSpeechError,
        () => console.log('🎤 Speech started'),
        () => console.log('🎤 Speech ended')
      );
    }
  };

  const handleDoubleTap = async () => {
    console.log('👆👆 DOUBLE TAP');
    
    // Emergency stop - works in any state
    if (isSpeaking) {
      console.log('🚨 EMERGENCY STOP - Stopping TTS');
      await stopTTS();
      setIsSpeaking(false);
      return;
    }

    if (isProcessing) {
      console.log('⚠️ Cannot interrupt during processing');
      return;
    }

    if (isRecording) {
      console.log('📸 Double tap while recording - capturing photo');
      try {
        await capturePhoto();
        console.log('✅ Photo captured during recording');
      } catch (error) {
        console.error('❌ Photo capture error:', error);
      }
    }
  };

  const handleSpeechResult = (transcript: string) => {
    console.log('📝 Transcript:', transcript);
    setCurrentTranscript(transcript);
  };

  const handleSpeechError = (error: any) => {
    console.error('❌ Speech error:', error);
    setIsRecording(false);
    
    // Only show alert if it's a real error, not "already started"
    if (!error?.error?.message?.includes('already started')) {
      Alert.alert('Error', 'Speech recognition failed. Please try again.');
    }
  };

  const processVoiceCommand = async (transcript: string) => {
    setIsProcessing(true);
    
    try {
      console.log('⚡ Processing command:', transcript);
      
      // Capture photo
      const photoUri = await capturePhoto();
      console.log('📸 Photo:', photoUri);
      
      // Send to backend
      const response = await sendToWorkflow({
        text: transcript,
        imageUri: photoUri,
      });

      console.log('✅ Response:', response.text.substring(0, 50) + '...');

      // Transition from processing to speaking
      setIsProcessing(false);
      setIsSpeaking(true);

      // Speak response
      if (response.text) {
        await speak(response.text);
        // Speaking finished naturally
        setIsSpeaking(false);
      } else {
        setIsSpeaking(false);
        Alert.alert('No Response', 'No response received from server');
      }
      
    } catch (error) {
      console.error('❌ Processing error:', error);
      setIsProcessing(false);
      setIsSpeaking(false);
      Alert.alert(
        'Error',
        'Failed to process request. Please check your internet connection and try again.'
      );
    } finally {
      setCurrentTranscript('');
    }
  };

  if (!device) {
    return (
      <View style={styles.loadingContainer}>
        <ActivityIndicator size="large" color={COLORS.PRIMARY} />
        <Text style={styles.loadingText}>Loading camera...</Text>
      </View>
    );
  }

  // Determine what to show
  const getStatusInfo = () => {
    if (isSpeaking) {
      return { text: 'Speaking...', color: COLORS.SPEAKING };
    }
    if (isProcessing) {
      return { text: 'Thinking...', color: COLORS.PROCESSING };
    }
    if (isRecording) {
      return { text: 'Listening...', color: COLORS.RECORDING };
    }
    return { text: 'Ready', color: COLORS.PRIMARY };
  };

  const statusInfo = getStatusInfo();

  return (
    <View style={styles.container}>
      <Camera
        ref={cameraRef}
        style={StyleSheet.absoluteFill}
        device={device}
        isActive={true}
        photo={true}
      />

      <VisualFeedback 
        isActive={isRecording || isProcessing || isSpeaking}
        isRecording={isRecording}
        isProcessing={isProcessing}
        isSpeaking={isSpeaking}
      />
      
      <View style={styles.buttonContainer}>
        <VoiceButton
          isRecording={isRecording}
          isProcessing={isProcessing}
          isSpeaking={isSpeaking}
          onPress={handlePress}
          onDoubleTap={handleDoubleTap}
        />
        
        <Text style={[styles.statusText, { color: statusInfo.color }]}>
          {statusInfo.text}
        </Text>

        {/* Show transcript while listening */}
        {isRecording && currentTranscript && (
          <View style={styles.transcriptContainer}>
            <Text style={styles.transcriptText}>{currentTranscript}</Text>
          </View>
        )}

        {/* Show instructions */}
        <Text style={styles.instructionText}>
          {isSpeaking || isProcessing
            ? 'Double-tap to interrupt'
            : isRecording
            ? 'Tap to stop & process'
            : 'Tap to speak'}
        </Text>
      </View>

      {!hasPermissions && (
        <TouchableOpacity
          style={styles.permissionButton}
          onPress={initializePermissions}
        >
          <Text style={styles.permissionText}>Grant Permissions</Text>
        </TouchableOpacity>
      )}
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: COLORS.BACKGROUND,
  },
  loadingContainer: {
    flex: 1,
    backgroundColor: COLORS.BACKGROUND,
    justifyContent: 'center',
    alignItems: 'center',
  },
  loadingText: {
    color: COLORS.WHITE,
    marginTop: 16,
    fontSize: 16,
  },
  buttonContainer: {
    position: 'absolute',
    bottom: 100,
    left: 0,
    right: 0,
    alignItems: 'center',
  },
  statusText: {
    fontSize: 24,
    fontWeight: '600',
    marginTop: 20,
  },
  transcriptContainer: {
    position: 'absolute',
    bottom: 200,
    left: 20,
    right: 20,
    backgroundColor: 'rgba(33, 150, 243, 0.2)',
    padding: 20,
    borderRadius: 15,
    borderLeftWidth: 4,
    borderLeftColor: COLORS.RECORDING,
  },
  transcriptText: {
    color: COLORS.WHITE,
    fontSize: 18,
    lineHeight: 24,
  },
  instructionText: {
    position: 'absolute',
    bottom: -40,
    color: '#999',
    fontSize: 14,
    textAlign: 'center',
  },
  permissionButton: {
    position: 'absolute',
    top: 60,
    alignSelf: 'center',
    backgroundColor: COLORS.PRIMARY,
    paddingHorizontal: 20,
    paddingVertical: 10,
    borderRadius: 8,
  },
  permissionText: {
    color: COLORS.WHITE,
    fontSize: 16,
    fontWeight: '600',
  },
});

export default MainScreen;