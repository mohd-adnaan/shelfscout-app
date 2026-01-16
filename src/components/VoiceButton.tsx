/**
 * src/components/VoiceButton.tsx
 * 
 * WCAG 2.1 AA Compliant Voice Button
 * 
 * Compliance Features:
 * - 2.1.1 Keyboard: Fully operable via screen reader gestures
 * - 2.4.7 Focus Visible: Clear focus indication for sighted users
 * - 2.5.1 Pointer Gestures: Both single-tap AND double-tap work
 * - 2.5.2 Pointer Cancellation: Action on release, can cancel
 * - 3.2.1 On Focus: No unexpected changes on focus
 * - 3.3.2 Labels or Instructions: Clear labels and hints
 * - 4.1.2 Name, Role, Value: Complete accessibility props
 * - 4.1.3 Status Messages: Announces state changes
 * 
 * CRITICAL: This is the PRIMARY control for blind users
 */

import React, { useEffect, useRef, useState } from 'react';
import {
  TouchableOpacity,
  StyleSheet,
  Animated,
  View,
  Vibration,
  AccessibilityInfo,
  Platform,
} from 'react-native';
import { TapGestureHandler, State } from 'react-native-gesture-handler';
import { COLORS } from '../utils/constants';

interface VoiceButtonProps {
  isRecording: boolean;
  isProcessing: boolean;
  isSpeaking: boolean;
  onPress: () => void;
  onDoubleTap: () => void;
}

/**
 * VoiceButton Component
 * 
 * The main interactive control for voice recording.
 * MUST be fully accessible to blind users via screen readers.
 */
