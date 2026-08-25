/**
 * VoiceOver reachability of the home screen's controls.
 *
 * ── The invariant being guarded ────────────────────────────────────────────
 * `TouchableWithoutFeedback` clones its child and force-sets `accessible:
 * true` on it. On iOS that collapses the entire subtree into ONE accessibility
 * element: every descendant is absorbed and can never take VoiceOver focus.
 *
 * That is intentional for the tap-anywhere surface, which is meant to be a
 * single screen-wide button. It is fatal for anything else placed inside it.
 * A settings gear nested under that surface was, for one pilot build, simply
 * unreachable — a blind participant had no way to change language or speech
 * rate at all, and nothing on screen indicated the control existed.
 *
 * So every interactive control must be a SIBLING of the tap surface, never a
 * child. These tests fail if anyone moves one back inside.
 *
 * ── What changed ───────────────────────────────────────────────────────────
 * The home screen is now an action menu rather than a bare tap target, so the
 * same invariant is checked against a longer list of controls: each menu row
 * must be independently focusable, because the menu's whole purpose is that a
 * VoiceOver user can enumerate the app by swiping through it. A menu that
 * collapsed into one element would be strictly worse than the screen it
 * replaced.
 *
 * @format
 */

import React from 'react';
import ReactTestRenderer from 'react-test-renderer';
import type { ReactTestInstance } from 'react-test-renderer';
import App from '../App';
import { en } from '../src/i18n/strings/en';

// Must outlast STARTUP_LOADER_MIN_MS (1800ms) so we get past the branded
// loader screen and render the real home tree.
const PAST_STARTUP_LOADER_MS = 3000;

/** Only host ("string type") nodes reach the native accessibility tree. */
const isHost = (node: ReactTestInstance): boolean => typeof node.type === 'string';

const byLabel = (renderer: ReactTestRenderer.ReactTestRenderer, label: string) =>
  renderer.root.findAll(
    node => isHost(node) && node.props?.accessibilityLabel === label,
    { deep: true },
  );

/** Labels of every `accessible` host ancestor above `node`. */
const swallowingAncestors = (node: ReactTestInstance): string[] => {
  const found: string[] = [];
  for (let current = node.parent; current; current = current.parent) {
    if (isHost(current) && current.props?.accessible === true) {
      found.push(String(current.props?.accessibilityLabel ?? current.type));
    }
  }
  return found;
};

async function renderHomeScreen() {
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

describe('home screen VoiceOver reachability', () => {
  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  // Order matters: this is the order VoiceOver reads them in, and "Describe"
  // leads because it is the one row that needs nothing but a press.
  const MENU_LABELS = [
    en.menu.items.describe.label,
    en.menu.items.ask.label,
    en.menu.items.find.label,
    en.menu.items.navigate.label,
    en.menu.items.repeat.label,
  ];

  it('exposes every menu action as its own accessibility element', async () => {
    const renderer = await renderHomeScreen();

    for (const label of MENU_LABELS) {
      const matches = byLabel(renderer, label);
      expect({ label, count: matches.length }).toEqual({ label, count: 1 });
      expect(matches[0].props.accessibilityRole).toBe('button');
      // A hint is not decoration here: it is the only place the UI says
      // whether the row will open the microphone or act immediately, which is
      // the difference between waiting to speak and missing the moment.
      expect(String(matches[0].props.accessibilityHint ?? '')).not.toBe('');
    }

    await ReactTestRenderer.act(() => {
      renderer.unmount();
    });
  });

  it('does not nest any menu action inside an accessible ancestor', async () => {
    const renderer = await renderHomeScreen();

    for (const label of MENU_LABELS) {
      const [row] = byLabel(renderer, label);
      expect(row).toBeDefined();
      expect({ label, ancestors: swallowingAncestors(row) }).toEqual({
        label,
        ancestors: [],
      });
    }

    await ReactTestRenderer.act(() => {
      renderer.unmount();
    });
  });

  it('exposes the settings gear as its own reachable element', async () => {
    const renderer = await renderHomeScreen();

    const gears = byLabel(renderer, en.menu.settingsLabel);
    expect(gears.length).toBeGreaterThan(0);
    expect(swallowingAncestors(gears[0])).toEqual([]);

    await ReactTestRenderer.act(() => {
      renderer.unmount();
    });
  });

  it('hides the camera preview from the accessibility tree', async () => {
    const renderer = await renderHomeScreen();

    // The camera is mounted behind the menu so a no-speech action can capture
    // immediately. It must never become a focusable element: a VoiceOver user
    // swiping the menu would hit an unlabelled view between two rows and have
    // no way to tell what it was.
    const cameras = renderer.root.findAll(
      node => isHost(node) && node.props?.accessibilityElementsHidden === true,
      { deep: true },
    );
    expect(cameras.length).toBeGreaterThan(0);

    await ReactTestRenderer.act(() => {
      renderer.unmount();
    });
  });
});
