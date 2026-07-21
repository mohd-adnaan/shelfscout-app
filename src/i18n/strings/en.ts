// src/i18n/strings/en.ts
//
// English string catalog. This file is the SOURCE OF TRUTH for the catalog
// shape: `fr.ts` is typed as `StringCatalog`, so TypeScript fails the build if
// a French key is missing or its interpolation signature drifts. Add keys here
// first, then translate.
//
// Only strings the user can HEAR or READ belong here. Console logs stay inline
// in English — they are developer output, not product copy.

export const en = {
  // ── Spoken + VoiceOver-announced runtime strings ─────────────────────────
  speech: {
    tapToSpeak: 'Tap to speak.',
    thinking: 'Thinking.',
    stopping: 'Stopping.',
    stoppingMode: (mode: string) => `Stopping ${mode}.`,
    noVoiceInput: 'No voice input detected. Tap to try again.',
    errorStartingVoice: 'Error starting voice. Tap to try again.',
    processingWithoutPhoto: 'Processing without photo.',
    photoCaptureFailed:
      'Warning: Failed to capture photo. Continuing with voice only.',
    stoppedTimeLimit: 'Stopped due to time limit.',
    requestFailed: 'Error processing your request. Try again.',
    genericError: (detail: string) => `Error: ${detail}`,
  },

  // ── Reaching guidance ────────────────────────────────────────────────────
  reaching: {
    guidingTo: (target: string) =>
      `Guiding you to ${target}. Follow the audio beeps. Tap anywhere when you have it.`,
    reached: (object: string) => `${object} reached!`,
    ended: 'Reaching guidance ended.',
    error: (detail: string) => `Reaching error: ${detail}`,
    unknownError: 'Unknown error',
    relocalizationTimeout:
      'I could not match the saved map here. Move closer to the mapped shelf and try again.',
    mapNotFound:
      'The saved AR map for this target was not found on this device.',
    spatialTargetUnavailable:
      'Spatial Target reaching is not available. Please rebuild the app.',
    moduleUnavailable:
      'Reaching module not available. Please rebuild the app.',
    noPreciseCoordinates: (object: string) =>
      `I can detect the ${object} in the scene, but I could not get precise coordinates for guidance. Try pointing your camera more directly at it and ask again.`,
    defaultObjectName: 'object',
  },

  // ── Settings: language section ───────────────────────────────────────────
  settings: {
    languageSection: 'Language',
    languageDescription:
      'Choose the language ShelfScout speaks and listens in. Voice guidance, wake word, and on-screen text all follow this setting.',
    languageChanged: 'Language set to English.',
    languageOptionAccessibilityLabel: (language: string, selected: boolean) =>
      `${language}${selected ? ', currently selected' : ''}`,
    languageOptionAccessibilityHint: 'Double tap to select',
  },
};

/**
 * Catalog shape every language must satisfy. Derived from English so the
 * compiler enforces parity instead of a runtime check.
 */
export type StringCatalog = typeof en;
