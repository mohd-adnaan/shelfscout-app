/**
 * src/components/VisualFeedback.tsx
 * 
 * WCAG 2.1 AA Compliant Visual Feedback Component
 * 
 * Compliance Features:
 * - 1.1.1 Non-text Content: Pure decoration, hidden from screen readers
 * - This component provides ONLY visual feedback for sighted users
 * - Status is conveyed to blind users via VoiceVisualizer announcements
 * - All elements marked as decorative with accessible={false}
 * 
 * IMPORTANT: This component is completely hidden from assistive technologies
 * because it provides no information that isn't already conveyed through
 * text and accessibility announcements elsewhere in the app.
 */

import React, { useEffect, useRef } from 'react';
import { 
  View, 
  StyleSheet, 
  Animated, 
  Dimensions,
  AccessibilityInfo,
  Platform,
} from 'react-native';
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

/**
 * VisualFeedback Component
 * 
 * WCAG Compliance: This component is PURELY DECORATIVE
 * - Provides visual feedback for sighted/low-vision users
 * - Completely hidden from screen readers (accessible={false})
 * - Status information is conveyed via text and announcements elsewhere
 * - Respects reduce motion preference (WCAG 2.3.3)
 */
const VisualFeedback: React.FC<VisualFeedbackProps> = ({ 
  isActive, 
  isRecording = false,
  isProcessing = false,
  isSpeaking = false,
}) => {
  const pulseAnim = useRef(new Animated.Value(0)).current;
  const opacityAnim = useRef(new Animated.Value(0)).current;
  const rotateAnim = useRef(new Animated.Value(0)).current;
  const [reduceMotionEnabled, setReduceMotionEnabled] = React.useState(false);

  // ============================================================================
  // WCAG 2.3.3: Respect Reduce Motion Preference
  // ============================================================================
  useEffect(() => {
    const checkReduceMotion = async () => {
      const isEnabled = await AccessibilityInfo.isReduceMotionEnabled();
      setReduceMotionEnabled(isEnabled);
    };

    checkReduceMotion();

    const subscription = AccessibilityInfo.addEventListener(
      'reduceMotionChanged',
      setReduceMotionEnabled
    );

    return () => subscription?.remove();
  }, []);

  useEffect(() => {
    if (isActive) {
      // Fade in
      Animated.timing(opacityAnim, {
        toValue: 1,
        duration: reduceMotionEnabled ? 100 : 300, // Faster if reduce motion
        useNativeDriver: true,
      }).start();

      if (!reduceMotionEnabled) {
        // Only animate if reduce motion is NOT enabled
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
        // Reduce motion enabled - no animations
        pulseAnim.setValue(0);
        rotateAnim.setValue(0);
      }
    } else {
      // Fade out
      Animated.timing(opacityAnim, {
        toValue: 0,
        duration: reduceMotionEnabled ? 100 : 300,
        useNativeDriver: true,
      }).start();
      pulseAnim.setValue(0);
      rotateAnim.setValue(0);
    }
  }, [isActive, isProcessing, reduceMotionEnabled, pulseAnim, opacityAnim, rotateAnim]);

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
      return <Speaker size={iconSize} color={iconColor} accessible={false} />;
    }
    if (isProcessing) {
      return <Brain size={iconSize} color={iconColor} accessible={false} />;
    }
    if (isRecording) {
      return <Mic size={iconSize} color={iconColor} accessible={false} />;
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
      // ================================================================
      // WCAG 1.1.1: Pure decoration - Hidden from screen readers
      // ================================================================
      accessible={false}
      importantForAccessibility="no-hide-descendants"
      accessibilityElementsHidden={true} // iOS
    >
      <Animated.View
        style={[
          styles.circleContainer,
          {
            transform: [
              { scale: reduceMotionEnabled ? 1 : scale },
              { rotate: isProcessing && !reduceMotionEnabled ? rotation : '0deg' },
            ],
          },
        ]}
        accessible={false}
      >
        <View 
          style={[styles.circle, { borderColor: getCircleColor() }]}
          accessible={false}
        />
      </Animated.View>
      
      <View 
        style={styles.iconContainer}
        accessible={false}
      >
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