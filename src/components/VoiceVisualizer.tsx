/**
//  * src/components/VoiceVisualizer.tsx
//  * 
//  * WCAG 2.1 AA Compliant Voice Visualizer
//  * 
//  * UPDATED: Added isReaching prop for reaching/guidance mode (Jan 26, 2026)
//  * 
//  * Compliance Features:
//  * - 1.1.1 Non-text Content: Status conveyed via text AND accessibility labels
//  * - 1.3.1 Info and Relationships: Proper semantic structure with roles
//  * - 4.1.2 Name, Role, Value: All elements have proper accessibility props
//  * - 4.1.3 Status Messages: Live regions announce status changes
//  * - Decorative animations hidden from screen readers
//  
*/

import React, { useEffect, useRef } from 'react';
import {
  View,
  Text,
  StyleSheet,
  Animated,
  Dimensions,
  AccessibilityInfo,
  Easing,
} from 'react-native';
import { Mic, MicOff, Speaker, Brain } from './Icons';
import { COLORS } from '../utils/constants';

const { width } = Dimensions.get('window');
const CIRCLE_SIZE = width * 0.62;
const NUM_BARS = 56;
const INNER_RADIUS = CIRCLE_SIZE * 0.36;
const MAX_BAR_LENGTH = 42;
const BAR_WIDTH = 3.5;

interface VoiceVisualizerProps {
  isListening: boolean;
  isProcessing: boolean;
  isSpeaking: boolean;
  isNavigation?: boolean;
  isReaching?: boolean;
  transcript: string;
  pulseAnim: Animated.Value;
  opacityAnim: Animated.Value;
  audioLevel?: number;
}

// Simple icons
const NavigationIcon = ({ size, color }: { size: number; color: string }) => (
  <View style={{ width: size, height: size, justifyContent: 'center', alignItems: 'center' }}>
    <View style={{
      width: 0, height: 0,
      borderLeftWidth: size * 0.28, borderRightWidth: size * 0.28, borderBottomWidth: size * 0.55,
      borderLeftColor: 'transparent', borderRightColor: 'transparent', borderBottomColor: color,
    }} />
    <View style={{ width: size * 0.11, height: size * 0.22, backgroundColor: color, marginTop: -3 }} />
  </View>
);

const ReachingIcon = ({ size, color }: { size: number; color: string }) => (
  <View style={{ width: size, height: size, justifyContent: 'center', alignItems: 'center' }}>
    <View style={{ width: size * 0.75, height: size * 0.75, borderRadius: size * 0.375, borderWidth: 2, borderColor: color, position: 'absolute' }} />
    <View style={{ width: size * 0.45, height: size * 0.45, borderRadius: size * 0.225, borderWidth: 2, borderColor: color, position: 'absolute' }} />
    <View style={{ width: size * 0.18, height: size * 0.18, borderRadius: size * 0.09, backgroundColor: color, position: 'absolute' }} />
  </View>
);

