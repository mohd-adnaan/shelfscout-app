// src/a11y/Announcer.ts
//
// The single VoiceOver output channel.
//
// ── Why this exists ────────────────────────────────────────────────────────
// Before this module, every state change in App.tsx called
// `AccessibilityInfo.announceForAccessibility()` directly. Three things went
// wrong with that, all of them observed in the Aug 2026 blind-participant
// sessions:
//
//   1. An un-queued announcement *interrupts* whatever VoiceOver is currently
//      speaking and resets its announcement queue. On iOS that reset also eats
//      the user's next double-tap: VoiceOver spends the gesture dismissing the
//      announcement instead of routing it to the activation handler. Users
//      described this as "I have to tap four times before it hears me."
//
//   2. Because of (1), the fix everyone reached for was to *suppress*
//      announcements whenever VoiceOver was on (`announceIfNoVoiceOver`,
//      `if (!screenReaderEnabled)` guards throughout App.tsx). The result was
//      backwards: the blind user — the only user who cannot see the screen —
//      received strictly *less* feedback than a sighted user.
//
//   3. Rapid state transitions (Listening → Thinking within ~50ms) produced
//      two overlapping utterances, so the user heard neither.
//
// The real fix is not suppression, it is arbitration. iOS has supported
// queued announcements since iOS 11 (`UIAccessibilitySpeechAttributeQueue-
// Announcement`, exposed by React Native as
// `announceForAccessibilityWithOptions(msg, { queue: true })`). A queued
// announcement is appended to VoiceOver's own speech queue: it never
// interrupts, never resets the queue, and therefore never steals a gesture.
//
// This module makes queued announcements the default, serializes everything
// through one place, drops duplicates, and holds non-urgent speech for a
// moment after the user acts so their gesture always lands.
//
// ── Priorities ─────────────────────────────────────────────────────────────
//   critical — errors, failures, mode aborts. Interrupts. Never dropped.
//   status   — mode changes, arrivals, results. Queued. Deduped.
//   chatter  — progress and repeat-guidance. Dropped when anything else is
//              pending, so the user's ear is never flooded.
//
// ── Non-goals ──────────────────────────────────────────────────────────────
// This is not a TTS client. When VoiceOver is OFF nothing here reaches the
// user's ear on its own; the app's TTS path owns that case. `setSpeechSink()`
// lets the app bridge the two so a call site does not have to branch on
// whether a screen reader happens to be running.

import { AccessibilityInfo, Platform } from 'react-native';

export type AnnouncePriority = 'critical' | 'status' | 'chatter';

export interface AnnounceOptions {
  priority?: AnnouncePriority;
  /**
   * Bypass the duplicate filter. Use for text that is legitimately repeated
   * because the *situation* repeated (a second failed relocalization), not
   * because a re-render fired twice.
   */
  force?: boolean;
  /**
   * The focused element's accessibilityLabel already carries this information.
   * Dropped while a screen reader is on — VoiceOver reads the label change by
   * itself, and saying it twice is the double-voice echo. Still delivered to
   * the speech sink when VoiceOver is off, because then nothing else says it.
   */
  duplicatesFocusedLabel?: boolean;
}

/** Delivered to the app's TTS path when no screen reader is running. */
export type SpeechSink = (message: string, priority: AnnouncePriority) => void;

// ── Tunables ───────────────────────────────────────────────────────────────

/**
 * How long after a user activation non-critical speech is held back.
 *
 * VoiceOver processes the activation, moves focus, and reads the newly
 * focused element inside this window. Speaking over that is what produced
 * the "it talks on top of itself" reports. 450ms is long enough to clear the
 * focus read on an iPhone 14/16 and short enough that the resulting cue still
 * feels like a response to the tap rather than an afterthought.
 */
const GESTURE_HOLD_MS = 450;

/** Identical text inside this window is a re-render, not a new event. */
const DEDUPE_WINDOW_MS = 2500;

/**
 * Fallback pacing when `announcementFinished` never arrives.
 *
 * The event is iOS-only and is not delivered at all for queued announcements
 * in some iOS versions, so the drain loop must never depend on it. This is a
 * rough "how long does that sentence take to speak" estimate used as a timer.
 */
const MS_PER_CHARACTER = 45;
const MIN_UTTERANCE_MS = 700;
const MAX_UTTERANCE_MS = 6000;

/** Anything older than this in the queue is stale; the moment has passed. */
const MAX_QUEUE_AGE_MS = 8000;

/** Hard cap so a runaway loop cannot build an unbounded backlog. */
const MAX_QUEUE_LENGTH = 8;

