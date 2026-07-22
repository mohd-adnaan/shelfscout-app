/**
 * VoiceOver reachability of the main screen's controls.
 *
 * The main screen is deliberately ONE screen-wide VoiceOver button ("Ready.
 * Tap to speak"), built with TouchableWithoutFeedback. That Touchable clones
 * its child and force-sets `accessible: true` on it, which on iOS turns the
 * whole subtree into a single accessibility element — every descendant is
 * absorbed and can never take VoiceOver focus.
 *
 * The settings gear therefore has to be a SIBLING of the tap surface. When it
 * was nested inside, a blind participant could not reach Settings at all (no
 * way to change language or speech rate). This test fails if anyone moves it
 * back under an `accessible` ancestor.
 *
 * @format
 */

import React from 'react';
import ReactTestRenderer from 'react-test-renderer';
import type { ReactTestInstance } from 'react-test-renderer';
import App from '../App';

// Must outlast STARTUP_LOADER_MIN_MS (1800ms) so we get past the branded
// loader screen and render the real main tree.
const PAST_STARTUP_LOADER_MS = 3000;

const SETTINGS_LABEL = 'Open settings';

/** Only host ("string type") nodes reach the native accessibility tree. */
const isHost = (node: ReactTestInstance): boolean => typeof node.type === 'string';

async function renderMainScreen() {
  let renderer: ReactTestRenderer.ReactTestRenderer | undefined;

  await ReactTestRenderer.act(async () => {
    renderer = ReactTestRenderer.create(<App />);
  });

  // Let the startup loader's setTimeout fire, then flush the resulting render.
  await ReactTestRenderer.act(async () => {
    jest.advanceTimersByTime(PAST_STARTUP_LOADER_MS);
  });

  return renderer!;
}

describe('main screen VoiceOver reachability', () => {
  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('exposes the settings gear as its own accessibility element', async () => {
    const renderer = await renderMainScreen();

    const gears = renderer.root.findAll(
      node => isHost(node) && node.props?.accessibilityLabel === SETTINGS_LABEL,
      { deep: true },
    );

    expect(gears.length).toBeGreaterThan(0);

    await ReactTestRenderer.act(() => {
      renderer.unmount();
    });
  });

  it('does not nest the settings gear inside an accessible ancestor', async () => {
    const renderer = await renderMainScreen();

    const [gear] = renderer.root.findAll(
      node => isHost(node) && node.props?.accessibilityLabel === SETTINGS_LABEL,
      { deep: true },
    );

    // Walk up the host ancestry. Any ancestor with accessible===true would
    // swallow the gear into itself and hide it from VoiceOver.
    const swallowingAncestors: string[] = [];
    for (let node = gear.parent; node; node = node.parent) {
      if (isHost(node) && node.props?.accessible === true) {
        swallowingAncestors.push(
          String(node.props?.accessibilityLabel ?? node.type),
        );
      }
    }

    expect(swallowingAncestors).toEqual([]);

    await ReactTestRenderer.act(() => {
      renderer.unmount();
    });
  });
});
