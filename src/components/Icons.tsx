import React from 'react';
import { View, StyleSheet, Animated } from 'react-native';
import Svg, { Circle, Path, G } from 'react-native-svg';

interface IconProps {
  size?: number;
  color?: string;
}

export const Mic: React.FC<IconProps> = ({ size = 24, color = '#fff' }) => {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <Path
        d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"
        fill={color}
      />
      <Path
        d="M19 10v2a7 7 0 0 1-14 0v-2"
        stroke={color}
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <Path
        d="M12 19v4M8 23h8"
        stroke={color}
        strokeWidth="2"
        strokeLinecap="round"
      />
    </Svg>
  );
};

export const MicOff: React.FC<IconProps> = ({ size = 24, color = '#fff' }) => {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <Path
        d="M9 9v3a3 3 0 0 0 5.12 2.12M15 9.34V4a3 3 0 0 0-5.94-.6"
        stroke={color}
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <Path
        d="M17 16.95A7 7 0 0 1 5 12v-2m14 0v2a7 7 0 0 1-.11 1.23"
        stroke={color}
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <Path
        d="M12 19v4M8 23h8M1 1l22 22"
        stroke={color}
        strokeWidth="2"
        strokeLinecap="round"
      />
    </Svg>
  );
};

export const Speaker: React.FC<IconProps> = ({ size = 24, color = '#fff' }) => {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <Path
        d="M11 5L6 9H2v6h4l5 4V5z"
        fill={color}
      />
      <Path
        d="M15.54 8.46a5 5 0 0 1 0 7.07M19.07 4.93a10 10 0 0 1 0 14.14"
        stroke={color}
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </Svg>
  );
};

export const Brain: React.FC<IconProps> = ({ size = 24, color = '#fff' }) => {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <Path
        d="M9.5 2A2.5 2.5 0 0 0 7 4.5v15A2.5 2.5 0 0 0 9.5 22h5a2.5 2.5 0 0 0 2.5-2.5v-15A2.5 2.5 0 0 0 14.5 2h-5z"
        stroke={color}
        strokeWidth="2"
        fill="none"
      />
      <Circle cx="12" cy="8" r="1.5" fill={color} />
      <Circle cx="12" cy="12" r="1.5" fill={color} />
      <Circle cx="12" cy="16" r="1.5" fill={color} />
      <Path
        d="M9 8h6M9 12h6M9 16h6"
        stroke={color}
        strokeWidth="0.5"
        strokeLinecap="round"
      />
    </Svg>
  );
};

export const Loader: React.FC<IconProps> = ({ size = 24, color = '#fff' }) => {
  const spinValue = new Animated.Value(0);

  React.useEffect(() => {
    Animated.loop(
      Animated.timing(spinValue, {
        toValue: 1,
        duration: 1000,
        useNativeDriver: true,
      })
    ).start();
  }, []);

  const spin = spinValue.interpolate({
    inputRange: [0, 1],
    outputRange: ['0deg', '360deg'],
  });

  return (
    <Animated.View style={{ transform: [{ rotate: spin }] }}>
      <Svg width={size} height={size} viewBox="0 0 24 24" fill="none">
        <Circle
          cx="12"
          cy="12"
          r="10"
          stroke={color}
          strokeWidth="3"
          strokeLinecap="round"
          strokeDasharray="15, 85"
        />
      </Svg>
    </Animated.View>
  );
};