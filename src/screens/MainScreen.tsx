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
import { checkAndRequestPermissions } from '../services/PermissionService';
import { COLORS } from '../utils/constants';

const MainScreen: React.FC = () => {
  const [isRecording, setIsRecording] = useState(false);
  const [isProcessing, setIsProcessing] = useState(false);
  const [hasPermissions, setHasPermissions] = useState(false);
  const [currentTranscript, setCurrentTranscript] = useState('');
  
  const { startRecognition, stopRecognition } = useVoiceRecognition();
  const { device, cameraRef, capturePhoto } = useCamera();
  const { speak, stop: stopTTS } = useTTS();

  useEffect(() => {
    initializePermissions();
  }, []);

  const initializePermissions = async () => {
    const granted = await checkAndRequestPermissions();
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

    if (isRecording) {
      // Stop recording and process
      setIsRecording(false);
      await stopRecognition();
      if (currentTranscript) {
        await processVoiceCommand(currentTranscript);
      }
    } else {
      // Start recording
      setIsRecording(true);
      setCurrentTranscript('');
      startRecognition(
        handleSpeechResult,
        handleSpeechError,
        () => console.log('Speech started'),
        () => console.log('Speech ended')
      );
    }
  };

  const handleDoubleTap = async () => {
    if (isRecording) {
      console.log('Double tap detected - capturing photo');
      // Just capture and store, will use when processing
      try {
        await capturePhoto();
        Alert.alert('Photo Captured', 'Photo captured successfully');
      } catch (error) {
        console.error('Photo capture error:', error);
      }
    }
  };

  const handleSpeechResult = (transcript: string) => {
    console.log('Transcript received:', transcript);
    setCurrentTranscript(transcript);
  };

  const handleSpeechError = (error: any) => {
    console.error('Speech recognition error:', error);
    setIsRecording(false);
    Alert.alert('Error', 'Speech recognition failed. Please try again.');
  };

  const processVoiceCommand = async (transcript: string) => {
    setIsProcessing(true);
    
    try {
      console.log('Processing voice command:', transcript);
      
      // Capture photo
      const photoUri = await capturePhoto();
      console.log('Photo captured:', photoUri);
      
      // Send to backend
      const response = await sendToWorkflow({
        text: transcript,
        imageUri: photoUri,
      });

      console.log('Response received:', response);

      // Speak response
      if (response.text) {
        await speak(response.text);
      } else {
        Alert.alert('No Response', 'No response received from server');
      }
      
    } catch (error) {
      console.error('Processing error:', error);
      Alert.alert(
        'Error',
        'Failed to process request. Please check your internet connection and try again.'
      );
    } finally {
      setIsProcessing(false);
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

  return (
    <View style={styles.container}>
      <Camera
        ref={cameraRef}
        style={StyleSheet.absoluteFill}
        device={device}
        isActive={true}
        photo={true}
      />

      <VisualFeedback isActive={isRecording || isProcessing} />
      
      <View style={styles.buttonContainer}>
        <VoiceButton
          isRecording={isRecording}
          isProcessing={isProcessing}
          onPress={handlePress}
          onDoubleTap={handleDoubleTap}
        />
        
        {isRecording && (
          <Text style={styles.recordingText}>Listening...</Text>
        )}
        
        {isProcessing && (
          <Text style={styles.recordingText}>Processing...</Text>
        )}
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
  recordingText: {
    color: COLORS.WHITE,
    fontSize: 18,
    fontWeight: '600',
    marginTop: 16,
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