import { NativeModules, Platform } from 'react-native';

export type ARKitNavigationReason =
  | 'arrived'
  | 'cancelled'
  | 'map_not_found'
  | 'target_not_found'
  | 'ar_unavailable'
  | 'relocalization_failed'
  | 'arrival_unverified'
  | 'error';

export interface ARKitNavigationConfig {
  targetName: string;
  routeMapId?: string;
  routeMapName?: string;
  sessionId?: string;
  speakLandmarks?: boolean;
  errorRecovery?: boolean;
  /** Speak turns as clock-face hours ("turn to 2 o'clock") instead of left/right. */
  clockFaceDirections?: boolean;
  voiceOverEnabled?: boolean;
  ttsRate?: number;
}

/** One spoken destination label from a saved semantic route map. */
export interface ARKitNavigationTargetEntry {
  label: string;
  mapId: string;
  mapName: string;
}

export interface ARKitNavigationResult {
  success: boolean;
  reason: ARKitNavigationReason;
  targetName?: string;
  routeMapId?: string;
  routeName?: string;
  targetWorldPosition?: { x: number; y: number; z: number } | [number, number, number];
  /**
   * Graspable object marked on the arrived destination during route capture.
   * Present only when reason === 'arrived'. When set, the app should hand off
   * into in-device spatial-target reaching for this object.
   */
  reachingObjectName?: string;
  reachingObjectWorldPosition?: { x: number; y: number; z: number } | [number, number, number];
  message?: string;
}

interface NativeARKitNavigationModule {
  startNavigation(config: ARKitNavigationConfig): Promise<ARKitNavigationResult>;
  presentRouteManager(): Promise<void>;
  stopNavigation(): Promise<void>;
  isAvailable(): Promise<boolean>;
  availableNavigationTargets(): Promise<ARKitNavigationTargetEntry[]>;
}

const nativeModule = NativeModules.ARKitNavigationModule as NativeARKitNavigationModule | undefined;

export const isARKitNavigationModuleLinked = Platform.OS === 'ios' && Boolean(nativeModule);

const unavailableModule: NativeARKitNavigationModule = {
  async startNavigation(config: ARKitNavigationConfig): Promise<ARKitNavigationResult> {
    return {
      success: false,
      reason: 'ar_unavailable',
      targetName: config.targetName,
      message: Platform.OS === 'ios'
        ? 'ARKit navigation is not linked in this build.'
        : 'ARKit navigation is available on iPhone only.',
    };
  },
  async presentRouteManager(): Promise<void> {
    throw new Error(
      Platform.OS === 'ios'
        ? 'ARKit navigation is not linked in this build.'
        : 'ARKit route mapping is available on iPhone only.',
    );
  },
  async stopNavigation(): Promise<void> {
    return undefined;
  },
  async isAvailable(): Promise<boolean> {
    return false;
  },
  async availableNavigationTargets(): Promise<ARKitNavigationTargetEntry[]> {
    return [];
  },
};

export const ARKitNavigationBridge: NativeARKitNavigationModule =
  isARKitNavigationModuleLinked && nativeModule ? nativeModule : unavailableModule;
