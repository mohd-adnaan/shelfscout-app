import React, { useEffect, useRef } from 'react';
import {
  View,
  Text,
  StyleSheet,
  Animated,
  Dimensions,
} from 'react-native';
import { Mic, MicOff, Loader } from './Icons';

const { width, height } = Dimensions.get('window');
const CIRCLE_SIZE = width * 0.6;

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

  // Rotating animation for processing state
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

  // Generate dots for the circle
  const renderDots = () => {
    const dots = [];
    const numberOfDots = 60;
    
    for (let i = 0; i < numberOfDots; i++) {
      const angle = (i * 360) / numberOfDots;
      
      dots.push(
        <View
          key={i}
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
    if (isSpeaking) return 'Speaking...';
    if (isProcessing) return 'Processing...';
    if (isListening) return 'Listening...';
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
      return 'Tap to stop & process';
    }
    return 'Tap to speak';
  };

  return (
    <View style={styles.container}>
      {/* Main animated circle */}
      <Animated.View
        style={[
          styles.circleContainer,
          {
            transform: [
              { scale: pulseAnim },
              { rotate: rotation },
            ],
          },
        ]}
      >
        {/* Dotted circle */}
        <Animated.View 
          style={[
            styles.dotsCircle,
            { opacity: dotsOpacity }
          ]}
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
        />
        
        {/* Center icon */}
        <View style={styles.centerIcon}>
          {isProcessing ? (
            <Loader size={60} color="#FFC107" />
          ) : isListening ? (
            <Mic size={60} color="#2196F3" />
          ) : (
            <MicOff size={60} color="#666" />
          )}
        </View>
      </Animated.View>

      {/* Status text */}
      <Text style={[styles.statusText, { color: getStatusColor() }]}>
        {getStatusText()}
      </Text>

      {/* Transcript display */}
      {transcript && isListening && (
        <View style={styles.transcriptContainer}>
          <Text style={styles.transcriptText}>{transcript}</Text>
        </View>
      )}

      {/* Instruction text */}
      <Text style={styles.instructionText}>
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
  circleContainer: {
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
    zIndex: 10,
  },
  statusText: {
    marginTop: 40,
    fontSize: 24,
    fontWeight: '600',
    color: '#fff',
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