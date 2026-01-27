/**
 * src/components/VoiceVisualizer.tsx
 * 
 * WCAG 2.1 AA Compliant Voice Visualizer
 * 
 * UPDATED: Added isReaching prop for reaching/guidance mode (Jan 26, 2026)
 * 
 * Compliance Features:
 * - 1.1.1 Non-text Content: Status conveyed via text AND accessibility labels
 * - 1.3.1 Info and Relationships: Proper semantic structure with roles
 * - 4.1.2 Name, Role, Value: All elements have proper accessibility props
 * - 4.1.3 Status Messages: Live regions announce status changes
 * - Decorative animations hidden from screen readers
 */

import React, { useEffect, useRef } from 'react';
import {
  View,
  Text,
  StyleSheet,
  Animated,
  Dimensions,
  AccessibilityInfo,
} from 'react-native';
import { Mic, MicOff, Speaker, Brain } from './Icons';
import { COLORS } from '../utils/constants';

const { width, height } = Dimensions.get('window');
const CIRCLE_SIZE = width * 0.55;

interface VoiceVisualizerProps {
  isListening: boolean;
  isProcessing: boolean;
  isSpeaking: boolean;
  /** Navigation loop active state */
  isNavigation?: boolean;
  /** Reaching/guidance loop active state (NEW) */
  isReaching?: boolean;
  transcript: string;
  pulseAnim: Animated.Value;
  opacityAnim: Animated.Value;
}

// Navigation icon component
const NavigationIcon: React.FC<{ size: number; color: string; accessible?: boolean }> = ({ 
  size, 
  color, 
  accessible = false 
}) => {
  return (
    <View 
      style={{
        width: size,
        height: size,
        justifyContent: 'center',
        alignItems: 'center',
      }}
      accessible={accessible}
    >
      <View
        style={{
          width: 0,
          height: 0,
          borderLeftWidth: size * 0.35,
          borderRightWidth: size * 0.35,
          borderBottomWidth: size * 0.7,
          borderLeftColor: 'transparent',
          borderRightColor: 'transparent',
          borderBottomColor: color,
          transform: [{ rotate: '0deg' }],
        }}
      />
      <View
        style={{
          width: size * 0.15,
          height: size * 0.3,
          backgroundColor: color,
          marginTop: -5,
        }}
      />
    </View>
  );
};

// Reaching/Target icon component (NEW)
const ReachingIcon: React.FC<{ size: number; color: string; accessible?: boolean }> = ({ 
  size, 
  color, 
  accessible = false 
}) => {
  return (
    <View 
      style={{
        width: size,
        height: size,
        justifyContent: 'center',
        alignItems: 'center',
      }}
      accessible={accessible}
    >
      {/* Concentric circles representing target/reaching */}
      <View
        style={{
          width: size * 0.8,
          height: size * 0.8,
          borderRadius: (size * 0.8) / 2,
          borderWidth: 3,
          borderColor: color,
          position: 'absolute',
        }}
      />
      <View
        style={{
          width: size * 0.5,
          height: size * 0.5,
          borderRadius: (size * 0.5) / 2,
          borderWidth: 3,
          borderColor: color,
          position: 'absolute',
        }}
      />
      <View
        style={{
          width: size * 0.2,
          height: size * 0.2,
          borderRadius: (size * 0.2) / 2,
          backgroundColor: color,
          position: 'absolute',
        }}
      />
    </View>
  );
};

