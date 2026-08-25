/**
 * Announcer — VoiceOver output arbitration.
 *
 * These tests pin the three behaviours that the previous direct
 * `announceForAccessibility` calls got wrong, each of which was observed in
 * blind-participant sessions:
 *
 *   1. Announcements must be QUEUED, not interrupting. An interrupting
 *      announcement resets VoiceOver's queue, and that reset consumes the
 *      user's next double-tap — the "I have to tap four times" report.
 *   2. Repeated identical text must be dropped, so a re-render does not read
 *      the same sentence twice.
 *   3. Non-urgent speech must be held briefly after a user activation, so it
 *      never lands on top of VoiceOver reading the newly focused element.
 *
 * @format
 */

import { AccessibilityInfo } from 'react-native';
import Announcer from '../src/a11y/Announcer';

const withOptions = () =>
  (AccessibilityInfo as any).announceForAccessibilityWithOptions as jest.Mock;

describe('Announcer', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    (AccessibilityInfo as any).announceForAccessibilityWithOptions = jest.fn();
    (AccessibilityInfo as any).announceForAccessibility = jest.fn();
    Announcer.setSpeechSink(null);
    // setScreenReaderEnabled only acts on a change, so force a known edge.
    Announcer.setScreenReaderEnabled(false);
    Announcer.setScreenReaderEnabled(true);
    Announcer.reset();
    Announcer.holdForGesture(0);
  });

  afterEach(() => {
    Announcer.reset();
    jest.useRealTimers();
  });

  it('uses the queued announcement API so VoiceOver is never interrupted', () => {
    Announcer.announceStatus('Finding the cereal');
    jest.advanceTimersByTime(50);

    expect(withOptions()).toHaveBeenCalledTimes(1);
    const [message, options] = withOptions().mock.calls[0];
    expect(message).toBe('Finding the cereal');
    expect(options).toEqual({ queue: true });
  });

  it('interrupts only for critical announcements', () => {
    Announcer.announceCritical('Camera failed');
    jest.advanceTimersByTime(50);

    expect(withOptions()).toHaveBeenCalledWith('Camera failed', { queue: false });
  });

  it('drops a repeat of the same status inside the dedupe window', () => {
    Announcer.announceStatus('Listening');
    jest.advanceTimersByTime(50);
    Announcer.announceStatus('Listening');
    jest.advanceTimersByTime(2000);

    expect(withOptions()).toHaveBeenCalledTimes(1);
  });

  it('allows the same text again once the dedupe window has passed', () => {
    Announcer.announceStatus('Listening');
    jest.advanceTimersByTime(3000);
    Announcer.announceStatus('Listening');
    jest.advanceTimersByTime(3000);

    expect(withOptions()).toHaveBeenCalledTimes(2);
  });

  it('holds non-critical speech across a gesture, then delivers it', () => {
    Announcer.holdForGesture(450);
    Announcer.announceStatus('Describing what is in front of you');

    jest.advanceTimersByTime(100);
    expect(withOptions()).not.toHaveBeenCalled();

    jest.advanceTimersByTime(600);
    expect(withOptions()).toHaveBeenCalledTimes(1);
  });

  it('does not hold a critical announcement behind a gesture', () => {
    Announcer.holdForGesture(450);
    Announcer.announceCritical('Camera failed');

    jest.advanceTimersByTime(10);
    expect(withOptions()).toHaveBeenCalledTimes(1);
  });

  it('drops chatter while something more important is speaking', () => {
    Announcer.announceStatus('Going to the dairy aisle');
    Announcer.announceChatter('Still walking');
    jest.advanceTimersByTime(5000);

    const spoken = withOptions().mock.calls.map((c: unknown[]) => c[0]);
    expect(spoken).toEqual(['Going to the dairy aisle']);
  });

  it('clears pending speech on reset so a stopped session goes quiet', () => {
    Announcer.holdForGesture(400);
    Announcer.announceStatus('Going to the dairy aisle');
    Announcer.reset();
    jest.advanceTimersByTime(5000);

    expect(withOptions()).not.toHaveBeenCalled();
  });

  it('suppresses text the focused element already speaks', () => {
    Announcer.announce('Listening', { duplicatesFocusedLabel: true });
    jest.advanceTimersByTime(1000);

    expect(withOptions()).not.toHaveBeenCalled();
  });

  describe('with no screen reader running', () => {
    beforeEach(() => {
      Announcer.setScreenReaderEnabled(false);
    });

    it('routes to the speech sink instead of the accessibility API', () => {
      const sink = jest.fn();
      Announcer.setSpeechSink(sink);

      Announcer.announceStatus('Ready');
      jest.advanceTimersByTime(1000);

      expect(withOptions()).not.toHaveBeenCalled();
      expect(sink).toHaveBeenCalledWith('Ready', 'status');
    });

    it('still delivers text that would duplicate a focused label', () => {
      // With VoiceOver off nothing else says it, so suppressing it here would
      // mean the sighted-but-audio-dependent user hears nothing at all.
      const sink = jest.fn();
      Announcer.setSpeechSink(sink);

      Announcer.announce('Listening', { duplicatesFocusedLabel: true });

      expect(sink).toHaveBeenCalledWith('Listening', 'status');
    });
  });
});
