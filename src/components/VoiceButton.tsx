import React, { useEffect, useRef } from 'react';
import {
  TouchableOpacity,
  StyleSheet,
  Animated,
  View,
  Vibration,
} from 'react-native';
import { TapGestureHandler, State } from 'react-native-gesture-handler';
import { COLORS } from '../utils/constants';

interface VoiceButtonProps {
  isRecording: boolean;
  isProcessing: boolean;
  onPress: () => void;
  onDoubleTap: () => void;
}

const VoiceButton: React.FC<VoiceButtonProps> = ({
  isRecording,
  isProcessing,
  onPress,
  onDoubleTap,
}) => {
  const scaleAnim = useRef(new Animated.Value(1)).current;
  const doubleTapRef = useRef(null);

  useEffect(() => {
    if (isRecording) {
      // Pulse animation
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
  }, [isRecording, scaleAnim]);

  const handleDoubleTap = ({ nativeEvent }: any) => {
    if (nativeEvent.state === State.ACTIVE) {
      Vibration.vibrate(50); // Haptic feedback
      onDoubleTap();
    }
  };

  const handlePress = () => {
    Vibration.vibrate(50); // Haptic feedback
    onPress();
  };

  const backgroundColor = isProcessing
    ? COLORS.PROCESSING
    : isRecording
    ? COLORS.RECORDING
    : COLORS.PRIMARY;

  return (
    <TapGestureHandler
      ref={doubleTapRef}
      onHandlerStateChange={handleDoubleTap}
      numberOfTaps={2}
    >
      <Animated.View style={{ transform: [{ scale: scaleAnim }] }}>
        <TouchableOpacity
          style={[styles.button, { backgroundColor }]}
          onPress={handlePress}
          activeOpacity={0.7}
        >
          <View style={styles.innerCircle} />
        </TouchableOpacity>
      </Animated.View>
    </TapGestureHandler>
  );
};

const styles = StyleSheet.create({
  button: {
    width: 80,
    height: 80,
    borderRadius: 40,
    justifyContent: 'center',
    alignItems: 'center',
    elevation: 5,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.3,
    shadowRadius: 4,
  },
  innerCircle: {
    width: 60,
    height: 60,
    borderRadius: 30,
    backgroundColor: COLORS.WHITE,
    opacity: 0.3,
  },
});

export default VoiceButton;