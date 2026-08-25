// src/components/DestinationPicker.tsx
//
// Pick a saved destination from a list instead of speaking it.
//
// ── Why this is the highest-value screen in the app ────────────────────────
// Starting navigation used to require, in order: an open microphone, an
// accurate transcription, a reachable network, an LLM classifying the
// utterance as `navigation`, that same LLM extracting the destination, and
// then a fuzzy match of the extracted string against the saved route
// vocabulary. Six things, any of which can fail, to select one item from a
// list the device already has on disk.
//
// The pilot's clearest failure was the transcription-to-vocabulary step:
// "cereal" came back as "serial", and TargetGroundingService exists largely to
// paper over that class of mistake. But the destinations are a CLOSED SET,
// known before the user says anything. Rendering them as buttons removes all
// six failure points — no microphone, no network, no model, no matching. The
// user picks the exact string the route map was saved under, so the match is
// an identity comparison that cannot be wrong.
//
// Speaking a destination still works and is still faster when it works. This
// is the path that always works.

import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  AccessibilityInfo,
  ActivityIndicator,
  findNodeHandle,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import {
  ARKitNavigationBridge,
  ARKitNavigationTargetEntry,
} from '../native/ARKitNavigationModule';
import { useAppLanguage, useStrings } from '../i18n';
import Announcer from '../a11y/Announcer';
import earcons from '../a11y/earcons';

export interface DestinationPickerProps {
  onSelect: (entry: ARKitNavigationTargetEntry) => void;
  onCancel: () => void;
}

type LoadState = 'loading' | 'ready' | 'empty' | 'error';

export const DestinationPicker: React.FC<DestinationPickerProps> = ({
  onSelect,
  onCancel,
}) => {
  const s = useStrings();
  const language = useAppLanguage();
  const [state, setState] = useState<LoadState>('loading');
  const [entries, setEntries] = useState<ARKitNavigationTargetEntry[]>([]);
  const headingRef = useRef<Text | null>(null);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        const result = (await ARKitNavigationBridge.availableNavigationTargets()) || [];
        if (cancelled) return;

        // The same label can appear in several route maps (a store mapped in
        // two passes). Collapsing by label keeps the list the length the user
        // expects; the first map wins, matching what the spoken path resolves
        // to today.
        const seen = new Set<string>();
        const unique = result.filter(entry => {
          const key = (entry?.label || '').trim().toLowerCase();
          if (!key || seen.has(key)) return false;
          seen.add(key);
          return true;
        });

        setEntries(unique);
        setState(unique.length > 0 ? 'ready' : 'empty');
      } catch (error) {
        if (cancelled) return;
        console.warn('[DestinationPicker] Failed to load targets:', error);
        setState('error');
      }
    })();

    return () => {
      cancelled = true;
    };
  }, []);

  // Announce the outcome once loading settles. The list arriving is a change
  // the user cannot see, and without this the screen is silent until they
  // happen to swipe onto something.
  useEffect(() => {
    if (state === 'loading') return;
    const message =
      state === 'ready'
        ? s.destinations.countAnnouncement(entries.length)
        : state === 'empty'
          ? s.destinations.empty
          : s.destinations.loadFailed;
    Announcer.announce(message, { priority: state === 'ready' ? 'status' : 'critical' });

    if (Announcer.isScreenReaderEnabled()) {
      const timer = setTimeout(() => {
        const node = findNodeHandle(headingRef.current);
        if (node != null) AccessibilityInfo.setAccessibilityFocus(node);
      }, 250);
      return () => clearTimeout(timer);
    }
  }, [state, entries.length, s]);

  const handleSelect = useCallback(
    (entry: ARKitNavigationTargetEntry) => {
      Announcer.holdForGesture();
      earcons.play('select');
      onSelect(entry);
    },
    [onSelect],
  );

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity
          style={styles.backButton}
          onPress={() => {
            Announcer.holdForGesture();
            earcons.play('select');
            onCancel();
          }}
          accessible
          accessibilityRole="button"
          accessibilityLabel={s.destinations.backLabel}
          accessibilityHint={s.destinations.backHint}
          accessibilityLanguage={language}
          hitSlop={{ top: 12, bottom: 12, left: 12, right: 12 }}
        >
          <Text style={styles.backGlyph} accessible={false} importantForAccessibility="no">
            ✕
          </Text>
        </TouchableOpacity>

        <Text
          ref={headingRef as React.Ref<any>}
          style={styles.title}
          accessibilityRole="header"
          accessibilityLanguage={language}
          maxFontSizeMultiplier={1.6}
        >
          {s.destinations.title}
        </Text>
      </View>

      {state === 'loading' ? (
        <View
          style={styles.centered}
          accessible
          accessibilityRole="text"
          accessibilityLabel={s.destinations.loading}
          accessibilityLanguage={language}
        >
          <ActivityIndicator size="large" color="#FFFFFF" />
        </View>
      ) : state === 'ready' ? (
        <ScrollView
          contentContainerStyle={styles.listContent}
          showsVerticalScrollIndicator={false}
          alwaysBounceVertical={false}
        >
          {entries.map((entry, index) => (
            <TouchableOpacity
              key={`${entry.mapId}:${entry.label}:${index}`}
              style={styles.row}
              onPress={() => handleSelect(entry)}
              activeOpacity={0.75}
              accessible
              accessibilityRole="button"
              accessibilityLabel={entry.label}
              accessibilityHint={s.destinations.rowHint}
              accessibilityLanguage={language}
            >
              <Text
                style={styles.rowLabel}
                accessible={false}
                importantForAccessibility="no"
                maxFontSizeMultiplier={1.8}
                numberOfLines={3}
              >
                {entry.label}
              </Text>
            </TouchableOpacity>
          ))}
        </ScrollView>
      ) : (
        <View
          style={styles.centered}
          accessible
          accessibilityRole="text"
          accessibilityLabel={state === 'empty' ? s.destinations.empty : s.destinations.loadFailed}
          accessibilityLanguage={language}
        >
          <Text
            style={styles.emptyText}
            accessible={false}
            importantForAccessibility="no"
            maxFontSizeMultiplier={1.6}
          >
            {state === 'empty' ? s.destinations.empty : s.destinations.loadFailed}
          </Text>
        </View>
      )}
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
    paddingTop: Platform.OS === 'ios' ? 60 : 24,
    paddingHorizontal: 16,
    paddingBottom: 14,
  },
  backButton: {
    width: 48,
    height: 48,
    borderRadius: 24,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'rgba(255,255,255,0.10)',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.28)',
    marginRight: 14,
  },
  backGlyph: {
    color: '#FFFFFF',
    fontSize: 22,
    fontWeight: '600',
  },
  title: {
    flex: 1,
    color: '#FFFFFF',
    fontSize: 26,
    fontWeight: '700',
  },
  listContent: {
    paddingHorizontal: 16,
    paddingBottom: 28,
  },
  row: {
    minHeight: 84,
    justifyContent: 'center',
    borderRadius: 16,
    paddingVertical: 18,
    paddingHorizontal: 20,
    marginBottom: 12,
    backgroundColor: '#5B2BB5',
    borderWidth: 1.5,
    borderColor: 'rgba(255,255,255,0.35)',
  },
  rowLabel: {
    color: '#FFFFFF',
    fontSize: 23,
    fontWeight: '700',
    lineHeight: 29,
  },
  centered: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 28,
  },
  emptyText: {
    color: '#FFFFFF',
    fontSize: 20,
    fontWeight: '600',
    textAlign: 'center',
    lineHeight: 28,
  },
});

export default DestinationPicker;