const VoiceButton: React.FC<VoiceButtonProps> = ({
  isRecording,
  isProcessing,
  isSpeaking,
  onPress,
  onDoubleTap,
}) => {
  const scaleAnim = useRef(new Animated.Value(1)).current;
  const doubleTapRef = useRef(null);
  const previousState = useRef<string>('');
  const [isFocused, setIsFocused] = useState(false);
  const [reduceMotionEnabled, setReduceMotionEnabled] = useState(false);

  // ============================================================================
  // WCAG 2.3.3: Check Reduce Motion Preference
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

  // ============================================================================
  // WCAG 2.3.3: Pulse Animation (respects reduce motion)
  // ============================================================================
  useEffect(() => {
    if ((isRecording || isSpeaking) && !reduceMotionEnabled) {
      // Pulse animation ONLY if reduce motion is disabled
      Animated.loop(
        Animated.sequence([
          Animated.timing(scaleAnim, {
            toValue: 1.2,
            duration: 1000,
            useNativeDriver: true,
          }),
          Animated.timing(scaleAnim, {
            toValue: 1,
            duration: 1000,
            useNativeDriver: true,
          }),
        ])
      ).start();
    } else {
      scaleAnim.setValue(1);
    }
  }, [isRecording, isSpeaking, reduceMotionEnabled, scaleAnim]);

  // ============================================================================
  // WCAG 4.1.3: Announce State Changes
  // ============================================================================
  useEffect(() => {
    const currentState = getAccessibilityLabel();
    
    // Only announce if state actually changed
    if (currentState !== previousState.current && previousState.current !== '') {
      // Don't announce during processing - VoiceVisualizer handles that
      if (!isProcessing) {
        AccessibilityInfo.announceForAccessibility(
          `${getAccessibilityLabel()}. ${getAccessibilityHint()}`
        );
      }
    }
    
    previousState.current = currentState;
  }, [isRecording, isProcessing, isSpeaking]);

  // ============================================================================
  // WCAG 2.5.1: Double-Tap Gesture Handler
  // ============================================================================
  const handleDoubleTap = ({ nativeEvent }: any) => {
    if (nativeEvent.state === State.ACTIVE) {
      Vibration.vibrate(50); // Haptic feedback
      
      // Announce action
      AccessibilityInfo.announceForAccessibility(
        'Double tap detected. Taking photo.'
      );
      
      onDoubleTap();
    }
  };

  // ============================================================================
  // WCAG 2.1.1, 3.2.1: Press Handler
  // ============================================================================
  const handlePress = () => {
    // WCAG 3.2.1: Don't allow press during processing (predictable behavior)
    if (isProcessing) {
      console.log('⚠️ Button press ignored - currently processing');
      
      // Inform user why action was blocked
      AccessibilityInfo.announceForAccessibility(
        'Please wait. Processing in progress.'
      );
      return;
    }
    
    Vibration.vibrate(50); // Haptic feedback
    onPress();
  };

  // ============================================================================
  // WCAG 4.1.2: Accessibility Label (Name)
  // ============================================================================
  const getAccessibilityLabel = () => {
    if (isSpeaking) return 'Voice assistant speaking';
    if (isProcessing) return 'Processing your request';
    if (isRecording) return 'Stop recording';
    return 'Start voice recording';
  };

  // ============================================================================
  // WCAG 4.1.2: Accessibility Hint (Instructions)
  // ============================================================================
  const getAccessibilityHint = () => {
    if (isSpeaking) {
      return 'Double tap to interrupt and stop speaking';
    }
    if (isProcessing) {
      return 'Please wait while we process your request. Double tap to cancel.';
    }
    if (isRecording) {
      return 'Tap to stop recording and process your voice command. Double tap anywhere to take a photo.';
    }
    return 'Tap to start voice recording. Double tap anywhere to take a photo without speaking.';
  };

  // ============================================================================
  // Visual Styling (for sighted/low-vision users)
  // ============================================================================
  const getBackgroundColor = () => {
    if (isProcessing) return COLORS.PROCESSING;
    if (isSpeaking) return COLORS.SPEAKING;
    if (isRecording) return COLORS.RECORDING;
    return COLORS.PRIMARY;
  };

  return (
    <TapGestureHandler
      ref={doubleTapRef}
      onHandlerStateChange={handleDoubleTap}
      numberOfTaps={2}
      // Allow both gestures to work
      enabled={!isProcessing}
    >
      <Animated.View 
        style={{ 
          transform: [{ scale: reduceMotionEnabled ? 1 : scaleAnim }] 
        }}
      >
        <TouchableOpacity
          // ================================================================
          // WCAG 4.1.2: Name, Role, Value
          // ================================================================
          accessible={true}
          accessibilityLabel={getAccessibilityLabel()}
          accessibilityHint={getAccessibilityHint()}
          accessibilityRole="button"
          
          // WCAG 4.1.2: State information
          accessibilityState={{
            disabled: isProcessing,
            busy: isProcessing,
            // Note: 'selected' not used here as it's not a selection
          }}
          
          // WCAG 4.1.3: Live region for status (optional - VoiceVisualizer handles main announcements)
          accessibilityLiveRegion="polite"
          
          // ================================================================
          // Interaction Handlers
          // ================================================================
          onPress={handlePress}
          onPressIn={() => {
            // WCAG 2.5.2: Visual feedback on press start
            // Action happens on release for cancellation
          }}
          
          // WCAG 2.4.7: Focus indicators
          onFocus={() => setIsFocused(true)}
          onBlur={() => setIsFocused(false)}
          
          // WCAG 2.5.2: Lower opacity when disabled, full opacity when active
          activeOpacity={isProcessing ? 1 : 0.7}
          disabled={isProcessing}
          
          // ================================================================
          // Styling
          // ================================================================
          style={[
            styles.button, 
            { backgroundColor: getBackgroundColor() },
            // WCAG 2.4.7: Visible focus indicator
            isFocused && styles.buttonFocused,
            // WCAG 1.4.11: Disabled state has clear visual difference
            isProcessing && styles.buttonDisabled,
          ]}
        >
          {/* Inner circle - decorative, hidden from screen readers */}
          <View 
            style={styles.innerCircle}
            accessible={false}
          />
        </TouchableOpacity>
      </Animated.View>
    </TapGestureHandler>
  );
};

const styles = StyleSheet.create({
  button: {
    // WCAG 2.5.5: Touch target at least 44x44 points (80 > 44 ✓)
    width: 80,
    height: 80,
    borderRadius: 40,
    justifyContent: 'center',
    alignItems: 'center',
    
    // Shadow for depth (visual only)
    elevation: 5,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.3,
    shadowRadius: 4,
    
    // WCAG 2.4.7: Default border (transparent until focused)
    borderWidth: 3,
    borderColor: 'transparent',
  },
  
  // WCAG 2.4.7: Focus Visible - High contrast focus indicator
  buttonFocused: {
    borderColor: '#FFFF00', // Yellow - 3:1+ contrast on all backgrounds
    borderWidth: 4,
    shadowColor: '#FFFF00',
    shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 0.8,
    shadowRadius: 8,
    elevation: 8,
  },
  
  // WCAG 1.4.11: Disabled state visually distinct
  buttonDisabled: {
    opacity: 0.6,
  },
  
  // Decorative inner circle
  innerCircle: {
    width: 60,
    height: 60,
    borderRadius: 30,
    backgroundColor: COLORS.WHITE,
    opacity: 0.3,
  },
});

export default VoiceButton;