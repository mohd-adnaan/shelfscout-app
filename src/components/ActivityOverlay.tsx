// src/components/ActivityOverlay.tsx
//
// The persistent state readout that sits over an active turn.
//
// ── Why a VoiceOver user needs this ────────────────────────────────────────
// The app already displayed its state — VoiceVisualizer renders "Listening",
// "Thinking", "Speaking" in the middle of the screen. But that whole subtree
// is `accessibilityElementsHidden`, deliberately: it was absorbed into the
// full-screen tap target, and leaving it visible made VoiceOver read the
// status twice. The consequence was that app state existed only in transient
// announcements. Miss one — because a bus went past, because VoiceOver was
// mid-sentence about something else — and there was no way to ask again. The
// user's only recovery was to tap and see what happened, which during an
// active turn meant cancelling it.
//
// So this overlay does the thing an announcement cannot: it makes the current
// state a FOCUSABLE ELEMENT. Swipe to it, hear where you are, swipe away. It
// is the same information the sighted user gets by glancing at the screen,
// and glancing is exactly what an announcement fails to model.
//
// Three regions, in VoiceOver's reading order:
//   1. Stop — first, because the thing you most need mid-session is out.
//   2. Status — what the app is doing, and to what.
//   3. Guidance — the latest instruction, plus distance when there is one.

