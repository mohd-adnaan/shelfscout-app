import { useState, useEffect, useRef } from 'react';
import { accelerometer, setUpdateIntervalForType, SensorTypes } from 'react-native-sensors';

// Update every 500ms to save battery while still being responsive enough
setUpdateIntervalForType(SensorTypes.accelerometer, 500);

/**
 * Angle convention used by the navigation posture gate:
 *   0 degrees  = phone upright, rear camera looking forward
 *   45 degrees = half-forward / half-floor, poor for frame matching
 *   90 degrees = phone flat, rear camera facing the floor
 *
 * RTAB and ARKit route matching both depend on forward-looking frames, so we
 * block before the device gets anywhere near the 45-degree half-floor pose.
 */
export const MAX_FORWARD_TILT_DEGREES = 35;

export interface DeviceOrientationSnapshot {
  x: number;
  y: number;
  z: number;
  tiltFromUprightDegrees: number;
  isStraight: boolean;
}

const UNKNOWN_ORIENTATION: DeviceOrientationSnapshot = {
  x: 0,
  y: 0,
  z: 0,
  tiltFromUprightDegrees: 0,
  isStraight: true,
};

const calculateTiltFromUpright = (y: number, z: number): number => {
  const uprightGravity = Math.max(Math.abs(y), 0.001);
  const floorGravity = Math.abs(z);
  return Math.atan2(floorGravity, uprightGravity) * (180 / Math.PI);
};

export const useDeviceOrientation = () => {
  const [isDeviceStraight, setIsDeviceStraight] = useState(true);
  const [tiltFromUprightDegrees, setTiltFromUprightDegrees] = useState(0);
  // Keep a ref to the latest value for synchronous access in non-React contexts if needed
  const isStraightRef = useRef(true);
  const tiltFromUprightRef = useRef(0);
  const displayedTiltRef = useRef(0);
  const orientationSnapshotRef = useRef<DeviceOrientationSnapshot>(UNKNOWN_ORIENTATION);
  // True if we have received at least one accelerometer sample without error
  const isAvailableRef = useRef(true);

  useEffect(() => {
    // Platform differences might exist, but generally:
    // When held vertically (portrait), gravity mostly acts on the Y axis.
    // When held flat (e.g., camera pointing to floor), gravity mostly acts on the Z axis.
    const subscription = accelerometer.subscribe(({ x, y, z }) => {
      const tilt = calculateTiltFromUpright(y, z);
      const isStraight = tilt <= MAX_FORWARD_TILT_DEGREES;
      isAvailableRef.current = true;
      tiltFromUprightRef.current = tilt;
      orientationSnapshotRef.current = {
        x,
        y,
        z,
        tiltFromUprightDegrees: tilt,
        isStraight,
      };
      
      if (isStraight !== isStraightRef.current) {
        isStraightRef.current = isStraight;
        setIsDeviceStraight(isStraight);
      }

      if (Math.abs(tilt - displayedTiltRef.current) >= 2) {
        displayedTiltRef.current = tilt;
        setTiltFromUprightDegrees(tilt);
      }
    }, (error) => {
      // If CoreMotion is blocked, avoid gating the UX on a missing signal.
      isAvailableRef.current = false;
      isStraightRef.current = true;
      tiltFromUprightRef.current = 0;
      displayedTiltRef.current = 0;
      orientationSnapshotRef.current = UNKNOWN_ORIENTATION;
      setIsDeviceStraight(true);
      setTiltFromUprightDegrees(0);
      console.warn('Accelerometer error:', error);
    });

    return () => {
      subscription.unsubscribe();
    };
  }, []);

  return {
    isDeviceStraight,
    isStraightRef,
    isAvailableRef,
    tiltFromUprightDegrees,
    tiltFromUprightRef,
    orientationSnapshotRef,
    maxForwardTiltDegrees: MAX_FORWARD_TILT_DEGREES,
  };
};
