// Cross-Platform Permission Handler
// iOS: Native permission system through Info.plist
// Android: Runtime permission requests using PermissionsAndroid

import { Platform, PermissionsAndroid, Alert } from 'react-native';

export interface PermissionStatus {
  camera: 'granted' | 'denied' | 'not-determined';
  microphone: 'granted' | 'denied' | 'not-determined';
  speech: 'granted' | 'denied' | 'not-determined';
}

/**
 * Check current permission status
 */
export const checkPermissionStatus = async (): Promise<PermissionStatus> => {
  if (Platform.OS === 'android') {
    const cameraStatus = await PermissionsAndroid.check(PermissionsAndroid.PERMISSIONS.CAMERA);
    const micStatus = await PermissionsAndroid.check(PermissionsAndroid.PERMISSIONS.RECORD_AUDIO);
    
    return {
      camera: cameraStatus ? 'granted' : 'not-determined',
      microphone: micStatus ? 'granted' : 'not-determined',
      speech: micStatus ? 'granted' : 'not-determined',
    };
  }
  
  // iOS doesn't provide a way to check permissions without requesting them
  return {
    camera: 'not-determined',
    microphone: 'not-determined',
    speech: 'not-determined',
  };
};

/**
 * Request permissions
 * iOS: Shows native dialogs automatically when features are accessed
 * Android: Explicitly requests permissions using PermissionsAndroid
 */
export const requestPermissions = async (): Promise<boolean> => {
  try {
    if (Platform.OS === 'android') {
      console.log('[Permissions] Requesting Android permissions...');
      
      const granted = await PermissionsAndroid.requestMultiple([
        PermissionsAndroid.PERMISSIONS.CAMERA,
        PermissionsAndroid.PERMISSIONS.RECORD_AUDIO,
      ]);
      
      const cameraGranted = granted[PermissionsAndroid.PERMISSIONS.CAMERA] === PermissionsAndroid.RESULTS.GRANTED;
      const micGranted = granted[PermissionsAndroid.PERMISSIONS.RECORD_AUDIO] === PermissionsAndroid.RESULTS.GRANTED;
      
      if (cameraGranted && micGranted) {
        console.log('[Permissions] All permissions granted on Android');
        return true;
      } else {
        console.log('[Permissions] Some permissions denied on Android');
        Alert.alert(
          'Permissions Required',
          'ShelfScout needs camera and microphone permissions to function properly. Please grant them in Settings.',
          [{ text: 'OK' }]
        );
        return false;
      }
    }
    
    // iOS - permissions requested automatically
    console.log('[Permissions] iOS - Permissions will be requested when features are accessed');
    console.log('[Permissions] iOS handles this natively through Info.plist');
    return true;
    
  } catch (error) {
    console.error('[Permissions] Error requesting permissions:', error);
    return false;
  }
};

/**
 * Show rationale before requesting permissions
 */
export const showPermissionRationale = (): void => {
  console.log('[Permissions] ShelfScout needs camera and microphone access for:');
  console.log('  - Camera: Capture product images for identification');
  console.log('  - Microphone: Voice commands and audio feedback');
  console.log('  - Speech Recognition: Convert voice to text');
};

/**
 * Check if running on iOS
 */
export const isIOSPlatform = (): boolean => {
  return Platform.OS === 'ios';
};

export default {
  checkPermissionStatus,
  requestPermissions,
  showPermissionRationale,
  isIOSPlatform,
};

// import { Platform } from 'react-native';

// /**
//  * iOS handles permissions natively through Info.plist.
//  * When you access the camera or microphone, iOS automatically shows the permission dialog.
//  * This service provides a simple interface to check if permissions will be requested.
//  */

// export interface PermissionStatus {
//   camera: 'granted' | 'denied' | 'not-determined';
//   microphone: 'granted' | 'denied' | 'not-determined';
//   speech: 'granted' | 'denied' | 'not-determined';
// }

// /**
//  * Check current permission status (best effort)
//  * Note: On iOS, we can't reliably check permission status without triggering the prompt
//  * This returns 'not-determined' as the safe default
//  */
// export const checkPermissionStatus = async (): Promise<PermissionStatus> => {
//   // iOS doesn't provide a way to check permissions without requesting them
//   // Return not-determined which is the safest assumption
//   return {
//     camera: 'not-determined',
//     microphone: 'not-determined', 
//     speech: Platform.OS === 'ios' ? 'not-determined' : 'granted',
//   };
// };

// /**
//  * Request permissions by attempting to access the features
//  * iOS will show native permission dialogs automatically
//  * 
//  * IMPORTANT: This must be called from a user interaction (button press, etc.)
//  */
// export const requestPermissions = async (): Promise<boolean> => {
//   try {
//     console.log('[Permissions] Permissions will be requested when features are accessed');
//     console.log('[Permissions] iOS handles this natively through Info.plist');
    
//     // On iOS, permissions are requested automatically when you:
//     // 1. Access the camera using react-native-camera or react-native-vision-camera
//     // 2. Access the microphone using react-native-voice or @react-native-voice/voice
//     // 3. Use speech recognition through native modules
    
//     // Return true to indicate the system is ready to request permissions
//     return true;
//   } catch (error) {
//     console.error('[Permissions] Error in permission setup:', error);
//     return false;
//   }
// };

// /**
//  * Show an alert explaining why permissions are needed
//  * Useful to show before requesting permissions for better UX
//  */
// export const showPermissionRationale = (): void => {
//   // This would show a native alert explaining permissions
//   // Implementation depends on your UI library
//   console.log('[Permissions] ShelfScout needs camera and microphone access for:');
//   console.log('  - Camera: Capture product images for identification');
//   console.log('  - Microphone: Voice commands and audio feedback');
//   console.log('  - Speech Recognition: Convert voice to text');
// };

// /**
//  * Check if running on iOS (where native permissions apply)
//  */
// export const isIOSPlatform = (): boolean => {
//   return Platform.OS === 'ios';
// };

// export default {
//   checkPermissionStatus,
//   requestPermissions,
//   showPermissionRationale,
//   isIOSPlatform,
// };