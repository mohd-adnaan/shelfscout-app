import { useEffect, useCallback, useRef } from 'react';
import Voice, {
  SpeechResultsEvent,
  SpeechErrorEvent,
  SpeechStartEvent,
  SpeechEndEvent,
} from '@react-native-voice/voice';

export const useVoiceRecognition = () => {
  const callbacksRef = useRef<{
    onResults?: (transcript: string) => void;
    onError?: (error: any) => void;
    onStart?: () => void;
    onEnd?: () => void;
  }>({});

  useEffect(() => {
    Voice.onSpeechStart = (e: SpeechStartEvent) => {
      console.log('Speech started');
      callbacksRef.current.onStart?.();
    };

    Voice.onSpeechEnd = (e: SpeechEndEvent) => {
      console.log('Speech ended');
      callbacksRef.current.onEnd?.();
    };

    Voice.onSpeechResults = (e: SpeechResultsEvent) => {
      console.log('Speech results:', e.value);
      if (e.value && e.value.length > 0) {
        callbacksRef.current.onResults?.(e.value[0]);
      }
    };

    Voice.onSpeechError = (e: SpeechErrorEvent) => {
      console.error('Speech error:', e.error);
      callbacksRef.current.onError?.(e.error);
    };

    return () => {
      Voice.destroy().then(Voice.removeAllListeners);
    };
  }, []);

  const startRecognition = useCallback(
    async (
      onResults: (transcript: string) => void,
      onError: (error: any) => void,
      onStart?: () => void,
      onEnd?: () => void
    ) => {
      callbacksRef.current = { onResults, onError, onStart, onEnd };

      try {
        await Voice.start('en-US');
      } catch (error) {
        console.error('Start recognition error:', error);
        onError(error);
      }
    },
    []
  );

  const stopRecognition = useCallback(async () => {
    try {
      await Voice.stop();
    } catch (error) {
      console.error('Stop recognition error:', error);
    }
  }, []);

  const cancelRecognition = useCallback(async () => {
    try {
      await Voice.cancel();
    } catch (error) {
      console.error('Cancel recognition error:', error);
    }
  }, []);

  return {
    startRecognition,
    stopRecognition,
    cancelRecognition,
  };
};