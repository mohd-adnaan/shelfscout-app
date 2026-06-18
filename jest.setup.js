/* eslint-env jest */

jest.mock('@react-native-async-storage/async-storage', () => {
  const store = new Map();
  return {
    getItem: jest.fn((key) => Promise.resolve(store.get(key) ?? null)),
    setItem: jest.fn((key, value) => {
      store.set(key, value);
      return Promise.resolve();
    }),
    removeItem: jest.fn((key) => {
      store.delete(key);
      return Promise.resolve();
    }),
    clear: jest.fn(() => {
      store.clear();
      return Promise.resolve();
    }),
  };
});

const { NativeModules } = require('react-native');

NativeModules.TextToSpeech = {
  addListener: jest.fn(),
  removeListeners: jest.fn(),
};

jest.mock('react-native-vision-camera', () => {
  const React = require('react');
  const { View } = require('react-native');

  return {
    Camera: React.forwardRef((props, ref) => React.createElement(View, { ...props, ref })),
    useCameraDevice: jest.fn(() => ({ id: 'back', position: 'back' })),
    useCameraPermission: jest.fn(() => ({
      hasPermission: true,
      requestPermission: jest.fn().mockResolvedValue(true),
    })),
    useMicrophonePermission: jest.fn(() => ({
      hasPermission: true,
      requestPermission: jest.fn().mockResolvedValue(true),
    })),
  };
});

jest.mock('react-native-video', () => {
  const React = require('react');
  const { View } = require('react-native');
  return React.forwardRef((props, ref) => React.createElement(View, { ...props, ref }));
});

jest.mock('@react-native-voice/voice', () => ({
  __esModule: true,
  default: {
    start: jest.fn().mockResolvedValue(undefined),
    stop: jest.fn().mockResolvedValue(undefined),
    cancel: jest.fn().mockResolvedValue(undefined),
    destroy: jest.fn().mockResolvedValue(undefined),
    removeAllListeners: jest.fn(),
  },
}));

jest.mock('react-native-tts', () => ({
  __esModule: true,
  default: {
    addEventListener: jest.fn(),
    removeEventListener: jest.fn(),
    getInitStatus: jest.fn().mockResolvedValue('success'),
    setDefaultLanguage: jest.fn().mockResolvedValue('success'),
    setDefaultVoice: jest.fn().mockResolvedValue('success'),
    setDefaultRate: jest.fn().mockResolvedValue('success'),
    setDefaultPitch: jest.fn().mockResolvedValue('success'),
    setIgnoreSilentSwitch: jest.fn().mockResolvedValue(true),
    setDucking: jest.fn().mockResolvedValue('success'),
    speak: jest.fn(() => 'utterance-id'),
    stop: jest.fn().mockResolvedValue(true),
    voices: jest.fn().mockResolvedValue([]),
  },
}));

jest.mock('react-native-sound', () => {
  const Sound = jest.fn().mockImplementation((_file, _basePath, onLoad) => {
    queueMicrotask(() => onLoad?.(null));
    return {
      play: jest.fn((onEnd) => onEnd?.(true)),
      stop: jest.fn((onStop) => onStop?.()),
      release: jest.fn(),
      setNumberOfLoops: jest.fn(),
      setVolume: jest.fn(),
    };
  });
  Sound.setCategory = jest.fn();
  Sound.MAIN_BUNDLE = 'MAIN_BUNDLE';
  return Sound;
});

jest.mock('react-native-sensors', () => ({
  SensorTypes: {
    accelerometer: 'accelerometer',
  },
  setUpdateIntervalForType: jest.fn(),
  accelerometer: {
    subscribe: jest.fn(() => ({ unsubscribe: jest.fn() })),
  },
}));

jest.mock('react-native-fs', () => ({
  DocumentDirectoryPath: '/tmp',
  writeFile: jest.fn().mockResolvedValue(undefined),
  unlink: jest.fn().mockResolvedValue(undefined),
}));
