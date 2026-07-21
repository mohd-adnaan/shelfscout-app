// src/i18n/strings/fr.ts
//
// Quebec French (fr-CA) catalog.
//
// Translation notes for anyone editing this file:
//  - These strings are SPOKEN to blind and low-vision users, so they are
//    written to be heard, not read: short sentences, no abbreviations, no
//    parentheses, and no symbols a synthesizer reads awkwardly.
//  - Quebec usage is preferred over European French where they differ.
//  - French typography normally puts a narrow space before « ! » and « : ».
//    We use a plain space before the colon and none before the exclamation
//    mark, because AVSpeechSynthesizer inserts an audible pause on a
//    non-breaking space.
//
// Typed as StringCatalog: the build fails if a key is missing or a function
// signature drifts from en.ts.

import type { StringCatalog } from './en';

export const fr: StringCatalog = {
  speech: {
    tapToSpeak: 'Touchez pour parler.',
    thinking: 'Je réfléchis.',
    stopping: 'Arrêt.',
    stoppingMode: (mode: string) => `Arrêt : ${mode}.`,
    noVoiceInput: 'Aucune parole détectée. Touchez pour réessayer.',
    errorStartingVoice: 'Erreur au démarrage du micro. Touchez pour réessayer.',
    processingWithoutPhoto: 'Traitement sans photo.',
    photoCaptureFailed:
      'Attention : la photo n’a pas pu être prise. Je continue avec la voix seulement.',
    stoppedTimeLimit: 'Arrêt : limite de temps atteinte.',
    requestFailed: 'Erreur lors du traitement de votre demande. Réessayez.',
    genericError: (detail: string) => `Erreur : ${detail}`,
  },

  reaching: {
    guidingTo: (target: string) =>
      `Je vous guide vers ${target}. Suivez les signaux sonores. Touchez l’écran quand vous l’avez.`,
    reached: (object: string) => `${object} atteint!`,
    ended: 'Guidage terminé.',
    error: (detail: string) => `Erreur de guidage : ${detail}`,
    unknownError: 'erreur inconnue',
    relocalizationTimeout:
      'Je ne reconnais pas la carte enregistrée ici. Approchez-vous de l’étagère cartographiée et réessayez.',
    mapNotFound:
      'La carte AR enregistrée pour cette cible est introuvable sur cet appareil.',
    spatialTargetUnavailable:
      'Le guidage par cible spatiale n’est pas disponible. Veuillez recompiler l’application.',
    moduleUnavailable:
      'Le module de guidage n’est pas disponible. Veuillez recompiler l’application.',
    noPreciseCoordinates: (object: string) =>
      `Je détecte ${object} dans la scène, mais je n’ai pas pu obtenir de coordonnées précises pour le guidage. Pointez la caméra plus directement vers l’objet et redemandez.`,
    defaultObjectName: 'l’objet',
  },

  settings: {
    languageSection: 'Langue',
    languageDescription:
      'Choisissez la langue dans laquelle ShelfScout parle et vous écoute. Le guidage vocal, le mot d’activation et le texte à l’écran suivent ce réglage.',
    languageChanged: 'Langue réglée sur le français.',
    languageOptionAccessibilityLabel: (language: string, selected: boolean) =>
      `${language}${selected ? ', actuellement sélectionné' : ''}`,
    languageOptionAccessibilityHint: 'Touchez deux fois pour sélectionner',
  },
};
