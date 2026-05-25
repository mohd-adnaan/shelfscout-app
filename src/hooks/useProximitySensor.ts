import { useEffect, useRef, useState } from 'react';
import { Platform } from 'react-native';
import {
  addProximityListener,
  startProximitySensor,
  stopProximitySensor,
} from '../native/ProximitySensor';

export const useProximitySensor = (enabled: boolean = true) => {
  const [isNear, setIsNear] = useState(false);
  const isNearRef = useRef(false);
  const isAvailableRef = useRef(false);

  useEffect(() => {
    if (!enabled || Platform.OS !== 'ios') {
      isAvailableRef.current = false;
      isNearRef.current = false;
      setIsNear(false);
      return;
    }

    isAvailableRef.current = true;
    const subscription = addProximityListener((event) => {
      const next = !!event?.near;
      if (next !== isNearRef.current) {
        isNearRef.current = next;
        setIsNear(next);
      }
    });

    startProximitySensor();

    return () => {
      subscription.remove();
      stopProximitySensor();
    };
  }, [enabled]);

  return { isNear, isNearRef, isAvailableRef };
};
