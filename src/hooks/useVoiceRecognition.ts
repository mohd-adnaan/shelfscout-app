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

  const isRecognizingRef = useRef(false);

  useEffect(() => {
    Voice.onSpeechStart = (e: SpeechStartEvent) => {
      console.log('🎤 Speech started');
      isRecognizingRef.current = true;
      callbacksRef.current.onStart?.();
    };

    Voice.onSpeechEnd = (e: SpeechEndEvent) => {
      console.log('🎤 Speech ended');
      isRecognizingRef.current = false;
      callbacksRef.current.onEnd?.();
    };

    Voice.onSpeechResults = (e: SpeechResultsEvent) => {
      console.log('📝 Speech results:', e.value);
      if (e.value && e.value.length > 0) {
        callbacksRef.current.onResults?.(e.value[0]);
      }
    };

    Voice.onSpeechError = (e: SpeechErrorEvent) => {
      console.error('❌ Speech error:', e.error);
      isRecognizingRef.current = false;
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
        // ✅ Ensure Voice is completely stopped before starting
        if (isRecognizingRef.current) {
          console.log('⚠️ Voice already recognizing, stopping first...');
          await Voice.cancel();
          isRecognizingRef.current = false;
          // Small delay to ensure cleanup
          await new Promise(resolve => setTimeout(resolve, 100));
        }

        console.log('✅ Starting voice recognition');
        await Voice.start('en-US');
      } catch (error: any) {
        console.error('❌ Start recognition error:', error);
        
        // If already started, try to recover
        if (error?.message?.includes('already started')) {
          console.log('🔄 Attempting to recover from "already started" error');
          try {
            await Voice.cancel();
            await new Promise(resolve => setTimeout(resolve, 100));
            await Voice.start('en-US');
          } catch (retryError) {
            console.error('❌ Recovery failed:', retryError);
            onError(retryError);
          }
        } else {
          onError(error);
        }
      }
    },
    []
  );

  const stopRecognition = useCallback(async () => {
    try {
      console.log('🛑 Voice recognition stopped');
      await Voice.stop();
      isRecognizingRef.current = false;
    } catch (error) {
      console.error('❌ Stop recognition error:', error);
      isRecognizingRef.current = false;
    }
  }, []);

  const cancelRecognition = useCallback(async () => {
    try {
      console.log('🚫 Voice recognition cancelled');
      await Voice.cancel();
      isRecognizingRef.current = false;
    } catch (error) {
      console.error('❌ Cancel recognition error:', error);
      isRecognizingRef.current = false;
    }
  }, []);

  return {
    startRecognition,
    stopRecognition,
    cancelRecognition,
  };
};