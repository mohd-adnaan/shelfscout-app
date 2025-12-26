import { useRef } from 'react';
import { Camera, useCameraDevice, useCameraPermission } from 'react-native-vision-camera';
import { CameraPhoto } from '../utils/types';

export const useCamera = () => {
  const device = useCameraDevice('back');
  const { hasPermission, requestPermission } = useCameraPermission();
  const cameraRef = useRef<Camera>(null);

  const capturePhoto = async (): Promise<string> => {
    if (!cameraRef.current) {
      throw new Error('Camera not initialized');
    }

    if (!hasPermission) {
      const granted = await requestPermission();
      if (!granted) {
        throw new Error('Camera permission denied');
      }
    }

    try {
      const photo = await cameraRef.current.takePhoto({
        qualityPrioritization: 'balanced',
        flash: 'off',
      });

      console.log('Photo captured:', photo.path);
      return `file://${photo.path}`;
    } catch (error) {
      console.error('Photo capture error:', error);
      throw error;
    }
  };

  return {
    device,
    cameraRef,
    capturePhoto,
    hasPermission,
  };
};