export const VoiceVisualizer: React.FC<VoiceVisualizerProps> = ({
  isListening,
  isProcessing,
  isSpeaking,
  isNavigation = false,
  isReaching = false,
  transcript,
  pulseAnim,
  opacityAnim,
  audioLevel = 0,
}) => {
  const rotateAnim = useRef(new Animated.Value(0)).current;
  const previousState = useRef('');
  
  // Animated scale for each bar (0 to 1)
  const barScales = useRef<Animated.Value[]>(
    Array.from({ length: NUM_BARS }, () => new Animated.Value(0.15))
  ).current;
  
  const animFrameRef = useRef<number | null>(null);

  const getStatusText = () => {
    if (isReaching) return 'Reaching';
    if (isNavigation) return 'Navigating';
    if (isSpeaking) return 'Speaking';
    if (isProcessing) return 'Thinking';
    if (isListening) return 'Listening';
    return 'Ready';
  };

  const getStatusColor = () => {
    if (isReaching) return COLORS.REACHING || '#9B59B6';
    if (isNavigation) return COLORS.NAVIGATION || '#FF6B35';
    if (isSpeaking) return '#4CAF50';
    if (isProcessing) return '#FFC107';
    if (isListening) return '#2196F3';
    return '#555';
  };

  const getInstructionText = () => {
    if (isReaching || isNavigation) return 'Tap to stop';
    if (isSpeaking || isProcessing) return 'Tap to interrupt';
    if (isListening) return 'Speak naturally, tap to stop';
    return 'Tap to speak';
  };

  // Announce state changes
  useEffect(() => {
    const currentState = getStatusText();
    if (currentState !== previousState.current && previousState.current !== '') {
      AccessibilityInfo.announceForAccessibility(`${currentState}. ${getInstructionText()}`);
    }
    previousState.current = currentState;
  }, [isListening, isProcessing, isSpeaking, isNavigation, isReaching]);

  // Slow rotation for processing/navigation/reaching
  useEffect(() => {
    if (isProcessing || isNavigation || isReaching) {
      Animated.loop(
        Animated.timing(rotateAnim, {
          toValue: 1,
          duration: isReaching ? 8000 : isNavigation ? 10000 : 6000,
          easing: Easing.linear,
          useNativeDriver: true,
        })
      ).start();
    } else {
      rotateAnim.stopAnimation();
      rotateAnim.setValue(0);
    }
  }, [isProcessing, isNavigation, isReaching, rotateAnim]);

  // Bar animation loop
  useEffect(() => {
    const isActive = isListening || isProcessing || isSpeaking || isNavigation || isReaching;
    
    if (!isActive) {
      barScales.forEach(scale => {
        Animated.timing(scale, { toValue: 0.15, duration: 400, useNativeDriver: true }).start();
      });
      if (animFrameRef.current) cancelAnimationFrame(animFrameRef.current);
      return;
    }

    const animate = () => {
      const t = Date.now() * 0.001;
      
      barScales.forEach((scale, i) => {
        const angle = (i / NUM_BARS) * Math.PI * 2;
        let value = 0.15;
        
        if (isListening) {
          // Organic, voice-reactive pattern
          value = 0.25 + 
            Math.sin(t * 4 + angle * 3) * 0.22 +
            Math.sin(t * 7 + i * 0.4) * 0.18 +
            Math.sin(t * 2.5 + angle * 2) * 0.15;
        } else if (isProcessing) {
          // Smooth wave traveling around
          value = 0.35 + Math.sin(angle - t * 2.5) * 0.35;
        } else if (isSpeaking) {
          // Rhythmic pulse
          value = 0.4 + Math.sin(t * 5 + angle * 2) * 0.28 + Math.sin(t * 2) * 0.12;
        } else if (isNavigation) {
          // Directional with forward emphasis
          value = 0.3 + Math.cos(angle) * 0.2 + Math.sin(angle - t * 1.8) * 0.22;
        } else if (isReaching) {
          // Radar ping sweep
          const sweep = (t * 1.5) % (Math.PI * 2);
          const diff = Math.min(Math.abs(angle - sweep), Math.PI * 2 - Math.abs(angle - sweep));
          value = 0.2 + Math.max(0, 1 - diff / 0.7) * 0.55;
        }
        
        scale.setValue(Math.max(0.1, Math.min(1, value)));
      });
      
      animFrameRef.current = requestAnimationFrame(animate);
    };
    
    animate();
    return () => { if (animFrameRef.current) cancelAnimationFrame(animFrameRef.current); };
  }, [isListening, isProcessing, isSpeaking, isNavigation, isReaching, barScales]);

  const rotation = rotateAnim.interpolate({
    inputRange: [0, 1],
    outputRange: ['0deg', '360deg'],
  });

  const statusColor = getStatusColor();

  // Pre-calculate bar positions - bars are positioned at their CENTER along the radial line
  const barPositions = React.useMemo(() => {
    const centerX = CIRCLE_SIZE / 2;
    const centerY = CIRCLE_SIZE / 2;
    
    return Array.from({ length: NUM_BARS }, (_, i) => {
      const angleDeg = (i / NUM_BARS) * 360;
      const angleRad = (angleDeg - 90) * (Math.PI / 180);
      
      // Position where the bar's CENTER should be
      // This is at INNER_RADIUS + half of MAX_BAR_LENGTH from the visualization center
      const barCenterDist = INNER_RADIUS + MAX_BAR_LENGTH / 2;
      const barCenterX = centerX + Math.cos(angleRad) * barCenterDist;
      const barCenterY = centerY + Math.sin(angleRad) * barCenterDist;
      
      return { 
        // Position so bar's center is at the calculated point
        // Since RN positions from top-left, we offset by half width and half height
        x: barCenterX - BAR_WIDTH / 2,
        y: barCenterY - MAX_BAR_LENGTH / 2,
        angleDeg 
      };
    });
  }, []);

  const renderIcon = () => {
    const size = 65;
    if (isReaching) return <ReachingIcon size={size} color={COLORS.REACHING || '#9B59B6'} />;
    if (isNavigation) return <NavigationIcon size={size} color={COLORS.NAVIGATION || '#FF6B35'} />;
    if (isSpeaking) return <Speaker size={size} color="#4CAF50" />;
    if (isProcessing) return <Brain size={size} color="#FFC107" />;
    if (isListening) return <Mic size={size} color="#2196F3" />;
    return <MicOff size={size} color="#555" />;
  };

  return (
    <View style={styles.container} accessible accessibilityLabel={`${getStatusText()}. ${getInstructionText()}`} accessibilityRole="text" accessibilityLiveRegion="polite">
      
      <View style={styles.visualizer} accessible={false} importantForAccessibility="no-hide-descendants">
        
        {/* Outer glow */}
        <Animated.View style={[styles.outerGlow, { borderColor: statusColor, opacity: opacityAnim, transform: [{ scale: pulseAnim }] }]} />
        
        {/* Bars container */}
        <Animated.View style={[styles.barsContainer, { transform: [{ rotate: (isProcessing || isNavigation || isReaching) ? rotation : '0deg' }] }]}>
          {barPositions.map((pos, i) => (
            <Animated.View
              key={i}
              style={{
                position: 'absolute',
                width: BAR_WIDTH,
                height: MAX_BAR_LENGTH,
                left: pos.x,
                top: pos.y,
                backgroundColor: statusColor,
                borderRadius: BAR_WIDTH / 2,
                opacity: 0.88,
                transform: [
                  { scaleY: barScales[i] }, // Scale FIRST (along bar's length)
                  { rotate: `${pos.angleDeg}deg` }, // Then rotate to face outward
                ],
              }}
            />
          ))}
        </Animated.View>
        
        {/* Inner circle */}
        <View style={[styles.innerCircle, { borderColor: statusColor }]} />
        
        {/* Icon */}
        <View style={styles.iconContainer}>{renderIcon()}</View>
      </View>

      <Text style={[styles.statusText, { color: statusColor }]}>{getStatusText()}</Text>

      {transcript && isListening && !isNavigation && !isReaching && (
        <View style={styles.transcriptBox}>
          <Text style={styles.transcriptText}>{transcript}</Text>
        </View>
      )}

      <Text style={styles.instructionText}>{getInstructionText()}</Text>
    </View>
  );
};

