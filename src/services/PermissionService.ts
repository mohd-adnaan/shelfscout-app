/**
 * src/services/PermissionService.ts
 * 
 * WCAG 2.1 Level AA Compliant Permission Service
 * 
 * Compliance Features:
 * - 3.3.1 Error Identification: Clear permission error messages
 * - 3.3.2 Labels or Instructions: Step-by-step guidance for enabling permissions  
 * - 4.1.3 Status Messages: Announces permission status to screen reader
 * 
 * Cross-Platform Permission Handler
 * - iOS: Native permission system through Info.plist
 * - Android: Runtime permission requests using PermissionsAndroid
 */

import { Platform, PermissionsAndroid, Alert, Linking } from 'react-native';
import { AccessibilityService } from './AccessibilityService';

export interface PermissionStatus {
  camera: 'granted' | 'denied' | 'not-determined';
  microphone: 'granted' | 'denied' | 'not-determined';
  speech: 'granted' | 'denied' | 'not-determined';
}

/**
 * Check current permission status
 * 
 * WCAG 3.3.1: Provides clear status information without errors
 * 
 * @returns Promise<PermissionStatus> - Current permission status
 */
export const checkPermissionStatus = async (): Promise<PermissionStatus> => {
  try {
    if (Platform.OS === 'android') {
      console.log('[Permissions] Checking Android permissions...');
      
      const cameraStatus = await PermissionsAndroid.check(
        PermissionsAndroid.PERMISSIONS.CAMERA
      );
      const micStatus = await PermissionsAndroid.check(
        PermissionsAndroid.PERMISSIONS.RECORD_AUDIO
      );
      
      console.log('[Permissions] Status:', {
        camera: cameraStatus ? 'granted' : 'not-determined',
        microphone: micStatus ? 'granted' : 'not-determined',
      });
      
      return {
        camera: cameraStatus ? 'granted' : 'not-determined',
        microphone: micStatus ? 'granted' : 'not-determined',
        speech: micStatus ? 'granted' : 'not-determined',
      };
    }
    
    // iOS doesn't provide a way to check permissions without requesting them
    console.log('[Permissions] iOS - Cannot check without requesting');
    return {
      camera: 'not-determined',
      microphone: 'not-determined',
      speech: 'not-determined',
    };
    
  } catch (error: any) {
    // WCAG 3.3.1: Handle check errors gracefully without crashing
    console.error('[Permissions] Error checking permissions:', error);
    
    // Don't announce - this is a background check
    // Return safe defaults
    return {
      camera: 'not-determined',
      microphone: 'not-determined',
      speech: 'not-determined',
    };
  }
};

/**
 * Request permissions
 * 
 * WCAG 3.3.1: Clear error messages when permissions denied
 * WCAG 3.3.2: Platform-specific step-by-step guidance
 * WCAG 4.1.3: Announces permission results to screen reader
 * 
 * iOS: Shows native dialogs automatically when features are accessed
 * Android: Explicitly requests permissions using PermissionsAndroid
 * 
 * @returns Promise<boolean> - true if all permissions granted
 */
