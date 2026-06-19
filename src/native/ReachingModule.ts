/**
 * src/native/ReachingModule.ts
 * 
 * React Native Bridge for iOS Reaching Module
 * 
 * This module provides iOS-only reaching functionality using ARKit
 * and native hand detection. Android devices should use the existing
 * reaching_flag workflow.
 * 
 * Created: Feb 3, 2026
 */

import { NativeModules, NativeEventEmitter, Platform } from 'react-native';

// =============================================================================
// Types
// =============================================================================

export interface ReachingConfig {
  /** Name of the object to reach (from Qwen detection) */
  objectName: string;
  /** Bounding box from Qwen: [xmin, ymin, xmax, ymax] in pixels */
  bbox: [number, number, number, number];
  /** Width of the image that was sent to Qwen */
  imageWidth: number;
  /** Height of the image that was sent to Qwen */
  imageHeight: number;
  /** Reaching mode: 'handFree' (default) or 'withHand' */
  mode?: 'handFree' | 'withHand';
  /** Backend URL for acquisition validation (enables auto-exit in hand-free mode) */
  acquisitionUrl?: string;
  /** Workflow session ID forwarded to iOS acquisition requests */
  sessionId?: string;
  /** Start AR session silently; JS will enable guidance audio later */
  startupSilent?: boolean;
  /** VoiceOver is active; native should suppress synthesized speech voices. */
  voiceOverEnabled?: boolean;
}

export interface SpatialTargetReachingConfig {
  /** Saved AR map target or object name. Used for speech and future POI lookup. */
  targetName: string;
  /** Optional saved route map metadata for map-target relocalization. */
  routeMapId?: string;
  routeMapName?: string;
  /** Optional target position in the saved ARWorldMap coordinate space. */
  targetWorldPosition?: { x: number; y: number; z: number } | [number, number, number];
  /** Optional normalized on-screen seed region. Defaults to a centered target. */
  targetRegion?: [number, number, number, number];
  /** Reaching mode: 'handFree' (default) or 'withHand' */
  mode?: 'handFree' | 'withHand';
  /** Workflow session ID forwarded to native logs/validation. */
  sessionId?: string;
  /** Start AR session silently; JS will enable guidance audio later */
  startupSilent?: boolean;
  /** VoiceOver is active; native should suppress synthesized speech voices. */
  voiceOverEnabled?: boolean;
  /** iOS TTS speech rate */
  ttsRate?: number;
  /** Distance unit for spoken guidance */
  distanceUnit?: 'steps' | 'cm';
}

export type ReachingState = 'idle' | 'tracking' | 'locked' | 'reached' | 'lost';

export interface ReachingModuleInterface {
  /**
   * Start reaching mode with backend-provided bounding box
   * Presents fullscreen ARKit view with audio guidance
   */
  startReaching(config: ReachingConfig): Promise<void>;

  /**
   * Start backend-bbox-free reaching for a saved/spatial target.
   * This seeds native AR placement from an on-device target region and leaves
   * map-anchor relocalization behind a separate API from backend bbox reaching.
   */
  startSpatialTargetReaching(config: SpatialTargetReachingConfig): Promise<void>;
  
  /**
   * Stop reaching mode and dismiss ARKit view
   */
  stopReaching(): Promise<void>;

  /**
   * Enable AR guidance audio after a silent bootstrap.
   */
  enableGuidanceAudio(): Promise<{ success: boolean; reason?: string }>;
  
  /**
   * Check if ARKit reaching is available on this device
   * Returns false on older devices without ARKit support
   */
  isAvailable(): Promise<boolean>;
  
  /**
   * Get current reaching state
   */
  getState(): Promise<ReachingState>;

  /**
   * Pre-warm the DepthAnythingV2 model on iOS to avoid loading delay when session starts
   */
  prewarmDAv2(): Promise<{ success: boolean }>;
}

// =============================================================================
// Event Types
// =============================================================================

export type ReachingEventType = 
  | 'onTrackingStarted'
  | 'onTargetLocked'
  | 'onTargetReached'
  | 'onTargetLost'
  | 'onError';

export interface ReachingEventData {
  onTrackingStarted: { object: string };
  onTargetLocked: null;
  onTargetReached: null;
  onTargetLost: null;
  onError: { message: string };
}

// =============================================================================
// Native Module Access
// =============================================================================

const { ReachingModule: NativeReachingModule } = NativeModules;

// =============================================================================
// Android Stub Implementation
// =============================================================================

