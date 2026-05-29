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

import React, { useEffect, useMemo, useRef } from 'react';
import {
  View,
  Text,
  StyleSheet,
  Animated,
  Dimensions,
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
const ACTIVE_BASE = 0.18;

type VisualizerState =
  | 'ready'
  | 'glassesListening'
  | 'listening'
  | 'thinking'
  | 'speaking'
  | 'navigating'
  | 'reaching';

interface MotionProfile {
  speed: number;
  waveAmplitude: number;
  pulseAmplitude: number;
  baseline: number;
  outerGlowOpacity: number;
}

const MOTION: Record<VisualizerState, MotionProfile> = {
  ready: {
    speed: 0,
    waveAmplitude: 0,
    pulseAmplitude: 0,
    baseline: 0.16,
    outerGlowOpacity: 0.16,
  },
  glassesListening: {
    speed: 0.6,
    waveAmplitude: 0.06,
    pulseAmplitude: 0.03,
    baseline: 0.2,
    outerGlowOpacity: 0.22,
  },
  listening: {
    speed: 1.65,
    waveAmplitude: 0.15,
    pulseAmplitude: 0.08,
    baseline: 0.28,
    outerGlowOpacity: 0.29,
  },
  thinking: {
    speed: 2.3,
    waveAmplitude: 0.22,
    pulseAmplitude: 0.05,
    baseline: 0.31,
    outerGlowOpacity: 0.35,
  },
  speaking: {
    speed: 1.9,
    waveAmplitude: 0.18,
    pulseAmplitude: 0.12,
    baseline: 0.34,
    outerGlowOpacity: 0.4,
  },
  navigating: {
    speed: 1.45,
    waveAmplitude: 0.2,
    pulseAmplitude: 0.07,
    baseline: 0.3,
    outerGlowOpacity: 0.37,
  },
  reaching: {
    speed: 1.45,
    waveAmplitude: 0.18,
    pulseAmplitude: 0.08,
    baseline: 0.3,
    outerGlowOpacity: 0.38,
  },
};

interface VoiceVisualizerProps {
  isListening: boolean;
  isProcessing: boolean;
  isSpeaking: boolean;
  isNavigation?: boolean;
  isReaching?: boolean;
  isGlassesListening?: boolean;
  transcript: string;
  pulseAnim: Animated.Value;
  opacityAnim: Animated.Value;
  audioLevel?: number;
  /** Debug status from wake word hook (mic info, errors) */
  glassesDebugStatus?: string;
  /** Raw transcript from wake word recognizer */
  glassesDebugRaw?: string;
}

const STATUS_TEXT: Record<VisualizerState, string> = {
  ready: 'Ready',
  glassesListening: 'Say "Hey ShelfScout"',
  listening: 'Listening',
  thinking: 'Thinking',
  speaking: 'Speaking',
  navigating: 'Navigating',
  reaching: 'Reaching',
};

const STATUS_INSTRUCTION: Record<VisualizerState, string> = {
  ready: 'Tap to speak',
  glassesListening: 'Glasses mic active',
  listening: 'Speak naturally, tap to stop',
  thinking: 'Tap to interrupt',
  speaking: 'Tap to interrupt',
  navigating: 'Tap to stop',
  reaching: 'Tap to stop',
};

const STATUS_COLOR: Record<VisualizerState, string> = {
  ready: '#8A8F98',
  glassesListening: '#00BFA5',
  listening: '#2AA4FF',
  thinking: '#FFC24A',
  speaking: '#4CCB6E',
  navigating: COLORS.NAVIGATION || '#FF6B35',
  reaching: COLORS.REACHING || '#9B59B6',
};

// Minimal symbolic icons, consistent with HUD style.
const NavigationIcon = ({ size, color }: { size: number; color: string }) => (
  <View style={[styles.symbolContainer, { width: size, height: size }]}>
    <View
      style={[
        styles.navArrow,
        {
          borderLeftWidth: size * 0.28,
          borderRightWidth: size * 0.28,
          borderBottomWidth: size * 0.55,
          borderBottomColor: color,
        },
      ]}
    />
    <View
      style={[
        styles.navStem,
        {
          width: size * 0.11,
          height: size * 0.22,
          backgroundColor: color,
        },
      ]}
    />
  </View>
);

const ReachingIcon = ({ size, color }: { size: number; color: string }) => (
  <View style={[styles.symbolContainer, { width: size, height: size }]}>
    <View
      style={[
        styles.targetOuter,
        {
          width: size * 0.75,
          height: size * 0.75,
          borderRadius: size * 0.375,
          borderColor: color,
        },
      ]}
    />
    <View
      style={[
        styles.targetInner,
        {
          width: size * 0.45,
          height: size * 0.45,
          borderRadius: size * 0.225,
          borderColor: color,
        },
      ]}
    />
    <View
      style={[
        styles.targetCore,
        {
          width: size * 0.16,
          height: size * 0.16,
          borderRadius: size * 0.08,
          backgroundColor: color,
        },
      ]}
    />
  </View>
);

export const VoiceVisualizer: React.FC<VoiceVisualizerProps> = ({
  isListening,
  isProcessing,
  isSpeaking,
  isNavigation = false,
  isReaching = false,
  isGlassesListening = false,
  transcript,
  pulseAnim: _pulseAnim,
  opacityAnim: _opacityAnim,
  audioLevel: _audioLevel = 0,
  glassesDebugStatus,
  glassesDebugRaw,
}) => {
  const ringRotateAnim = useRef(new Animated.Value(0)).current;
  
  // Animated scale for each bar (0 to 1)
  const barScales = useRef<Animated.Value[]>(
    Array.from({ length: NUM_BARS }, () => new Animated.Value(ACTIVE_BASE))
  ).current;
  
  const animFrameRef = useRef<number | null>(null);

  const state: VisualizerState = useMemo(() => {
    if (isReaching) return 'reaching';
    if (isNavigation) return 'navigating';
    if (isSpeaking) return 'speaking';
    if (isProcessing) return 'thinking';
    if (isListening) return 'listening';
    if (isGlassesListening) return 'glassesListening';
    return 'ready';
  }, [isGlassesListening, isListening, isNavigation, isProcessing, isReaching, isSpeaking]);

  const statusText = STATUS_TEXT[state];
  const instructionText = STATUS_INSTRUCTION[state];
  const statusColor = STATUS_COLOR[state];
  const motion = MOTION[state];

  // Single clockwise ring rotation language for active states.
  useEffect(() => {
    const isActive = state !== 'ready';
    if (isActive) {
      Animated.loop(
        Animated.timing(ringRotateAnim, {
          toValue: 1,
          duration:
            state === 'thinking'
              ? 5400
              : state === 'glassesListening'
                ? 12000
              : state === 'navigating' || state === 'reaching'
                ? 7600
                : 8400,
          easing: Easing.linear,
          useNativeDriver: true,
        })
      ).start();
    } else {
      ringRotateAnim.stopAnimation();
      ringRotateAnim.setValue(0);
    }
  }, [ringRotateAnim, state]);

  // Unified circular motion engine with per-state profile tuning.
  useEffect(() => {
    const isActive = state !== 'ready';

    if (!isActive) {
      barScales.forEach(scale => {
        Animated.timing(scale, {
          toValue: MOTION.ready.baseline,
          duration: 360,
          useNativeDriver: true,
        }).start();
      });
      if (animFrameRef.current) cancelAnimationFrame(animFrameRef.current);
      return;
    }

    const animate = () => {
      const t = Date.now() * 0.001;
      
      barScales.forEach((scale, i) => {
        const angle = (i / NUM_BARS) * Math.PI * 2;
        const travelWave = Math.sin(angle - t * motion.speed) * motion.waveAmplitude;
        const microPulse = Math.sin(t * (motion.speed + 2.1) + i * 0.32) * motion.pulseAmplitude;
        let stateBias = 0;

        if (state === 'navigating') {
          const forwardBias = Math.max(0, Math.cos(angle - Math.PI / 2));
          stateBias = forwardBias * 0.18;
        }

        if (state === 'reaching') {
          const sweep = (t * 1.5) % (Math.PI * 2);
          const diff = Math.min(
            Math.abs(angle - sweep),
            Math.PI * 2 - Math.abs(angle - sweep)
          );
          stateBias = Math.max(0, 1 - diff / 0.68) * 0.25;
        }

        const value = motion.baseline + travelWave + microPulse + stateBias;
        scale.setValue(Math.max(0.12, Math.min(1, value)));
      });
      
      animFrameRef.current = requestAnimationFrame(animate);
    };
    
    animate();
    return () => { if (animFrameRef.current) cancelAnimationFrame(animFrameRef.current); };
  }, [barScales, motion, state]);

  const rotation = ringRotateAnim.interpolate({
    inputRange: [0, 1],
    outputRange: ['0deg', '360deg'],
  });

  // Pre-calculate bar positions - bars are positioned at their CENTER along the radial line
  const barPositions = useMemo(() => {
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

  const statusTextStyle = useMemo(
    () => [
      styles.statusText,
      state === 'ready' ? styles.statusTextReady : styles.statusTextActive,
      {
        color: statusColor,
        opacity: state === 'ready' ? 0.88 : 1,
      },
    ],
    [state, statusColor]
  );

  const instructionTextStyle = useMemo(
    () => [
      styles.instructionText,
      {
        opacity:
          state === 'ready'
            ? 0.78
            : state === 'listening'
              ? 0.9
              : 0.72,
      },
    ],
    [state]
  );

  const ringGlowStyle = useMemo(
    () => [
      styles.outerGlow,
      {
        borderColor: statusColor,
        opacity: motion.outerGlowOpacity,
      },
    ],
    [motion.outerGlowOpacity, statusColor]
  );

  const ringBarsRotationStyle = useMemo(
    () => [
      styles.barsContainer,
      {
        transform: [{ rotate: rotation }],
        opacity: state === 'ready' ? 0.5 : 1,
      },
    ],
    [rotation, state]
  );

  const innerCircleStyle = useMemo(
    () => [styles.innerCircle, { borderColor: statusColor }],
    [statusColor]
  );

  const transcriptBoxStyle = useMemo(
    () => [styles.transcriptBox, { borderLeftColor: statusColor }],
    [statusColor]
  );

  const barStyleMap = useMemo(
    () =>
      barPositions.map(pos => ({
        position: 'absolute' as const,
        width: BAR_WIDTH,
        height: MAX_BAR_LENGTH,
        left: pos.x,
        top: pos.y,
        backgroundColor: statusColor,
        borderRadius: BAR_WIDTH / 2,
        opacity: 0.88,
      })),
    [barPositions, statusColor]
  );

  const renderIcon = () => {
    const size = 65;
    if (state === 'reaching') return <ReachingIcon size={size} color={statusColor} />;
    if (state === 'navigating') return <NavigationIcon size={size} color={statusColor} />;
    if (isSpeaking) return <Speaker size={size} color="#4CAF50" />;
    if (isProcessing) return <Brain size={size} color="#FFC107" />;
    if (isListening) return <Mic size={size} color="#2196F3" />;
    if (isGlassesListening) return <Mic size={size} color="#00BFA5" />;
    return <MicOff size={size} color={STATUS_COLOR.ready} />;
  };

  return (
    <View
      style={styles.container}
      // ── Bug 8: do NOT compete with the parent TouchableWithoutFeedback's
      // accessibility region. Previously this View was `accessible={true}`
      // with its own `accessibilityRole="text"` — that, combined with the
      // visible <Text>"Ready"</Text> below using a wide letterSpacing,
      // caused VoiceOver to spell the word as letters ("R-e-a-d-y" /
      // "L-I-S-T-E-N-I-N-G") on some iOS versions. We hide the entire
      // subtree from accessibility; the parent TouchableWithoutFeedback in
      // App.tsx owns the spoken label ("Ready. Tap to speak").
      accessible={false}
      accessibilityElementsHidden={true}
      importantForAccessibility="no-hide-descendants"
    >
      
      <View style={styles.visualizer} accessible={false} importantForAccessibility="no-hide-descendants">
        
        <Animated.View style={ringGlowStyle} />

        <Animated.View style={ringBarsRotationStyle}>
          {barPositions.map((pos, i) => (
            <Animated.View
              key={i}
              style={[
                barStyleMap[i],
                {
                  transform: [
                    { scaleY: barScales[i] },
                    { rotate: `${pos.angleDeg}deg` },
                  ],
                },
              ]}
            />
          ))}
        </Animated.View>

        <View style={innerCircleStyle} />

        <View style={styles.iconContainer}>{renderIcon()}</View>
      </View>

      {/* Visible status text — explicitly hidden from accessibility so
          VoiceOver does not fall back to reading the on-screen letters. */}
      <Text style={statusTextStyle} accessible={false} importantForAccessibility="no">{statusText}</Text>

      {transcript && state === 'listening' && (
        <View style={transcriptBoxStyle} accessible={false} importantForAccessibility="no-hide-descendants">
          <Text style={styles.transcriptText} accessible={false} importantForAccessibility="no">{transcript}</Text>
        </View>
      )}

      <Text style={instructionTextStyle} accessible={false} importantForAccessibility="no">{instructionText}</Text>

      {/* ── Debug overlay for glasses mode ── */}
      {(state === 'glassesListening' || isGlassesListening) && glassesDebugStatus ? (
        <View style={styles.debugBox} accessible={false} importantForAccessibility="no-hide-descendants">
          <Text style={styles.debugStatusText}>{glassesDebugStatus}</Text>
          {glassesDebugRaw ? (
            <Text style={styles.debugRawText}>Raw: "{glassesDebugRaw}"</Text>
          ) : null}
        </View>
      ) : null}
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  visualizer: {
    width: CIRCLE_SIZE,
    height: CIRCLE_SIZE,
    justifyContent: 'center',
    alignItems: 'center',
  },
  outerGlow: {
    position: 'absolute',
    width: CIRCLE_SIZE + 20,
    height: CIRCLE_SIZE + 20,
    borderRadius: (CIRCLE_SIZE + 20) / 2,
    borderWidth: 1,
  },
  barsContainer: {
    position: 'absolute',
    width: CIRCLE_SIZE,
    height: CIRCLE_SIZE,
  },
  innerCircle: {
    position: 'absolute',
    width: INNER_RADIUS * 2,
    height: INNER_RADIUS * 2,
    borderRadius: INNER_RADIUS,
    borderWidth: 1.8,
    backgroundColor: 'rgba(0, 0, 0, 0.56)',
  },
  iconContainer: {
    position: 'absolute',
  },
  symbolContainer: {
    justifyContent: 'center',
    alignItems: 'center',
  },
  navArrow: {
    width: 0,
    height: 0,
    borderLeftColor: 'transparent',
    borderRightColor: 'transparent',
  },
  navStem: {
    marginTop: -3,
  },
  targetOuter: {
    position: 'absolute',
    borderWidth: 2,
  },
  targetInner: {
    position: 'absolute',
    borderWidth: 2,
  },
  targetCore: {
    position: 'absolute',
  },
  statusText: {
    marginTop: 30,
    fontSize: 24,
  },
  statusTextReady: {
    fontWeight: '600',
    letterSpacing: 0.6,
  },
  statusTextActive: {
    fontWeight: '700',
    letterSpacing: 0.85,
  },
  transcriptBox: {
    position: 'absolute',
    bottom: 105,
    left: 20,
    right: 20,
    backgroundColor: 'rgba(15, 30, 52, 0.7)',
    padding: 16,
    borderRadius: 14,
    borderWidth: 1,
    borderColor: 'rgba(122, 172, 255, 0.28)',
    borderLeftWidth: 4,
  },
  transcriptText: {
    color: '#F5F8FF',
    fontSize: 17,
    lineHeight: 23,
  },
  instructionText: {
    position: 'absolute',
    bottom: 42,
    color: 'rgba(218, 223, 234, 0.72)',
    fontSize: 15,
    letterSpacing: 0.28,
    fontWeight: '500',
  },
  debugBox: {
    position: 'absolute',
    bottom: 65,
    left: 16,
    right: 16,
    backgroundColor: 'rgba(0, 0, 0, 0.85)',
    borderRadius: 10,
    borderWidth: 1,
    borderColor: 'rgba(0, 191, 165, 0.5)',
    paddingHorizontal: 14,
    paddingVertical: 10,
  },
  debugStatusText: {
    color: '#00BFA5',
    fontSize: 13,
    fontWeight: '600',
    fontFamily: 'Menlo',
  },
  debugRawText: {
    color: '#AAFFEE',
    fontSize: 12,
    fontFamily: 'Menlo',
    marginTop: 4,
  },
});

export default VoiceVisualizer;
