import { NativeModules, Platform } from 'react-native';
import type { AppLanguage } from '../i18n';

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
  /** Language for native spoken guidance ('en' | 'fr'). */
  language?: AppLanguage;
  /**
   * Keep the AR screen mounted and relocalized after arriving, so the next
   * leg can start with `continueNavigation` and skip relocalization. Ignored
   * when the arrival hands off to reaching, which needs the camera back.
   */
  keepSessionAlive?: boolean;
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
  /**
   * The AR session stayed mounted and localized after this result. The next
   * leg should be launched with `continueNavigation` so it reuses the live
   * pose instead of relocalizing from scratch.
   */
  sessionAlive?: boolean;
  message?: string;
}

interface NativeARKitNavigationModule {
  startNavigation(config: ARKitNavigationConfig): Promise<ARKitNavigationResult>;
  /**
   * Start the next leg on an already-running, already-localized AR session.
   * Falls back to a normal `startNavigation` when no warm session exists, so
   * callers can always use it for a follow-up destination.
   */
  continueNavigation(config: ARKitNavigationConfig): Promise<ARKitNavigationResult>;
  presentRouteManager(): Promise<void>;
  stopNavigation(): Promise<void>;
  isAvailable(): Promise<boolean>;
  availableNavigationTargets(): Promise<ARKitNavigationTargetEntry[]>;
  /** Set the language for all native spoken guidance. Resolves with the code actually applied. */
  setLanguage(code: AppLanguage): Promise<string>;
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
  async continueNavigation(config: ARKitNavigationConfig): Promise<ARKitNavigationResult> {
    return this.startNavigation(config);
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
  async setLanguage(code: AppLanguage): Promise<string> {
    // No native module (Android, or an iOS build without it linked) — the JS
    // i18n store still holds the language, so this is a silent no-op.
    return code;
  },
};

export const ARKitNavigationBridge: NativeARKitNavigationModule =
  isARKitNavigationModuleLinked && nativeModule ? nativeModule : unavailableModule;
