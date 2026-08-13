/**
 * src/native/DeviceAttitude.ts
 *
 * Phone orientation (CMDeviceMotion.attitude) for the standard reaching
 * tracker. The tracker posts yaw/pitch/roll with each frame so the
 * server-side sonification knows how the phone was pointed.
 *
 * iOS only — Android returns null and callers post the frame without
 * orientation rather than dropping it.
 */

import { NativeModules, Platform } from 'react-native';

const { DeviceAttitudeModule } = NativeModules as {
  DeviceAttitudeModule?: {
    start: (options: Record<string, unknown>) => Promise<{
      success: boolean;
      reference_frame?: string;
      error?: string;
    }>;
    stop: () => Promise<{ success: boolean }>;
    getAttitude: () => Promise<DeviceAttitude | null>;
  };
};

/**
 * What yaw 0 means. `gravity` is Melody's confirmed choice: pitch/roll are
 * absolute (gravity-referenced) but yaw is relative to wherever the phone
 * pointed when updates started, and it drifts. The north-referenced frames
 * give absolute yaw at the cost of depending on the magnetometer, which is
 * unreliable in a grocery aisle full of steel shelving. Do not change this
 * mid-study — yaw would stop meaning the same thing across runs.
 */
export type AttitudeReferenceFrame = 'gravity' | 'magneticNorth' | 'trueNorth';

export interface DeviceAttitude {
  /** Rotation about the gravity axis, degrees, [-180, 180], CCW-positive. */
  yaw_deg: number;
  /** Nose up/down, degrees, [-90, 90]. */
  pitch_deg: number;
  /** Rotation about the phone's long axis, degrees, [-180, 180]. */
  roll_deg: number;
  /** Unix epoch seconds when the sensor sample was taken (not when read). */
  capture_ts: number;
  /** The frame actually applied — may differ from the one requested. */
  reference_frame: AttitudeReferenceFrame;
  /** Sample age at read time. Large values mean the sensor stalled. */
  age_ms: number;
  /**
   * The same rotation as the Euler angles above, straight from
   * CMAttitude.quaternion. Free of gimbal lock and safe to interpolate, which
   * the degrees are not.
   */
  quaternion: { x: number; y: number; z: number; w: number };
}

const isSupported = (): boolean =>
  Platform.OS === 'ios' && !!DeviceAttitudeModule;

export const startDeviceAttitude = async (
  options: {
    referenceFrame?: AttitudeReferenceFrame;
    updateIntervalMs?: number;
  } = {},
): Promise<boolean> => {
  if (!isSupported()) return false;
  try {
    const result = await DeviceAttitudeModule!.start({
      referenceFrame: options.referenceFrame ?? 'gravity',
      ...(options.updateIntervalMs !== undefined
        ? { updateIntervalMs: options.updateIntervalMs }
        : {}),
    });
    if (!result?.success) {
      console.warn('[DeviceAttitude] start failed:', result?.error);
      return false;
    }
    console.log(`[DeviceAttitude] started (frame=${result.reference_frame})`);
    return true;
  } catch (e) {
    console.warn('[DeviceAttitude] start threw:', e);
    return false;
  }
};

export const stopDeviceAttitude = async (): Promise<void> => {
  if (!isSupported()) return;
  try {
    await DeviceAttitudeModule!.stop();
  } catch (e) {
    console.warn('[DeviceAttitude] stop threw:', e);
  }
};

/**
 * Newest attitude sample, or null when unavailable. Never throws — orientation
 * is supplementary to the frame, so a sensor problem must not take the
 * guidance loop down with it.
 */
export const getDeviceAttitude = async (): Promise<DeviceAttitude | null> => {
  if (!isSupported()) return null;
  try {
    return await DeviceAttitudeModule!.getAttitude();
  } catch (e) {
    console.warn('[DeviceAttitude] read threw:', e);
    return null;
  }
};
