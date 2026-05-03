/**
 * src/services/WearablesCamera.ts
 *
 * Minimal placeholder for Meta Ray-Ban camera access.
 *
 * NOTE: This is a stub until the Meta Wearables Device Access Toolkit
 * is integrated natively (iOS/Android). It provides a single place
 * to wire up streaming/photo capture later.
 */

import { NativeModules, Platform } from 'react-native';

export type WearablesCameraStatus = 'unknown' | 'connected' | 'disconnected' | 'unsupported';

const { WearablesCameraModule } = NativeModules;

const notConnectedMessage =
  'Meta Ray-Ban camera not connected. Pair your glasses in the Meta AI app and enable Developer Mode.';

const isIOSSupported = Platform.OS === 'ios' && !!WearablesCameraModule?.capturePhoto;

export const wearablesCamera = {

  async preWarm(): Promise<void> {
    if (!isIOSSupported) return;
    await WearablesCameraModule.preWarm();
  },

  async getStatus(): Promise<WearablesCameraStatus> {
    if (!isIOSSupported) {
      return 'unsupported';
    }

    try {
      const status = await WearablesCameraModule.getStatus();
      if (status === 'connected' || status === 'disconnected' || status === 'unknown') {
        return status;
      }
      return 'unknown';
    } catch (error) {
      console.warn('[WearablesCamera] Status check failed:', error);
      return 'unknown';
    }
  },

  async startRegistration(): Promise<void> {
    if (!isIOSSupported) {
      throw new Error('Wearables camera is only available on iOS with the Meta SDK configured.');
    }

    await WearablesCameraModule.startRegistration();
  },

  async capturePhoto(): Promise<string> {
    if (!isIOSSupported) {
      throw new Error('Wearables camera is only available on iOS with the Meta SDK configured.');
    }

    try {
      const path = await WearablesCameraModule.capturePhoto();
      if (!path) {
        throw new Error('Wearables capture returned an empty path.');
      }
      return path;
    } catch (error: any) {
      if (error?.message?.toLowerCase().includes('permission')) {
        throw new Error('Camera permission denied. Please grant access in the Meta AI app.');
      }
      throw new Error(error?.message || notConnectedMessage);
    }
  },
};
