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
}

export type ReachingState = 'idle' | 'tracking' | 'locked' | 'reached' | 'lost';

export interface ReachingModuleInterface {
  /**
   * Start reaching mode with backend-provided bounding box
   * Presents fullscreen ARKit view with audio guidance
   */
  startReaching(config: ReachingConfig): Promise<void>;
  
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
  stopReachingMode,
};