const styles = StyleSheet.create({
  container: { flex: 1, justifyContent: 'center', alignItems: 'center' },
  visualizer: { width: CIRCLE_SIZE, height: CIRCLE_SIZE, justifyContent: 'center', alignItems: 'center' },
  outerGlow: {
    position: 'absolute',
    width: CIRCLE_SIZE + 25,
    height: CIRCLE_SIZE + 25,
    borderRadius: (CIRCLE_SIZE + 25) / 2,
    borderWidth: 1.5,
  },
  barsContainer: { position: 'absolute', width: CIRCLE_SIZE, height: CIRCLE_SIZE },
  innerCircle: {
    position: 'absolute',
    width: INNER_RADIUS * 2,
    height: INNER_RADIUS * 2,
    borderRadius: INNER_RADIUS,
    borderWidth: 1.5,
    backgroundColor: 'rgba(0,0,0,0.5)',
  },
  iconContainer: { position: 'absolute' },
  statusText: { marginTop: 28, fontSize: 26, fontWeight: '600', letterSpacing: 1.2 },
  transcriptBox: {
    position: 'absolute', bottom: 105, left: 20, right: 20,
    backgroundColor: 'rgba(33,150,243,0.12)', padding: 16, borderRadius: 12,
    borderLeftWidth: 3, borderLeftColor: '#2196F3',
  },
  transcriptText: { color: '#fff', fontSize: 17, lineHeight: 23 },
  instructionText: { position: 'absolute', bottom: 42, color: '#777', fontSize: 15, letterSpacing: 0.4 },
});

export default VoiceVisualizer;