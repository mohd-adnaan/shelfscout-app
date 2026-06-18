import { NativeEventEmitter, NativeModules, Platform } from 'react-native';

type ProximityEvent = { near?: boolean };

const { ProximitySensorModule } = NativeModules as {
  ProximitySensorModule?: {
    start?: () => void;
    stop?: () => void;
    addListener: (eventName: string) => void;
    removeListeners: (count: number) => void;
  };
};

const emitter =
  Platform.OS === 'ios' && ProximitySensorModule
    ? new NativeEventEmitter(ProximitySensorModule)
    : null;

export const startProximitySensor = (): void => {
  if (Platform.OS !== 'ios' || !ProximitySensorModule?.start) return;
  try {
    ProximitySensorModule.start();
  } catch (e) {
    console.warn('ProximitySensor start failed:', e);
  }
};

export const stopProximitySensor = (): void => {
  if (Platform.OS !== 'ios' || !ProximitySensorModule?.stop) return;
  try {
    ProximitySensorModule.stop();
  } catch (e) {
    console.warn('ProximitySensor stop failed:', e);
  }
};

export const addProximityListener = (
  handler: (event: ProximityEvent) => void
): { remove: () => void } => {
  if (!emitter) {
    return { remove: () => {} };
  }
  return emitter.addListener('onProximityChange', handler);
};