const AndroidStub: ReachingModuleInterface = {
  startReaching: async () => {
    console.warn('[ReachingModule] iOS-only feature. Use reaching_flag for Android.');
    throw new Error('Reaching module is only available on iOS. Use reaching_flag workflow for Android.');
  },
  startSpatialTargetReaching: async () => {
    console.warn('[ReachingModule] spatial target reaching is iOS-only.');
    throw new Error('Spatial target reaching is only available on iOS.');
  },
  stopReaching: async () => {
    console.log('[ReachingModule] stopReaching called on Android (no-op)');
  },
  enableGuidanceAudio: async () => {
    return { success: false, reason: 'ios_only' };
  },
  isAvailable: async () => {
    console.log('[ReachingModule] isAvailable: false (Android)');
    return false;
  },
  getState: async () => {
    return 'idle';
  },
  prewarmDAv2: async () => {
    return { success: false };
  },
};

// =============================================================================
// Platform-Specific Bridge
// =============================================================================

/**
 * ReachingBridge - Platform-aware interface to native reaching module
 * 
 * iOS: Full ARKit-based reaching with hand detection and audio guidance
 * Android: Stub that returns unavailable (use reaching_flag workflow instead)
 */
export const ReachingBridge: ReachingModuleInterface = Platform.select({
  ios: NativeReachingModule as ReachingModuleInterface,
  android: AndroidStub,
  default: AndroidStub,
})!;

// =============================================================================
// Event Emitter
// =============================================================================

/**
 * ReachingEvents - Event emitter for receiving callbacks from native module
 * 
 * Only available on iOS. Returns null on Android.
 * 
 * Usage:
 * ```typescript
 * useEffect(() => {
 *   if (!ReachingEvents) return;
 *   
 *   const subscription = ReachingEvents.addListener('onTargetReached', () => {
 *     console.log('Target reached!');
 *   });
 *   
 *   return () => subscription.remove();
 * }, []);
 * ```
 */
export const ReachingEvents: NativeEventEmitter | null = 
  Platform.OS === 'ios' && NativeReachingModule
    ? new NativeEventEmitter(NativeReachingModule)
    : null;

// =============================================================================
// Helper Functions
// =============================================================================

/**
 * Check if iOS reaching is available and device supports ARKit
 */
export const isIOSReachingAvailable = async (): Promise<boolean> => {
  if (Platform.OS !== 'ios') {
    return false;
  }
  
  try {
    return await ReachingBridge.isAvailable();
  } catch (error) {
    console.error('[ReachingModule] Error checking availability:', error);
    return false;
  }
};

/**
 * Safely start reaching mode with error handling
 */
export const startReachingMode = async (config: ReachingConfig): Promise<boolean> => {
  if (Platform.OS !== 'ios') {
    console.warn('[ReachingModule] Cannot start reaching on non-iOS platform');
    return false;
  }
  
  try {
    const available = await ReachingBridge.isAvailable();
    if (!available) {
      console.warn('[ReachingModule] ARKit not available on this device');
      return false;
    }
    
    await ReachingBridge.startReaching(config);
    return true;
  } catch (error) {
    console.error('[ReachingModule] Failed to start reaching:', error);
    return false;
  }
};

/**
 * Safely start backend-bbox-free spatial target reaching.
 */
export const startSpatialTargetReachingMode = async (
  config: SpatialTargetReachingConfig,
): Promise<boolean> => {
  if (Platform.OS !== 'ios') {
    console.warn('[ReachingModule] Cannot start spatial target reaching on non-iOS platform');
    return false;
  }

  try {
    const available = await ReachingBridge.isAvailable();
    if (!available) {
      console.warn('[ReachingModule] ARKit not available on this device');
      return false;
    }

    await ReachingBridge.startSpatialTargetReaching(config);
    return true;
  } catch (error) {
    console.error('[ReachingModule] Failed to start spatial target reaching:', error);
    return false;
  }
};

/**
 * Safely stop reaching mode
 */
export const stopReachingMode = async (): Promise<void> => {
  if (Platform.OS !== 'ios') {
    return;
  }
  
  try {
    await ReachingBridge.stopReaching();
  } catch (error) {
    console.error('[ReachingModule] Failed to stop reaching:', error);
  }
};

// =============================================================================
// Default Export
// =============================================================================

export default {
  ReachingBridge,
  ReachingEvents,
  isIOSReachingAvailable,
  startReachingMode,
  startSpatialTargetReachingMode,
  stopReachingMode,
};
