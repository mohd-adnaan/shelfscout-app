/**
 * src/utils/inputLiveness.ts
 *
 * The two rules that keep the app answering taps.
 *
 * Both are one-liners, and both are here rather than inline in App.tsx for the
 * same reason: they are the load-bearing half of the fix for the longest-lived
 * bug this app has had — "the screen says Ready, I keep tapping, nothing
 * happens, I have to force-quit" — and a rule that cannot be tested is a rule
 * nobody can be sure of.
 */

/**
 * Whether a CLAIM about state we do not own is still worth believing.
 *
 * The specific claim that caused the hang: `sessionAlive` from the native AR
 * bridge. Native holds an offered session for at most 120 s and then pauses it
 * on its own, telling JavaScript nothing. The turn watchdog — the only thing
 * that recovers a stuck turn — exempts a turn entirely while that claim is
 * true, so one stale `true` disabled the recovery mechanism permanently, for
 * the rest of the process.
 *
 * A claim about someone else's state is only ever a snapshot. This is what
 * stops a snapshot from being treated as a standing fact.
 *
 * `setAtMs` of 0 means "never claimed", which is never fresh.
 */
export const isClaimFresh = (
  setAtMs: number,
  ttlMs: number,
  now: number = Date.now(),
): boolean => setAtMs > 0 && now - setAtMs < ttlMs;

/**
 * Whether a latch has been held longer than any legitimate holder could.
 *
 * A latch cleared in a `finally` is only as reliable as the awaits inside the
 * `try` — a native promise that never settles means the `finally` is never
 * reached. Rather than trusting that every await is bounded (it was not, and
 * the next one added might not be either), a latch also carries the time it
 * was taken, and anything older than the sum of its bounded steps is a leak
 * rather than work in progress.
 */
export const isLatchStale = (
  heldSinceMs: number,
  maxHoldMs: number,
  now: number = Date.now(),
): boolean => heldSinceMs > 0 && now - heldSinceMs >= maxHoldMs;
