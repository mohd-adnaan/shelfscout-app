/**
 * src/hooks/useCamera.ts
 * 
 * WCAG 2.1 Level AA Compliant Camera Hook
 * 
 * Compliance Features:
 * - 3.3.1 Error Identification: Clear error messages for camera failures
 * - 3.3.2 Labels or Instructions: Guidance for fixing camera issues
 * - 4.1.3 Status Messages: Announces camera errors to screen reader
 * 
 * Provides camera functionality with accessibility support
 */

import { useRef } from 'react';
import { Alert, Platform } from 'react-native';
import { 
  Camera, 
  useCameraDevice, 
  useCameraPermission 
} from 'react-native-vision-camera';
import { AccessibilityService } from '../services/AccessibilityService';

/**
 * Camera Hook with WCAG-compliant error handling
 * 
 * @returns Camera functionality and state
 */
export const useCamera = () => {
  const device = useCameraDevice('back');
  const { hasPermission, requestPermission } = useCameraPermission();
  const cameraRef = useRef<Camera>(null);

  /**
   * Capture photo with comprehensive error handling
   * 
   * WCAG 3.3.1: Clear error messages for all camera failures
   * WCAG 3.3.2: Provides guidance for resolving issues
   * WCAG 4.1.3: Announces errors to screen reader
   * 
   * @returns Promise<string> - File URI of captured photo
   * @throws Error with user-friendly message
   */
  const capturePhoto = async (): Promise<string> => {
    try {
      // WCAG 3.3.1: Validate camera initialization
      if (!cameraRef.current) {
        const message = 'Camera not initialized. Please restart the app.';
        
        console.error('[Camera] ❌ Camera ref is null');
        
        // WCAG 4.1.3: Announce error to screen reader
        AccessibilityService.announceError(message, false);
        
        Alert.alert(
          'Camera Error',
          message,
          [{ text: 'OK', style: 'default' }]
        );
        
        throw new Error(message);
      }

      // WCAG 3.3.1: Validate camera device
      if (!device) {
        const message = 'No camera found on this device.';
        
        console.error('[Camera] ❌ No camera device available');
        
        AccessibilityService.announceError(message, false);
        
        Alert.alert(
          'Camera Unavailable',
          message,
          [{ text: 'OK', style: 'default' }]
        );
        
        throw new Error(message);
      }

      // WCAG 3.3.2: Check and request permission with guidance
      if (!hasPermission) {
        console.log('[Camera] Requesting camera permission...');
        
        const granted = await requestPermission();
        
        if (!granted) {
          // WCAG 3.3.2: Platform-specific guidance
          const guidance = Platform.OS === 'ios'
            ? 'To enable camera:\n1. Open Settings\n2. Find ShelfScout\n3. Enable Camera'
            : 'To enable camera:\n1. Open Settings\n2. Go to Apps\n3. Find ShelfScout\n4. Tap Permissions\n5. Enable Camera';
          
          const message = `Camera permission denied.\n\n${guidance}`;
          
          console.error('[Camera] ❌ Permission denied');
          
          // WCAG 4.1.3: Announce error
          AccessibilityService.announceError(
            'Camera permission denied. Please enable it in Settings.',
            false
          );
          
          Alert.alert(
            'Camera Permission Required',
            message,
            [{ text: 'OK', style: 'default' }]
          );
          
          throw new Error('Camera permission denied');
        }
        
        console.log('[Camera] ✅ Permission granted');
      }

      // Capture photo
      console.log('[Camera] Capturing photo...');
      
      const photo = await cameraRef.current.takePhoto({
        qualityPrioritization: 'balanced',
        flash: 'off',
      });

      console.log('[Camera] ✅ Photo captured:', photo.path);

      // Ensure proper file URI format
      const photoUri = photo.path.startsWith('file://') 
        ? photo.path 
        : `file://${photo.path}`;

      return photoUri;
      
    } catch (error: any) {
      // WCAG 3.3.1: Format camera errors for users
      console.error('[Camera] ❌ Capture error:', error);
      
      let userMessage = 'Failed to capture photo.';
      let shouldShowAlert = true;
      
      // Parse error types and provide clear messages
      if (error.message) {
        const errorMsg = error.message.toLowerCase();
        
        if (errorMsg.includes('permission')) {
          userMessage = 'Camera permission denied. Please enable it in Settings.';
        } 
        else if (errorMsg.includes('not initialized') || errorMsg.includes('camera ref')) {
          userMessage = 'Camera not ready. Please restart the app.';
        } 
        else if (errorMsg.includes('no camera') || errorMsg.includes('unavailable')) {
          userMessage = 'Camera is not available on this device.';
        } 
        else if (errorMsg.includes('busy') || errorMsg.includes('in use')) {
          userMessage = 'Camera is busy. Please close other camera apps and try again.';
        } 
        else if (errorMsg.includes('disconnected') || errorMsg.includes('hardware')) {
          userMessage = 'Camera hardware error. Please restart your device.';
        } 
        else if (errorMsg.includes('timeout')) {
          userMessage = 'Camera timeout. Please try again.';
        } 
        else if (errorMsg.includes('capture failed') || errorMsg.includes('take photo')) {
          userMessage = 'Photo capture failed. Please try again.';
        } 
        else if (errorMsg.includes('denied')) {
          // Permission error already handled above
          shouldShowAlert = false;
        } 
        else {
          userMessage = `Camera error: ${error.message}`;
        }
      }
      
      // WCAG 4.1.3: Announce error to screen reader
      AccessibilityService.announceError(userMessage, false);
      
      // Show visual alert
      if (shouldShowAlert) {
        Alert.alert(
          'Camera Error',
          userMessage + ' Please try again.',
          [{ text: 'OK', style: 'default' }]
        );
      }
      
      // Re-throw with user-friendly message
      throw new Error(userMessage);
    }
  };

  /**
   * Check if camera is ready to capture
   * 
   * @returns boolean - true if camera is ready
   */
  const isCameraReady = (): boolean => {
    const ready = !!(device && cameraRef.current && hasPermission);
    
    console.log('[Camera] Ready:', ready, {
      hasDevice: !!device,
      hasRef: !!cameraRef.current,
      hasPermission,
    });
    
    return ready;
  };

  /**
   * Get detailed camera status for debugging
   * 
   * @returns Object with camera state details
   */
  const getCameraStatus = () => {
    return {
      hasDevice: !!device,
      hasRef: !!cameraRef.current,
      hasPermission,
      isReady: isCameraReady(),
    };
  };

  return {
    device,
    cameraRef,
    capturePhoto,
    hasPermission,
    isCameraReady,
    getCameraStatus,
  };
};