export const requestPermissions = async (): Promise<boolean> => {
  try {
    if (Platform.OS === 'android') {
      console.log('[Permissions] Requesting Android permissions...');
      
      const granted = await PermissionsAndroid.requestMultiple([
        PermissionsAndroid.PERMISSIONS.CAMERA,
        PermissionsAndroid.PERMISSIONS.RECORD_AUDIO,
      ]);
      
      const cameraGranted = granted[PermissionsAndroid.PERMISSIONS.CAMERA] === 
        PermissionsAndroid.RESULTS.GRANTED;
      const micGranted = granted[PermissionsAndroid.PERMISSIONS.RECORD_AUDIO] === 
        PermissionsAndroid.RESULTS.GRANTED;
      
      console.log('[Permissions] Camera:', cameraGranted ? 'granted' : 'denied');
      console.log('[Permissions] Microphone:', micGranted ? 'granted' : 'denied');
      
      if (cameraGranted && micGranted) {
        console.log('[Permissions] ✅ All permissions granted on Android');
        
        // WCAG 4.1.3: Announce success to screen reader
        AccessibilityService.announceSuccess(
          'Permissions granted. ShelfScout is ready to use.'
        );
        
        return true;
        
      } else {
        // WCAG 3.3.1: Identify which specific permissions were denied
        console.log('[Permissions] ❌ Some permissions denied on Android');
        
        const deniedPermissions = [];
        if (!cameraGranted) deniedPermissions.push('Camera');
        if (!micGranted) deniedPermissions.push('Microphone');
        
        // WCAG 3.3.2: Provide step-by-step instructions
        const permissionNames = deniedPermissions.join(' and ');
        const message = 
          `${permissionNames} permission${deniedPermissions.length > 1 ? 's' : ''} required.\n\n` +
          'To enable permissions:\n' +
          '1. Open Settings\n' +
          '2. Go to Apps\n' +
          '3. Find ShelfScout or CyberSight\n' +
          '4. Tap Permissions\n' +
          `5. Enable ${permissionNames}`;
        
        // WCAG 4.1.3: Announce error to screen reader
        AccessibilityService.announceError(
          `${permissionNames} permission denied. Please enable in Settings.`,
          false
        );
        
        // Show visual alert with "Open Settings" option
        Alert.alert(
          'Permissions Required',
          message,
          [
            { text: 'Cancel', style: 'cancel' },
            { 
              text: 'Open Settings', 
              onPress: () => {
                Linking.openSettings().catch((err) => {
                  console.error('[Permissions] Failed to open settings:', err);
                  
                  AccessibilityService.announceError(
                    'Could not open Settings. Please open Settings app manually.',
                    false
                  );
                });
              },
            },
          ]
        );
        
        return false;
      }
    }
    
    // iOS - permissions requested automatically when features accessed
    console.log('[Permissions] iOS - Permissions will be requested when features are accessed');
    console.log('[Permissions] iOS handles this natively through Info.plist');
    
    return true;
    
  } catch (error: any) {
    // WCAG 3.3.1: Handle permission request errors
    console.error('[Permissions] Error requesting permissions:', error);
    
    let userMessage = 'Failed to request permissions.';
    
    if (error.message?.includes('denied')) {
      userMessage = 'Permissions were denied. Please enable them in your device Settings.';
    } else if (error.message?.includes('never')) {
      userMessage = 'Permissions permanently denied. Please enable them in your device Settings.';
    } else {
      userMessage = 'Error requesting permissions. Please try again or check your device Settings.';
    }
    
    // WCAG 4.1.3: Announce error to screen reader
    AccessibilityService.announceError(userMessage, false);
    
    // Show visual alert
    Alert.alert(
      'Permission Error',
      userMessage,
      [{ text: 'OK', style: 'default' }]
    );
    
    return false;
  }
};

/**
 * Show rationale before requesting permissions
 * 
 * WCAG 3.3.2: Explains why permissions are needed before requesting
 * WCAG 4.1.3: Announces rationale to screen reader
 * 
 * Best practice: Call this before requestPermissions() for better UX
 */
export const showPermissionRationale = (): void => {
  const rationale = 
    'ShelfScout needs camera and microphone access for:\n\n' +
    '• Camera: Capture product images for identification\n' +
    '• Microphone: Voice commands and audio feedback\n' +
    '• Speech Recognition: Convert voice to text';
  
  console.log('[Permissions] Showing permission rationale');
  
  // WCAG 4.1.3: Announce to screen reader
  AccessibilityService.announce(
    'ShelfScout needs camera and microphone access for voice commands and product identification.',
    { delay: 300 }
  );
  
  Alert.alert(
    'Permissions Needed',
    rationale,
    [{ text: 'OK', style: 'default' }]
  );
};

/**
 * Check if running on iOS
 * 
 * @returns boolean - true if iOS platform
 */
export const isIOSPlatform = (): boolean => {
  return Platform.OS === 'ios';
};

/**
 * Check if all required permissions are granted
 * 
 * @returns Promise<boolean> - true if all permissions granted
 */
export const hasAllPermissions = async (): Promise<boolean> => {
  try {
    const status = await checkPermissionStatus();
    
    const allGranted = 
      status.camera === 'granted' && 
      status.microphone === 'granted';
    
    console.log('[Permissions] All permissions granted:', allGranted);
    
    return allGranted;
    
  } catch (error: any) {
    console.error('[Permissions] Error checking all permissions:', error);
    return false;
  }
};

/**
 * Open device settings
 * 
 * WCAG 3.3.2: Provides direct way to fix permission issues
 */
export const openSettings = async (): Promise<void> => {
  try {
    console.log('[Permissions] Opening device settings...');
    
    await Linking.openSettings();
    
    console.log('[Permissions] ✅ Settings opened');
    
    // WCAG 4.1.3: Announce action
    AccessibilityService.announce(
      'Opening Settings. Please enable Camera and Microphone permissions.',
      { delay: 200 }
    );
    
  } catch (error: any) {
    console.error('[Permissions] Error opening settings:', error);
    
    const message = 'Could not open Settings. Please open Settings app manually and enable permissions for ShelfScout.';
    
    AccessibilityService.announceError(message, false);
    
    Alert.alert(
      'Settings Error',
      message,
      [{ text: 'OK', style: 'default' }]
    );
  }
};

// Export all functions
export default {
  checkPermissionStatus,
  requestPermissions,
  showPermissionRationale,
  isIOSPlatform,
  hasAllPermissions,
  openSettings,
};