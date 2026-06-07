import { NativeModules, Platform } from 'react-native';

export type ARKitNavigationReason =
  | 'arrived'
  | 'cancelled'
  | 'map_not_found'
  | 'target_not_found'
  | 'ar_unavailable'
  | 'relocalization_failed'
  | 'error';

export interface ARKitNavigationConfig {
  targetName: string;
  routeMapId?: string;
  routeMapName?: string;
  sessionId?: string;
  speakLandmarks?: boolean;
  ttsRate?: number;
}

export interface ARKitNavigationResult {
  success: boolean;
  reason: ARKitNavigationReason;
  targetName?: string;
  routeName?: string;
  message?: string;
}

interface NativeARKitNavigationModule {
  startNavigation(config: ARKitNavigationConfig): Promise<ARKitNavigationResult>;
  presentRouteManager(): Promise<void>;
  stopNavigation(): Promise<void>;
  isAvailable(): Promise<boolean>;
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
};

export const ARKitNavigationBridge: NativeARKitNavigationModule =
  isARKitNavigationModuleLinked && nativeModule ? nativeModule : unavailableModule;