const PRIORITY_RANK: Record<AnnouncePriority, number> = {
  critical: 2,
  status: 1,
  chatter: 0,
};

interface QueueEntry {
  message: string;
  priority: AnnouncePriority;
  queuedAt: number;
}

const estimateUtteranceMs = (message: string): number =>
  Math.min(
    MAX_UTTERANCE_MS,
    Math.max(MIN_UTTERANCE_MS, message.length * MS_PER_CHARACTER),
  );

class AnnouncerClass {
  private screenReaderEnabled = false;
  private speechSink: SpeechSink | null = null;

  private queue: QueueEntry[] = [];
  private draining = false;
  private drainTimer: ReturnType<typeof setTimeout> | null = null;

  private lastSpoken = new Map<string, number>();
  private gestureHoldUntil = 0;

  private finishedSubscription: { remove: () => void } | null = null;
  private awaitingFinish = false;

  // ── Lifecycle ────────────────────────────────────────────────────────────

  /**
   * Wire up the iOS `announcementFinished` event so the drain loop advances as
   * soon as VoiceOver actually finishes, rather than always waiting out the
   * character-count estimate. Safe to call more than once.
   */
  initialize(): void {
    if (this.finishedSubscription || Platform.OS !== 'ios') return;
    try {
      this.finishedSubscription = AccessibilityInfo.addEventListener(
        'announcementFinished',
        () => {
          if (!this.awaitingFinish) return;
          this.awaitingFinish = false;
          this.scheduleDrain(0);
        },
      );
    } catch (error) {
      // Non-fatal: the estimate-based timer below still paces the queue.
      console.warn('[Announcer] announcementFinished unavailable:', error);
    }
  }

  teardown(): void {
    this.finishedSubscription?.remove();
    this.finishedSubscription = null;
    this.reset();
  }

  setScreenReaderEnabled(enabled: boolean): void {
    if (this.screenReaderEnabled === enabled) return;
    this.screenReaderEnabled = enabled;
    // A mid-session VoiceOver toggle invalidates everything queued: the
    // messages were shaped for the other output channel.
    this.reset();
  }

  isScreenReaderEnabled(): boolean {
    return this.screenReaderEnabled;
  }

  /** Route announcements to the app's TTS when no screen reader is running. */
  setSpeechSink(sink: SpeechSink | null): void {
    this.speechSink = sink;
  }

  // ── Gesture arbitration ──────────────────────────────────────────────────

  /**
   * Call at the top of every activation handler — every button `onPress`,
   * every screen tap. Holds non-critical speech just long enough for
   * VoiceOver to finish handling the gesture and read the new focus.
   *
   * Critical announcements ignore the hold: when something has failed, saying
   * so promptly matters more than gesture etiquette.
   */
  holdForGesture(durationMs: number = GESTURE_HOLD_MS): void {
    this.gestureHoldUntil = Date.now() + durationMs;
  }

  // ── Public API ───────────────────────────────────────────────────────────

  announce(message: string, options: AnnounceOptions = {}): void {
    const text = (message || '').trim();
    if (!text) return;

    const priority = options.priority ?? 'status';

    if (options.duplicatesFocusedLabel && this.screenReaderEnabled) {
      // VoiceOver reads the label change on its own.
      return;
    }

    // Dedupe BEFORE either delivery path. It used to sit below the sink
    // dispatch, so a re-render that fired the same announcement twice was
    // filtered for VoiceOver users and spoken twice for everyone else.
    if (!options.force && this.isDuplicate(text, priority)) return;

    if (!this.screenReaderEnabled) {
      // No screen reader: announceForAccessibility reaches nobody. Hand the
      // message to the app's TTS instead, if one is wired up.
      //
      // ⚠️ Until 4 Sep 2026 nothing ever called `setSpeechSink`, so this was a
      // silent drop — roughly thirty status and error messages a
      // VoiceOver-off user was supposed to hear and never did, including "that
      // object is not in the saved map". The module was built to END
      // suppression and had quietly become the suppression.
      this.speechSink?.(text, priority);
      return;
    }

    if (priority === 'chatter' && (this.queue.length > 0 || this.draining)) {
      // Something more important is already speaking or waiting. Progress
      // chatter is only useful when it is timely, so drop it rather than
      // stack it behind a sentence the user still has to sit through.
      return;
    }

    if (priority === 'critical') {
      // Clear pending non-critical speech: it describes a world that no
      // longer applies, and making the user wait through it delays the one
      // message that matters.
      this.queue = this.queue.filter(entry => entry.priority === 'critical');
    }

    this.queue.push({ message: text, priority, queuedAt: Date.now() });
    if (this.queue.length > MAX_QUEUE_LENGTH) {
      // Drop the least important, oldest entries first. Stable sort keeps
      // insertion order within a priority.
      this.queue.sort((a, b) => PRIORITY_RANK[b.priority] - PRIORITY_RANK[a.priority]);
      this.queue = this.queue.slice(0, MAX_QUEUE_LENGTH);
    }

    this.lastSpoken.set(text, Date.now());
    this.scheduleDrain(this.remainingHoldMs(priority));
  }

