// src/components/ActionMenu.tsx
//
// The home screen: one large, explicitly-labelled button per capability.
//
// ── Why this replaced "tap anywhere" ───────────────────────────────────────
// The previous home screen was a single full-screen `TouchableWithoutFeedback`
// whose accessibilityLabel changed with app state. For a VoiceOver user that
// screen contained exactly two elements — "Ready. Tap to speak" and the
// settings gear — which produced three problems that no amount of tuning
// inside that design could fix:
//
//   • Nothing was discoverable. Swiping right revealed no capabilities, so
//     the only way to learn what the app could do was to already know.
//   • Every action had to be spoken, so every action inherited the failure
//     modes of the whole chain: microphone session, transcription accuracy,
//     network reachability, and an LLM intent classifier. Asking for the same
//     thing twice could route two different ways. That is the specific thing
//     users described as the app being unpredictable.
//   • "Tap anywhere" is not a gesture VoiceOver forwards. With VoiceOver on,
//     a tap moves focus; only a double-tap on a focused element activates. A
//     full-screen target is the hardest possible thing to focus deliberately,
//     so the primary affordance was the one least suited to the primary user.
//
// A list of named buttons fixes all three at once. Each row is a distinct
// VoiceOver element, so swipe-to-explore enumerates the app's entire
// capability set. Each row maps to exactly one action with no classifier in
// the path, so the same press always does the same thing. That determinism is
// what makes an assistive app feel trustworthy — far more than accuracy does,
// because a user can work around a tool that is consistently wrong and cannot
// work around one that is unpredictably right.
//
// Voice input is still here — it is the first row, and it is still the only
// way to express something the menu does not cover. It is now a choice among
// options rather than the sole entry point.

