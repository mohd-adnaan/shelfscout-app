// Permission utilities
import { Platform } from 'react-native';
import { check, request, PERMISSIONS, RESULTS, Permission } from 'react-native-permissions';

export const checkAndRequestPermissions = async (): Promise<boolean> => {
  try {
    const micPermission = Platform.select({
      ios: PERMISSIONS.IOS.MICROPHONE,
      android: PERMISSIONS.ANDROID.RECORD_AUDIO,
    }) as Permission;
    
    const cameraPermission = Platform.select({
      ios: PERMISSIONS.IOS.CAMERA,
      android: PERMISSIONS.ANDROID.CAMERA,
    }) as Permission;

    const speechPermission = Platform.select({
      ios: PERMISSIONS.IOS.SPEECH_RECOGNITION,
      android: null,
    });

    // Check microphone
    let micStatus = await check(micPermission);
    if (micStatus !== RESULTS.GRANTED) {
      micStatus = await request(micPermission);
    }

    // Check camera
    let cameraStatus = await check(cameraPermission);
    if (cameraStatus !== RESULTS.GRANTED) {
      cameraStatus = await request(cameraPermission);
    }

    // Check speech recognition (iOS only)
    let speechStatus = RESULTS.GRANTED;
    if (Platform.OS === 'ios' && speechPermission) {
      speechStatus = await check(speechPermission);
      if (speechStatus !== RESULTS.GRANTED) {
        speechStatus = await request(speechPermission);
      }
    }

    return (
      micStatus === RESULTS.GRANTED &&
      cameraStatus === RESULTS.GRANTED &&
      speechStatus === RESULTS.GRANTED
    );
  } catch (error) {
    console.error('Permission error:', error);
    return false;
  }
};