import React, { useEffect, useRef } from 'react';
import {
  AccessibilityInfo,
  findNodeHandle,
  Platform,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import { StopIcon } from './MenuIcons';
import { useAppLanguage, useStrings } from '../i18n';
import Announcer from '../a11y/Announcer';
import earcons from '../a11y/earcons';

export interface ActivityOverlayProps {
  /** Short description of what the app is doing, e.g. "Finding the cereal". */
  status: string;
  /** Latest guidance sentence, e.g. "The object is close". */
  guidance?: string | null;
  /** Rendered beside the guidance, e.g. "0.5 m". Announced with it. */
  distanceLabel?: string | null;
  /** Colour of the guidance banner; defaults to a neutral slate. */
  tone?: 'neutral' | 'progress' | 'success' | 'warning';
  onStop: () => void;
  /** Hidden when the turn cannot be cancelled (nothing is running). */
  showStop?: boolean;
  /**
   * Points of right-hand space to keep clear on the top row.
   *
   * The screen this overlay sits on positions its own controls absolutely over
   * the same strip — the settings gear, top-right. The status pill is
   * `flex: 1` and would otherwise stretch underneath one, putting a button on
   * top of the text. Callers pass the width their trailing control occupies
   * plus its offset from the edge.
   */
  trailingInset?: number;
}

const TONE_COLORS: Record<NonNullable<ActivityOverlayProps['tone']>, string> = {
  // All four are >= 4.5:1 against the white text they carry.
  neutral: '#1F2C45',
  progress: '#0F4C81',
  success: '#146B3A',
  warning: '#8A4B00',
};

export const ActivityOverlay: React.FC<ActivityOverlayProps> = ({
  status,
  guidance,
  distanceLabel,
  tone = 'neutral',
  onStop,
  showStop = true,
  trailingInset = 0,
}) => {
  const s = useStrings();
  const language = useAppLanguage();
  const stopRef = useRef<View | null>(null);

  // Put VoiceOver focus on Stop when the overlay appears. A guided mode takes
  // over the camera and the audio channel; landing the user on the way out of
  // it means panic never costs them more than one double-tap.
  useEffect(() => {
    if (!showStop || !Announcer.isScreenReaderEnabled()) return;
    const timer = setTimeout(() => {
      const node = findNodeHandle(stopRef.current);
      if (node != null) AccessibilityInfo.setAccessibilityFocus(node);
    }, 400);
    return () => clearTimeout(timer);
  }, [showStop]);

  // The guidance line is read as one element, so distance belongs inside the
  // label rather than as a neighbouring element the user has to swipe to and
  // mentally re-join with the sentence it modifies.
  const guidanceLabel = [guidance, distanceLabel].filter(Boolean).join('. ');

  return (
    <View style={styles.container} pointerEvents="box-none">
      <View style={styles.topRow} pointerEvents="box-none">
        {showStop ? (
          <TouchableOpacity
            ref={stopRef as React.Ref<any>}
            style={styles.stopButton}
            onPress={() => {
              Announcer.holdForGesture();
              earcons.play('select');
              onStop();
            }}
            accessible
            accessibilityRole="button"
            accessibilityLabel={s.overlay.stopLabel}
            accessibilityHint={s.overlay.stopHint}
            accessibilityLanguage={language}
            hitSlop={{ top: 14, bottom: 14, left: 14, right: 14 }}
          >
            <StopIcon size={30} color="#FFFFFF" />
          </TouchableOpacity>
        ) : (
          <View style={styles.stopButtonPlaceholder} />
        )}

        <View
          style={[styles.statusPill, trailingInset > 0 && { marginRight: trailingInset }]}
          // Read-only: pointer events pass straight through so the existing
          // "tap anywhere to stop" gesture still reaches the surface beneath.
          // On iOS this only disables hit-testing — the view stays an
          // accessibility element, so VoiceOver can still focus and read it.
          pointerEvents="none"
          accessible
          // Not a live region: on iOS RN has none, and an element the user can
          // deliberately re-read is worth more here than one that interrupts.
          // Transitions are announced through Announcer; this is the record
          // the user can come back to.
          accessibilityRole="text"
          accessibilityLabel={s.overlay.statusLabel(status)}
          accessibilityLanguage={language}
        >
          <Text
            style={styles.statusText}
            accessible={false}
            importantForAccessibility="no"
            maxFontSizeMultiplier={1.5}
            numberOfLines={2}
          >
            {status}
          </Text>
        </View>
      </View>

      {guidanceLabel ? (
        <View
          style={[styles.guidanceBanner, { backgroundColor: TONE_COLORS[tone] }]}
          pointerEvents="none"
          accessible
          accessibilityRole="text"
          accessibilityLabel={guidanceLabel}
          accessibilityLanguage={language}
        >
          <Text
            style={styles.guidanceText}
            accessible={false}
            importantForAccessibility="no"
            maxFontSizeMultiplier={1.6}
            numberOfLines={3}
          >
            {guidance}
          </Text>
          {distanceLabel ? (
            <View style={styles.distanceChip} accessible={false} importantForAccessibility="no-hide-descendants">
              <Text style={styles.distanceText} maxFontSizeMultiplier={1.4} numberOfLines={1}>
                {distanceLabel}
              </Text>
            </View>
          ) : null}
        </View>
      ) : null}
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    ...StyleSheet.absoluteFillObject,
    justifyContent: 'space-between',
    paddingTop: Platform.OS === 'ios' ? 58 : 22,
    paddingBottom: Platform.OS === 'ios' ? 40 : 24,
    paddingHorizontal: 16,
  },
  topRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
  },
  stopButton: {
    width: 56,
    height: 56,
    borderRadius: 28,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#B3261E',
    borderWidth: 1.5,
    borderColor: 'rgba(255,255,255,0.5)',
  },
  stopButtonPlaceholder: {
    width: 56,
    height: 56,
  },
  statusPill: {
    flex: 1,
    marginLeft: 12,
    minHeight: 56,
    justifyContent: 'center',
    backgroundColor: 'rgba(17,26,46,0.94)',
    borderRadius: 16,
    paddingHorizontal: 16,
    paddingVertical: 10,
    borderWidth: 1.5,
    borderColor: 'rgba(255,255,255,0.32)',
  },
  statusText: {
    color: '#FFFFFF',
    fontSize: 20,
    fontWeight: '700',
  },
  guidanceBanner: {
    flexDirection: 'row',
    alignItems: 'center',
    borderRadius: 20,
    paddingVertical: 16,
    paddingHorizontal: 20,
    borderWidth: 1.5,
    borderColor: 'rgba(255,255,255,0.4)',
  },
  guidanceText: {
    flex: 1,
    color: '#FFFFFF',
    fontSize: 22,
    fontWeight: '700',
    lineHeight: 28,
  },
  distanceChip: {
    marginLeft: 14,
    minWidth: 74,
    height: 74,
    borderRadius: 37,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: 2,
    borderColor: 'rgba(255,255,255,0.75)',
    paddingHorizontal: 8,
  },
  distanceText: {
    color: '#FFFFFF',
    fontSize: 18,
    fontWeight: '700',
  },
});

export default ActivityOverlay;