import React, { useCallback, useEffect, useMemo, useRef } from 'react';
import {
  AccessibilityInfo,
  findNodeHandle,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import {
  AskIcon,
  DescribeIcon,
  FindIcon,
  GearIcon,
  MenuIconProps,
  RepeatIcon,
  RouteIcon,
} from './MenuIcons';
import { useStrings } from '../i18n';
import { useAppLanguage } from '../i18n';
import Announcer from '../a11y/Announcer';
import earcons from '../a11y/earcons';

/**
 * Every action the menu can dispatch.
 *
 * `ask` and `find` collect a spoken argument; the rest need no speech at all.
 * That split is the point of the whole screen — three of the five capabilities
 * become reachable with the microphone switched off.
 */
export type MenuActionId =
  | 'describe'
  | 'ask'
  | 'find'
  | 'navigate'
  | 'repeat';

interface MenuItemSpec {
  id: MenuActionId;
  Icon: React.FC<MenuIconProps>;
  /** Background. Each is >= 4.5:1 against white text (WCAG 1.4.3). */
  color: string;
}

// Distinct hues, not a gradient: users with residual vision reported
// navigating this screen by colour before the label finished being read, and
// neighbouring shades of one hue defeat that.
//
// Ordered by expected frequency, and "Describe" leads because it is the only
// row that needs nothing from the user but a press — no speaking, so nothing
// to mishear. It is the shortest swipe from the top for the same reason it is
// the most reliable.
//
// There was a sixth row, "Read text". It sent a different canonical command to
// the same endpoint and came back with the same kind of answer, because scene
// description already reads text in the frame. Two rows that do one thing cost
// a VoiceOver user a swipe every time they pass through the menu and force a
// choice with no correct answer, so it was removed rather than reworded.
const ITEMS: MenuItemSpec[] = [
  { id: 'describe', Icon: DescribeIcon, color: '#0B6E4F' },
  { id: 'ask', Icon: AskIcon, color: '#1057C4' },
  { id: 'find', Icon: FindIcon, color: '#A8480A' },
  { id: 'navigate', Icon: RouteIcon, color: '#5B2BB5' },
  { id: 'repeat', Icon: RepeatIcon, color: '#31456A' },
];

export interface ActionMenuProps {
  onAction: (id: MenuActionId) => void;
  onOpenSettings: () => void;
  /**
   * Whether a previous answer exists to repeat. The row stays mounted and
   * visible when false but reports `disabled` so VoiceOver says so, rather
   * than disappearing — a menu whose row count changes between visits forces
   * the user to re-learn the layout every time.
   */
  canRepeat: boolean;
  /** Suppresses press feedback while a turn is already running. */
  busy?: boolean;
}

const MIN_TOUCH_TARGET = 44;

export const ActionMenu: React.FC<ActionMenuProps> = ({
  onAction,
  onOpenSettings,
  canRepeat,
  busy = false,
}) => {
  const s = useStrings();
  const language = useAppLanguage();
  const firstItemRef = useRef<View | null>(null);

  // Move VoiceOver focus to the first action on mount. Without this, focus
  // lands wherever iOS decides — often the status bar — and the user has to
  // swipe blindly to find out they are on a new screen.
  useEffect(() => {
    if (!Announcer.isScreenReaderEnabled()) return;
    const timer = setTimeout(() => {
      const node = findNodeHandle(firstItemRef.current);
      if (node != null) AccessibilityInfo.setAccessibilityFocus(node);
    }, 350);
    return () => clearTimeout(timer);
  }, []);

  const handlePress = useCallback(
    (id: MenuActionId) => {
      // Hold non-critical speech across the activation so VoiceOver can finish
      // handling the gesture before anything else talks.
      Announcer.holdForGesture();
      earcons.play('select');
      onAction(id);
    },
    [onAction],
  );

  const rows = useMemo(
    () =>
      ITEMS.map(item => ({
        ...item,
        label: s.menu.items[item.id].label,
        hint: s.menu.items[item.id].hint,
        disabled: item.id === 'repeat' && !canRepeat,
      })),
    [s, canRepeat],
  );

  return (
    <View style={styles.container}>
      {/*
        The title is a header so VoiceOver's rotor "Headings" navigation can
        jump straight back to the top of the menu from anywhere on the screen.
      */}
      <View style={styles.header}>
        <Text
          style={styles.title}
          accessibilityRole="header"
          accessibilityLanguage={language}
          maxFontSizeMultiplier={1.6}
        >
          {s.menu.title}
        </Text>

        <TouchableOpacity
          style={styles.gearButton}
          onPress={() => {
            Announcer.holdForGesture();
            earcons.play('select');
            onOpenSettings();
          }}
          accessible
          accessibilityRole="button"
          accessibilityLabel={s.menu.settingsLabel}
          accessibilityHint={s.menu.settingsHint}
          accessibilityLanguage={language}
          hitSlop={{ top: 12, bottom: 12, left: 12, right: 12 }}
        >
          <GearIcon size={26} color="#FFFFFF" />
        </TouchableOpacity>
      </View>

      <ScrollView
        style={styles.scroll}
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
        // Large text settings can push the last row below the fold; without
        // this the user can focus a row VoiceOver cannot scroll into view.
        alwaysBounceVertical={false}
      >
        {rows.map((row, index) => (
          <TouchableOpacity
            key={row.id}
            ref={index === 0 ? (firstItemRef as React.Ref<any>) : undefined}
            style={[
              styles.row,
              { backgroundColor: row.color },
              row.disabled && styles.rowDisabled,
            ]}
            onPress={() => handlePress(row.id)}
            disabled={row.disabled || busy}
            activeOpacity={0.75}
            accessible
            accessibilityRole="button"
            accessibilityLabel={row.label}
            accessibilityHint={row.hint}
            // iOS reads the label with this language's phonetics. Without it a
            // French label under an English VoiceOver voice is read as if it
            // were English, which is close to unintelligible.
            accessibilityLanguage={language}
            accessibilityState={{ disabled: row.disabled || busy, busy }}
          >
            <View style={styles.rowIcon} accessible={false} importantForAccessibility="no-hide-descendants">
              <row.Icon size={36} color="#FFFFFF" />
            </View>
            <Text
              style={styles.rowLabel}
              accessible={false}
              importantForAccessibility="no"
              // Cap growth so the largest accessibility text sizes do not push
              // the label out of its row; the row scrolls, the text does not
              // need to reflow past three lines.
              maxFontSizeMultiplier={1.8}
              numberOfLines={3}
            >
              {row.label}
            </Text>
          </TouchableOpacity>
        ))}
      </ScrollView>
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#111A2E',
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingTop: Platform.OS === 'ios' ? 60 : 24,
    paddingHorizontal: 20,
    paddingBottom: 12,
  },
  title: {
    color: '#FFFFFF',
    fontSize: 26,
    fontWeight: '700',
    letterSpacing: 0.2,
    flexShrink: 1,
  },
  gearButton: {
    width: MIN_TOUCH_TARGET,
    height: MIN_TOUCH_TARGET,
    borderRadius: MIN_TOUCH_TARGET / 2,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'rgba(255,255,255,0.10)',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.28)',
    marginLeft: 12,
  },
  scroll: {
    flex: 1,
  },
  scrollContent: {
    paddingHorizontal: 16,
    paddingBottom: 28,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    // Two 30pt lines plus 18pt padding top and bottom comes to exactly 96, so
    // 96 leaves a label like "Describe my surroundings" — which wraps on every
    // phone width — touching the row's edges. 104 gives it room without making
    // the single-line rows look empty.
    minHeight: 104,
    borderRadius: 18,
    paddingVertical: 18,
    paddingHorizontal: 20,
    marginBottom: 12,
    // A light border keeps the rows separable under Increase Contrast and for
    // users whose colour perception does not distinguish the fills.
    borderWidth: 1.5,
    borderColor: 'rgba(255,255,255,0.35)',
  },
  rowDisabled: {
    opacity: 0.45,
  },
  rowIcon: {
    width: 44,
    alignItems: 'center',
    marginRight: 16,
  },
  rowLabel: {
    flex: 1,
    color: '#FFFFFF',
    fontSize: 24,
    fontWeight: '700',
    lineHeight: 30,
  },
});

export default ActionMenu;
