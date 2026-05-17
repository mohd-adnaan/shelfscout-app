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

export type WearablesCameraStatus =
  | 'unknown'
  | 'connected'
  | 'paired'
  | 'disconnected'
  | 'unsupported';

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
      if (
        status === 'connected' ||
        status === 'paired' ||
        status === 'disconnected' ||
        status === 'unknown'
      ) {
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
      if (error?.code) {
        throw error;
      }

      const message = error?.message || notConnectedMessage;
      const lower = String(message).toLowerCase();
      const enriched = new Error(message) as Error & { code?: string };

      if (lower.includes('permission')) {
        enriched.code = 'PERMISSION';
      } else if (
        lower.includes('stream did not reach streaming state') ||
        lower.includes('device session stopped') ||
        lower.includes('internalerror')
      ) {
        enriched.code = 'CAPTURE';
      }

      throw enriched;
    }
  },

  async disconnect(): Promise<void> {
    if (!isIOSSupported) return;
    try {
      await WearablesCameraModule.disconnect();
    } catch (error) {
      console.warn('[WearablesCamera] Disconnect failed:', error);
    }
  },
};
