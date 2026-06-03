import { useState, useEffect, useRef } from 'react';
import { accelerometer, setUpdateIntervalForType, SensorTypes } from 'react-native-sensors';

// Update every 500ms to save battery while still being responsive enough
setUpdateIntervalForType(SensorTypes.accelerometer, 500);

const STRAIGHT_RATIO = 1.2; // Require a bit more upright than 45 degrees

export const useDeviceOrientation = () => {
  const [isDeviceStraight, setIsDeviceStraight] = useState(true);
  // Keep a ref to the latest value for synchronous access in non-React contexts if needed
  const isStraightRef = useRef(true);
  // True if we have received at least one accelerometer sample without error
  const isAvailableRef = useRef(true);

  useEffect(() => {
    // Platform differences might exist, but generally:
    // When held vertically (portrait), gravity mostly acts on the Y axis.
    // When held flat (e.g., camera pointing to floor), gravity mostly acts on the Z axis.
    const subscription = accelerometer.subscribe(({ x, y, z }) => {
      // If |y| > |z|, the device is more vertical than horizontal (>45 degrees).
      // You can adjust the multiplier on |z| to require it to be even more vertical.
      // E.g., |y| > |z| * 1.5 means it must be >56 degrees vertical.
      // We will use |y| > |z| for a generous 45-degree threshold.
      const isStraight = Math.abs(y) > Math.abs(z) * STRAIGHT_RATIO;
      isAvailableRef.current = true;
      
      if (isStraight !== isStraightRef.current) {
        isStraightRef.current = isStraight;
        setIsDeviceStraight(isStraight);
      }
    }, (error) => {
      // If CoreMotion is blocked, avoid gating the UX on a missing signal.
      isAvailableRef.current = false;
      isStraightRef.current = true;
      setIsDeviceStraight(true);
      console.warn('Accelerometer error:', error);
    });

    return () => {
      subscription.unsubscribe();
    };
  }, []);

  return { isDeviceStraight, isStraightRef, isAvailableRef };
};
