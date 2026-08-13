/**
 * src/native/SpatialAudio.ts
 *
 * HRTF spatial-audio renderer for the standard reaching tracker.
 *
 * The tracker returns a `sonification` block per frame; this hands it to the
 * native AVAudioEnvironmentNode renderer unchanged. The wire shape is stable —
 * every key is always present:
 *
 *   pan          non-null → azimuth is stereo pan and position.x is already 0;
 *                null → azimuth is position.x under HRTF
 *   pitch_hz     the tone's frequency. Also carries elevation on its own when
 *                the server flattened position.y to 0
 *   beep_rate_hz the pulse rate. Also carries depth on its own when the server
 *                pinned position.z to a fixed reference distance
 *
 * Since Melody's Aug 2026 change, pitch_hz and beep_rate_hz are populated on
 * every frame including HRTF mode, so the renderer just plays what it is
 * given rather than inferring the mode. Any flattening already happened
 * server-side. Check for null, never for key presence.
 *
 * iOS only — on Android these are no-ops and the loop falls back to spoken
 * guidance alone.
 */

import { NativeModules, Platform } from 'react-native';

const { SpatialAudioModule } = NativeModules as {
  SpatialAudioModule?: {
    start: (options: Record<string, unknown>) => Promise<{
      success: boolean;
      error?: string;
    }>;
    update: (params: Record<string, unknown>) => Promise<{ success: boolean }>;
    silence: () => Promise<{ success: boolean }>;
    stop: () => Promise<{ success: boolean }>;
  };
};

export interface SonificationPayload {
  emit: boolean;
  position: { x: number; y: number; z: number };
  centered: boolean | null;
  pan: number | null;
  pitch_hz: number | null;
  beep_rate_hz: number | null;
}

const isSupported = (): boolean =>
  Platform.OS === 'ios' && !!SpatialAudioModule;

export const startSpatialAudio = async (
  options: {
    volume?: number;
    /**
     * Whether the module may set the AVAudioSession category. Pass false when
     * something else owns the session for the duration (e.g. a live glasses
     * camera stream) — the native side also refuses on its own when a DAT
     * stream is up, this is the JS-side override.
     */
    manageAudioSession?: boolean;
    /** Go silent if no update arrives within this window. Default 2000ms. */
    staleTimeoutMs?: number;
  } = {},
): Promise<boolean> => {
  if (!isSupported()) return false;
  try {
    const result = await SpatialAudioModule!.start(options);
    if (!result?.success) {
      console.warn('[SpatialAudio] start failed:', result?.error);
      return false;
    }
    console.log('[SpatialAudio] started (HRTFHQ)');
    return true;
  } catch (e) {
    console.warn('[SpatialAudio] start threw:', e);
    return false;
  }
};

/**
 * Renders one frame's sonification. Passing a payload with `emit: false`, or
 * null/undefined, silences output for that frame.
 */
export const updateSpatialAudio = async (
  sonification: SonificationPayload | null | undefined,
): Promise<void> => {
  if (!isSupported()) return;
  try {
    if (!sonification || sonification.emit !== true) {
      await SpatialAudioModule!.silence();
      return;
    }
    await SpatialAudioModule!.update({
      emit: true,
      position: sonification.position ?? { x: 0, y: 0, z: -1 },
      centered: sonification.centered === true,
      pan: sonification.pan,
      pitch_hz: sonification.pitch_hz,
      beep_rate_hz: sonification.beep_rate_hz,
    });
  } catch (e) {
    console.warn('[SpatialAudio] update threw:', e);
  }
};

/** Stops output but keeps the engine warm for the next frame. */
export const silenceSpatialAudio = async (): Promise<void> => {
  if (!isSupported()) return;
  try {
    await SpatialAudioModule!.silence();
  } catch (e) {
    console.warn('[SpatialAudio] silence threw:', e);
  }
};

export const stopSpatialAudio = async (): Promise<void> => {
  if (!isSupported()) return;
  try {
    await SpatialAudioModule!.stop();
  } catch (e) {
    console.warn('[SpatialAudio] stop threw:', e);
  }
};