export const VoiceVisualizer: React.FC<VoiceVisualizerProps> = ({
  isListening,
  isProcessing,
  isSpeaking,
  isNavigation = false,
  isReaching = false,
  transcript,
  pulseAnim,
  opacityAnim,
}) => {
  const rotateAnim = useRef(new Animated.Value(0)).current;
  const dotsOpacity = useRef(new Animated.Value(0)).current;
  const previousState = useRef<string>('');

  // ============================================================================
  // WCAG 4.1.3: Announce Status Changes
  // ============================================================================
  useEffect(() => {
    const currentState = getStatusText();
    
    if (currentState !== previousState.current && previousState.current !== '') {
      AccessibilityInfo.announceForAccessibility(
        `${currentState}. ${getInstructionText()}`
      );
    }
    
    previousState.current = currentState;
  }, [isListening, isProcessing, isSpeaking, isNavigation, isReaching]);

  // Rotating animation for processing, navigation, or reaching states
  useEffect(() => {
    if (isProcessing || isNavigation || isReaching) {
      // Different rotation speeds for different modes
      const duration = isReaching ? 2500 : isNavigation ? 3000 : 2000;
      
      Animated.loop(
        Animated.timing(rotateAnim, {
          toValue: 1,
          duration,
          useNativeDriver: true,
        })
      ).start();
      
      Animated.timing(dotsOpacity, {
        toValue: 1,
        duration: 300,
        useNativeDriver: true,
      }).start();
    } else {
      rotateAnim.setValue(0);
      Animated.timing(dotsOpacity, {
        toValue: 0,
        duration: 300,
        useNativeDriver: true,
      }).start();
    }
  }, [isProcessing, isNavigation, isReaching]);

  const rotation = rotateAnim.interpolate({
    inputRange: [0, 1],
    outputRange: ['0deg', '360deg'],
  });

  // Generate dots for the circle (PURELY DECORATIVE)
  const renderDots = () => {
    const dots = [];
    const numberOfDots = 60;
    
    for (let i = 0; i < numberOfDots; i++) {
      const angle = (i * 360) / numberOfDots;
      
      dots.push(
        <View
          key={i}
          accessible={false}
          style={[
            styles.dot,
            {
              transform: [
                { rotate: `${angle}deg` },
                { translateY: -CIRCLE_SIZE / 2 },
              ],
              backgroundColor: isReaching 
                ? COLORS.REACHING 
                : isNavigation 
                ? COLORS.NAVIGATION 
                : '#fff',
            },
          ]}
        />
      );
    }
    
    return dots;
  };

  const getStatusText = () => {
    if (isReaching) return 'Reaching';
    if (isNavigation) return 'Navigating';
    if (isSpeaking) return 'Speaking';
    if (isProcessing) return 'Thinking';
    if (isListening) return 'Listening';
    return 'Ready';
  };

  const getStatusColor = () => {
    if (isReaching) return COLORS.REACHING;
    if (isNavigation) return COLORS.NAVIGATION;
    if (isSpeaking) return '#4CAF50';
    if (isProcessing) return '#FFC107';
    if (isListening) return '#2196F3';
    return '#666';
  };

  const getInstructionText = () => {
    if (isReaching) return 'Tap to stop reaching';
    if (isNavigation) return 'Tap to stop navigation';
    if (isSpeaking || isProcessing) return 'Tap to interrupt';
    if (isListening) return 'Speak naturally, tap to stop';
    return 'Tap to speak';
  };

  // WCAG 4.1.2: Generate comprehensive accessibility label
  const getAccessibilityLabel = () => {
    const status = getStatusText();
    const instruction = getInstructionText();
    
    if (isReaching) {
      return `${status}. Guiding you to the object. ${instruction}`;
    }
    
    if (isNavigation) {
      return `${status}. Guiding you to your destination. ${instruction}`;
    }
    
    if (transcript && isListening) {
      return `${status}. You said: ${transcript}. ${instruction}`;
    }
    
    return `${status}. ${instruction}`;
  };

  // Get the appropriate icon based on state
  const renderIcon = () => {
    if (isReaching) {
      return <ReachingIcon size={80} color={COLORS.REACHING} accessible={false} />;
    }
    if (isNavigation) {
      return <NavigationIcon size={80} color={COLORS.NAVIGATION} accessible={false} />;
    }
    if (isSpeaking) {
      return <Speaker size={80} color="#4CAF50" accessible={false} />;
    }
    if (isProcessing) {
      return <Brain size={80} color="#FFC107" accessible={false} />;
    }
    if (isListening) {
      return <Mic size={80} color="#2196F3" accessible={false} />;
    }
    return <MicOff size={80} color="#666" accessible={false} />;
  };

  return (
    <View 
      style={styles.container}
      accessible={true}
      accessibilityLabel={getAccessibilityLabel()}
      accessibilityRole="text"
      accessibilityLiveRegion="polite"
    >
      {/* ================================================================ */}
      {/* DECORATIVE VISUAL ELEMENTS */}
      {/* ================================================================ */}
      <View 
        style={styles.circleWrapper}
        accessible={false}
        importantForAccessibility="no-hide-descendants"
      >
        <Animated.View
          style={[
            styles.circleContainer,
            {
              transform: [
                { scale: pulseAnim },
                { rotate: (isProcessing || isNavigation || isReaching) ? rotation : '0deg' },
              ],
            },
          ]}
          accessible={false}
        >
          <Animated.View 
            style={[
              styles.dotsCircle,
              { opacity: dotsOpacity }
            ]}
            accessible={false}
          >
            {renderDots()}
          </Animated.View>
          
          <Animated.View
            style={[
              styles.circle,
              {
                opacity: opacityAnim,
                borderColor: getStatusColor(),
              },
            ]}
            accessible={false}
          />
        </Animated.View>

        <View 
          style={styles.centerIcon}
          accessible={false}
        >
          {renderIcon()}
        </View>
      </View>

      {/* ================================================================ */}
      {/* ACCESSIBLE TEXT ELEMENTS */}
      {/* ================================================================ */}

      {/* Status text */}
      <Text 
        style={[styles.statusText, { color: getStatusColor() }]}
        accessible={true}
        accessibilityRole="text"
        accessibilityLabel={`Status: ${getStatusText()}`}
      >
        {getStatusText()}
      </Text>

      {/* Reaching indicator */}
      {isReaching && (
        <View 
          style={styles.reachingIndicator}
          accessible={true}
          accessibilityRole="text"
          accessibilityLabel="Object guidance in progress"
        >
          <Text style={styles.reachingText}>
            Reaching...
          </Text>
        </View>
      )}

      {/* Navigation indicator */}
      {isNavigation && (
        <View 
          style={styles.navigationIndicator}
          accessible={true}
          accessibilityRole="text"
          accessibilityLabel="Navigation in progress"
        >
          <Text style={styles.navigationText}>
            Guiding you...
          </Text>
        </View>
      )}

      {/* Transcript display */}
      {transcript && isListening && !isNavigation && !isReaching && (
        <View 
          style={styles.transcriptContainer}
          accessible={true}
          accessibilityRole="text"
          accessibilityLiveRegion="polite"
          accessibilityLabel={`Transcript: ${transcript}`}
        >
          <Text style={styles.transcriptText}>{transcript}</Text>
        </View>
      )}

      {/* Instruction text */}
      <Text 
        style={styles.instructionText}
        accessible={true}
        accessibilityRole="text"
        accessibilityLabel={`Instructions: ${getInstructionText()}`}
      >
        {getInstructionText()}
      </Text>
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  
  // Decorative elements
  circleWrapper: {
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
  dotsCircle: {
    position: 'absolute',
    width: CIRCLE_SIZE,
    height: CIRCLE_SIZE,
  },
  dot: {
    position: 'absolute',
    width: 4,
    height: 4,
    borderRadius: 2,
    backgroundColor: '#fff',
    top: '50%',
    left: '50%',
    marginLeft: -2,
    marginTop: -2,
  },
  circle: {
    position: 'absolute',
    width: CIRCLE_SIZE,
    height: CIRCLE_SIZE,
    borderRadius: CIRCLE_SIZE / 2,
    borderWidth: 2,
    backgroundColor: 'rgba(255, 255, 255, 0.05)',
  },
  centerIcon: {
    position: 'absolute',
    top: '50%',
    left: '50%',
    transform: [
      { translateX: -40 },
      { translateY: -40 },
    ],
    zIndex: 10,
  },
  
  // Accessible text elements
  statusText: {
    marginTop: 40,
    fontSize: 24,
    fontWeight: '600',
    color: '#fff',
  },
  
  // Reaching indicator styles
  reachingIndicator: {
    marginTop: 10,
    paddingHorizontal: 20,
    paddingVertical: 8,
    backgroundColor: 'rgba(155, 89, 182, 0.2)',
    borderRadius: 20,
    borderWidth: 1,
    borderColor: COLORS.REACHING,
  },
  reachingText: {
    color: COLORS.REACHING,
    fontSize: 16,
    fontWeight: '500',
  },
  
  // Navigation indicator styles
  navigationIndicator: {
    marginTop: 10,
    paddingHorizontal: 20,
    paddingVertical: 8,
    backgroundColor: 'rgba(255, 107, 53, 0.2)',
    borderRadius: 20,
    borderWidth: 1,
    borderColor: COLORS.NAVIGATION,
  },
  navigationText: {
    color: COLORS.NAVIGATION,
    fontSize: 16,
    fontWeight: '500',
  },
  
  transcriptContainer: {
    position: 'absolute',
    bottom: 100,
    left: 20,
    right: 20,
    backgroundColor: 'rgba(33, 150, 243, 0.2)',
    padding: 20,
    borderRadius: 15,
    borderLeftWidth: 4,
    borderLeftColor: '#2196F3',
  },
  transcriptText: {
    color: '#fff',
    fontSize: 18,
    lineHeight: 24,
  },
  instructionText: {
    position: 'absolute',
    bottom: 40,
    color: '#999',
    fontSize: 14,
    textAlign: 'center',
  },
});

export default VoiceVisualizer;