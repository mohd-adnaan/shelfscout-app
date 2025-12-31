import React, { useEffect, useRef } from 'react';
import { View, StyleSheet, Animated, Dimensions } from 'react-native';
import { COLORS } from '../utils/constants';
import { Mic, Speaker, Brain } from './Icons';

const { width } = Dimensions.get('window');
const CIRCLE_SIZE = width * 0.5;

interface VisualFeedbackProps {
  isActive: boolean;
  isRecording?: boolean;
  isProcessing?: boolean;
  isSpeaking?: boolean;
}

const VisualFeedback: React.FC<VisualFeedbackProps> = ({ 
  isActive, 
  isRecording = false,
  isProcessing = false,
  isSpeaking = false,
}) => {
  const pulseAnim = useRef(new Animated.Value(0)).current;
  const opacityAnim = useRef(new Animated.Value(0)).current;
  const rotateAnim = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    if (isActive) {
      // Fade in
      Animated.timing(opacityAnim, {
        toValue: 1,
        duration: 300,
        useNativeDriver: true,
      }).start();

      if (isProcessing) {
        // Rotating animation for thinking
        Animated.loop(
          Animated.timing(rotateAnim, {
            toValue: 1,
            duration: 2000,
            useNativeDriver: true,
          })
        ).start();
      } else {
        // Pulse animation for recording/speaking
        Animated.loop(
          Animated.sequence([
            Animated.timing(pulseAnim, {
              toValue: 1,
              duration: 2000,
              useNativeDriver: true,
            }),
            Animated.timing(pulseAnim, {
              toValue: 0,
              duration: 2000,
              useNativeDriver: true,
            }),
          ])
        ).start();
      }
    } else {
      // Fade out
      Animated.timing(opacityAnim, {
        toValue: 0,
        duration: 300,
        useNativeDriver: true,
      }).start();
      pulseAnim.setValue(0);
      rotateAnim.setValue(0);
    }
  }, [isActive, isProcessing, pulseAnim, opacityAnim, rotateAnim]);

  const scale = pulseAnim.interpolate({
    inputRange: [0, 1],
    outputRange: [1, 1.3],
  });

  const rotation = rotateAnim.interpolate({
    inputRange: [0, 1],
    outputRange: ['0deg', '360deg'],
  });

  const getCircleColor = () => {
    if (isSpeaking) return COLORS.SPEAKING;
    if (isProcessing) return COLORS.PROCESSING;
    if (isRecording) return COLORS.RECORDING;
    return COLORS.PRIMARY;
  };

  const getIcon = () => {
    const iconSize = 80;
    const iconColor = '#FFFFFF';

    if (isSpeaking) {
      return <Speaker size={iconSize} color={iconColor} />;
    }
    if (isProcessing) {
      return <Brain size={iconSize} color={iconColor} />;
    }
    if (isRecording) {
      return <Mic size={iconSize} color={iconColor} />;
    }
    return null;
  };

  return (
    <Animated.View
      style={[
        styles.container,
        {
          opacity: opacityAnim,
        },
      ]}
      pointerEvents="none"
    >
      <Animated.View
        style={[
          styles.circleContainer,
          {
            transform: [
              { scale },
              { rotate: isProcessing ? rotation : '0deg' },
            ],
          },
        ]}
      >
        <View style={[styles.circle, { borderColor: getCircleColor() }]} />
      </Animated.View>
      
      <View style={styles.iconContainer}>
        {getIcon()}
      </View>
    </Animated.View>
  );
};

const styles = StyleSheet.create({
  container: {
    position: 'absolute',
    top: '35%',
    left: '50%',
    marginLeft: -CIRCLE_SIZE / 2,
    width: CIRCLE_SIZE,
    height: CIRCLE_SIZE,
    justifyContent: 'center',
    alignItems: 'center',
  },
  circleContainer: {
    position: 'absolute',
    width: CIRCLE_SIZE,
    height: CIRCLE_SIZE,
    justifyContent: 'center',
    alignItems: 'center',
  },
  circle: {
    width: CIRCLE_SIZE,
    height: CIRCLE_SIZE,
    borderRadius: CIRCLE_SIZE / 2,
    borderWidth: 3,
    backgroundColor: 'rgba(255, 255, 255, 0.05)',
  },
  iconContainer: {
    zIndex: 10,
    justifyContent: 'center',
    alignItems: 'center',
  },
});

export default VisualFeedback;