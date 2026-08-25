/**
 * Sound cues and haptics.
 *
 * ── The regression these tests exist to prevent ────────────────────────────
 * Every cue in the app used to sit behind `if (!screenReaderEnabled)`. The
 * stated reason was an audio-session conflict, and the conflict was real — but
 * the fix was applied to the wrong layer, so the users who depend entirely on
 * audio were the only ones who got none of it. Haptics were suppressed by the
 * same condition despite having nothing to do with the audio session at all.
 *
 * Two invariants follow, and both are checked below:
 *   • A cue fires regardless of whether a screen reader is running.
 *   • Haptics fire even when sound is unavailable.
 *
 * @format
 */

import { Vibration } from 'react-native';

jest.mock('../src/utils/soundEffects', () => ({
  playListenSound: jest.fn().mockResolvedValue(undefined),
  stopListenSound: jest.fn().mockResolvedValue(undefined),
  playThinkingStarted: jest.fn(),
  stopLatencyLoop: jest.fn().mockResolvedValue(undefined),
  playSuccessChime: jest.fn().mockResolvedValue(undefined),
  playErrorSound: jest.fn().mockResolvedValue(undefined),
  playStopReachingSound: jest.fn().mockResolvedValue(undefined),
}));

import earcons from '../src/a11y/earcons';
import * as soundEffects from '../src/utils/soundEffects';

describe('earcons', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    jest.spyOn(Vibration, 'vibrate').mockImplementation(() => {});
    earcons.reset();
    earcons.setWearablesMode(false);
    earcons.setHapticsEnabled(true);
    earcons.setNativeSessionActive(false);
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('plays the listening cue and resolves before the caller continues', async () => {
    // startListening awaits this: the microphone must not open until the cue
    // has finished, or the recognizer transcribes the cue instead of the user.
    await earcons.playAndWait('listenStart');

    expect(soundEffects.playListenSound).toHaveBeenCalledTimes(1);
    expect(Vibration.vibrate).toHaveBeenCalled();
  });

  it('maps each semantic cue to its own sound', async () => {
    await earcons.playAndWait('thinking');
    await earcons.playAndWait('success');
    await earcons.playAndWait('error');
    await earcons.playAndWait('modeExit');

    expect(soundEffects.playThinkingStarted).toHaveBeenCalledTimes(1);
    expect(soundEffects.playSuccessChime).toHaveBeenCalledTimes(1);
    expect(soundEffects.playErrorSound).toHaveBeenCalledTimes(1);
    expect(soundEffects.playStopReachingSound).toHaveBeenCalledTimes(1);
  });

  it('collapses an accidental double-fire of the same cue', async () => {
    await earcons.playAndWait('thinking');
    await earcons.playAndWait('thinking');

    expect(soundEffects.playThinkingStarted).toHaveBeenCalledTimes(1);
  });

  it('never collapses a cue that answers a user action', async () => {
    // Pressing a button twice has to feel the same both times, even when the
    // presses are milliseconds apart.
    await earcons.playAndWait('error');
    await earcons.playAndWait('error');

    expect(soundEffects.playErrorSound).toHaveBeenCalledTimes(2);
  });

  it('still vibrates when sound is unavailable', async () => {
    // Glasses mode hands the audio session to BluetoothHFP, so cues cannot
    // play — but the vibration channel is untouched, and in a noisy aisle it
    // is the one the user is most likely to notice anyway.
    earcons.setWearablesMode(true);

    await earcons.playAndWait('error');

    expect(soundEffects.playErrorSound).not.toHaveBeenCalled();
    expect(Vibration.vibrate).toHaveBeenCalled();
  });

  it('honours the user turning haptics off without silencing sound', async () => {
    earcons.setHapticsEnabled(false);

    await earcons.playAndWait('success');

    expect(soundEffects.playSuccessChime).toHaveBeenCalledTimes(1);
    expect(Vibration.vibrate).not.toHaveBeenCalled();
  });

  it('stays silent while a native AR screen owns feedback', async () => {
    // A participant in the 25 Aug 2026 lab test reported two "random
    // vibrations" mid-navigation. `ready` and `select` are haptic-ONLY cues, so
    // one fired from behind the native screen reaches the user as a bare buzz
    // with nothing to attribute it to. Native speaks for itself for that whole
    // window; this layer must not interrupt it from underneath.
    earcons.setNativeSessionActive(true);

    await earcons.playAndWait('ready');
    await earcons.playAndWait('error');

    expect(Vibration.vibrate).not.toHaveBeenCalled();
    expect(soundEffects.playErrorSound).not.toHaveBeenCalled();

    // And it comes straight back when the screen does.
    earcons.setNativeSessionActive(false);
    await earcons.playAndWait('error');
    expect(Vibration.vibrate).toHaveBeenCalled();
    expect(soundEffects.playErrorSound).toHaveBeenCalledTimes(1);
  });

  it('reports whether a direct haptic would reach the user', () => {
    // `AudioFeedbackService.playEarcon` vibrates directly and predates this
    // module. It read neither the preference nor the native-screen mute, which
    // made it the one buzz a user could not turn off.
    expect(earcons.hapticsAllowed()).toBe(true);

    earcons.setNativeSessionActive(true);
    expect(earcons.hapticsAllowed()).toBe(false);

    earcons.setNativeSessionActive(false);
    earcons.setHapticsEnabled(false);
    expect(earcons.hapticsAllowed()).toBe(false);
  });

  it('survives a failing sound without rejecting', async () => {
    (soundEffects.playErrorSound as jest.Mock).mockRejectedValueOnce(
      new Error('audio session busy'),
    );

    // A cue that throws must never take down the pipeline that fired it —
    // these run inside reaching and navigation, where an unhandled rejection
    // costs the user their session.
    await expect(earcons.playAndWait('error')).resolves.toBeUndefined();
  });
});
