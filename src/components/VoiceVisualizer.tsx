/**
 * src/components/VoiceVisualizer.tsx
 * 
 * WCAG 2.1 AA Compliant Voice Visualizer
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

const { width, height } = Dimensions.get('window');
const CIRCLE_SIZE = width * 0.55;

interface VoiceVisualizerProps {
  isListening: boolean;
  isProcessing: boolean;
  isSpeaking: boolean;
  transcript: string;
  pulseAnim: Animated.Value;
  opacityAnim: Animated.Value;
}

export const VoiceVisualizer: React.FC<VoiceVisualizerProps> = ({
  isListening,
  isProcessing,
  isSpeaking,
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
    
    // Only announce if state actually changed
    if (currentState !== previousState.current && previousState.current !== '') {
      AccessibilityInfo.announceForAccessibility(
        `${currentState}. ${getInstructionText()}`
      );
    }
    
    previousState.current = currentState;
  }, [isListening, isProcessing, isSpeaking]);

  // Rotating animation for processing state ONLY
  useEffect(() => {
    if (isProcessing) {
      Animated.loop(
        Animated.timing(rotateAnim, {
          toValue: 1,
          duration: 2000,
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
  }, [isProcessing]);

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
          // WCAG 1.1.1: Decorative element
          accessible={false}
          style={[
            styles.dot,
            {
              transform: [
                { rotate: `${angle}deg` },
                { translateY: -CIRCLE_SIZE / 2 },
              ],
            },
          ]}
        />
      );
    }
    
    return dots;
  };

  const getStatusText = () => {
    if (isSpeaking) return 'Speaking';
    if (isProcessing) return 'Thinking';
    if (isListening) return 'Listening';
    return 'Ready';
  };

  const getStatusColor = () => {
    if (isSpeaking) return '#4CAF50';
    if (isProcessing) return '#FFC107';
    if (isListening) return '#2196F3';
    return '#666';
  };

  const getInstructionText = () => {
    if (isSpeaking || isProcessing) {
      return 'Double-tap to interrupt';
    }
    if (isListening) {
      return 'Tap to stop and process';
    }
    return 'Tap to speak';
  };

  // WCAG 4.1.2: Generate comprehensive accessibility label
  const getAccessibilityLabel = () => {
    const status = getStatusText();
    const instruction = getInstructionText();
    
    if (transcript && isListening) {
      return `${status}. You said: ${transcript}. ${instruction}`;
    }
    
    return `${status}. ${instruction}`;
  };

  return (
    <View 
      style={styles.container}
      // WCAG 4.1.2: Main container has comprehensive label
      accessible={true}
      accessibilityLabel={getAccessibilityLabel()}
      accessibilityRole="text"
      // WCAG 4.1.3: Status updates announced
      accessibilityLiveRegion="polite"
    >
      {/* ================================================================ */}
      {/* DECORATIVE VISUAL ELEMENTS - HIDDEN FROM SCREEN READERS */}
      {/* WCAG 1.1.1: Pure decoration, not needed for blind users */}
      {/* ================================================================ */}
      <View 
        style={styles.circleWrapper}
        accessible={false}
        importantForAccessibility="no-hide-descendants"
      >
        {/* Main animated circle - ONLY rotates during processing */}
        <Animated.View
          style={[
            styles.circleContainer,
            {
              transform: [
                { scale: pulseAnim },
                { rotate: isProcessing ? rotation : '0deg' },
              ],
            },
          ]}
          accessible={false}
        >
          {/* Dotted circle */}
          <Animated.View 
            style={[
              styles.dotsCircle,
              { opacity: dotsOpacity }
            ]}
            accessible={false}
          >
            {renderDots()}
          </Animated.View>
          
          {/* Solid circle background */}
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

        {/* Center icon - DECORATIVE, status conveyed by text */}
        <View 
          style={styles.centerIcon}
          accessible={false}
        >
          {isSpeaking ? (
            <Speaker size={80} color="#4CAF50" accessible={false} />
          ) : isProcessing ? (
            <Brain size={80} color="#FFC107" accessible={false} />
          ) : isListening ? (
            <Mic size={80} color="#2196F3" accessible={false} />
          ) : (
            <MicOff size={80} color="#666" accessible={false} />
          )}
        </View>
      </View>

      {/* ================================================================ */}
      {/* ACCESSIBLE TEXT ELEMENTS - READ BY SCREEN READERS */}
      {/* ================================================================ */}

      {/* Status text - WCAG 4.1.2, 4.1.3 */}
      <Text 
        style={[styles.statusText, { color: getStatusColor() }]}
        accessible={true}
        accessibilityRole="text"
        accessibilityLabel={`Status: ${getStatusText()}`}
      >
        {getStatusText()}
      </Text>

      {/* Transcript display - WCAG 4.1.3 (Live Region) */}
      {transcript && isListening && (
        <View 
          style={styles.transcriptContainer}
          accessible={true}
          accessibilityRole="text"
          // WCAG 4.1.3: Live region for transcript updates
          accessibilityLiveRegion="polite"
          accessibilityLabel={`Transcript: ${transcript}`}
        >
          <Text style={styles.transcriptText}>{transcript}</Text>
        </View>
      )}

      {/* Instruction text - WCAG 3.3.2 (Labels or Instructions) */}
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
  
  // ============================================================
  // DECORATIVE ELEMENTS (Hidden from screen readers)
  // ============================================================
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
  
  // ============================================================
  // ACCESSIBLE TEXT ELEMENTS
  // WCAG 1.4.3: Minimum 4.5:1 contrast for text
  // ============================================================
  statusText: {
    marginTop: 40,
    fontSize: 24,
    fontWeight: '600',
    color: '#fff', // Will be overridden by dynamic color
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