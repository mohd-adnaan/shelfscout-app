// src/services/NativeLanguageSync.ts
//
// Pushes the app language down to the native (Swift) speech layer.
//
// Native owns a separate copy of the language because SemanticRouteNavigator
// and the reaching controllers build their spoken cues in Swift, not JS. This
// module is the one place that keeps the two copies in step: subscribe once,
// and every future `setAppLanguage` call propagates automatically, whoever
// triggered it.

import { ARKitNavigationBridge } from '../native/ARKitNavigationModule';
import { AppLanguage, getAppLanguage, onAppLanguageChange } from '../i18n';

let started = false;

async function pushToNative(language: AppLanguage): Promise<void> {
  try {
    // Guard the method itself, not just the module: an app running against a
    // native binary built before setLanguage existed would otherwise throw on
    // every language change.
    if (typeof ARKitNavigationBridge.setLanguage !== 'function') {
      console.warn(
        '[i18n] Native setLanguage unavailable — rebuild the iOS app for localized native guidance',
      );
      return;
    }
    const applied = await ARKitNavigationBridge.setLanguage(language);
    console.log(`🌐 [i18n] Native speech language → ${applied}`);
  } catch (error) {
    // Never let this break a language switch: JS-side speech and UI have
    // already changed, and native falls back to English cues.
    console.warn('[i18n] Failed to set native language:', error);
  }
}

/**
 * Begin mirroring the JS language into native, and push the current value
 * immediately. Safe to call more than once.
 */
export function startNativeLanguageSync(): void {
  if (started) return;
  started = true;

  onAppLanguageChange(language => {
    void pushToNative(language);
  });

  void pushToNative(getAppLanguage());
}