  /** Errors and aborts. Interrupts whatever is speaking. */
  announceCritical(message: string): void {
    this.announce(message, { priority: 'critical', force: true });
  }

  /** Mode changes, results, arrivals. The default. */
  announceStatus(message: string, options: Omit<AnnounceOptions, 'priority'> = {}): void {
    this.announce(message, { ...options, priority: 'status' });
  }

  /** Progress updates that are worth hearing only if nothing else is. */
  announceChatter(message: string): void {
    this.announce(message, { priority: 'chatter' });
  }

  /**
   * Drop everything pending without speaking it. Used on emergency stop and
   * on mode exit, where the queued sentences describe a session that is over.
   */
  reset(): void {
    this.queue = [];
    this.lastSpoken.clear();
    this.awaitingFinish = false;
    this.draining = false;
    if (this.drainTimer) {
      clearTimeout(this.drainTimer);
      this.drainTimer = null;
    }
  }

  /** Test seam. */
  pendingCount(): number {
    return this.queue.length;
  }

  // ── Internals ────────────────────────────────────────────────────────────

  private isDuplicate(text: string, priority: AnnouncePriority): boolean {
    if (priority === 'critical') return false;
    const last = this.lastSpoken.get(text);
    if (last === undefined) return false;
    if (Date.now() - last >= DEDUPE_WINDOW_MS) {
      this.lastSpoken.delete(text);
      return false;
    }
    return true;
  }

  private remainingHoldMs(priority: AnnouncePriority): number {
    if (priority === 'critical') return 0;
    return Math.max(0, this.gestureHoldUntil - Date.now());
  }

  private scheduleDrain(delayMs: number): void {
    if (this.drainTimer) clearTimeout(this.drainTimer);
    this.drainTimer = setTimeout(() => {
      this.drainTimer = null;
      this.drain();
    }, delayMs);
  }

  private drain(): void {
    if (this.draining) return;

    const now = Date.now();
    // Stale entries describe a moment that has passed. Critical ones are kept:
    // an error is still worth hearing late.
    this.queue = this.queue.filter(
      entry => entry.priority === 'critical' || now - entry.queuedAt < MAX_QUEUE_AGE_MS,
    );

    const next = this.queue.shift();
    if (!next) return;

    const hold = this.remainingHoldMs(next.priority);
    if (hold > 0) {
      this.queue.unshift(next);
      this.scheduleDrain(hold);
      return;
    }

    this.draining = true;
    this.speak(next);

    // Always arm the estimate timer. `announcementFinished` fires first when
    // iOS delivers it and simply short-circuits this; when it does not fire —
    // which is the common case for queued announcements — this is what keeps
    // the queue moving. Depending on the event alone would wedge the queue.
    const settleMs = estimateUtteranceMs(next.message);
    if (this.drainTimer) clearTimeout(this.drainTimer);
    this.drainTimer = setTimeout(() => {
      this.drainTimer = null;
      this.draining = false;
      this.awaitingFinish = false;
      this.drain();
    }, settleMs);
  }

  private speak(entry: QueueEntry): void {
    const queued = entry.priority !== 'critical';
    try {
      const withOptions = (AccessibilityInfo as any).announceForAccessibilityWithOptions;
      if (Platform.OS === 'ios' && typeof withOptions === 'function') {
        this.awaitingFinish = true;
        withOptions.call(AccessibilityInfo, entry.message, { queue: queued });
        return;
      }
      // Android (and any iOS build without the queued API): the plain call is
      // all that exists. Android's TalkBack does not have the gesture-stealing
      // behaviour this module was written to avoid, so this is fine there.
      AccessibilityInfo.announceForAccessibility(entry.message);
    } catch (error) {
      console.warn('[Announcer] announce failed:', error);
      this.awaitingFinish = false;
    }
  }
}

export const Announcer = new AnnouncerClass();
export default Announcer;
