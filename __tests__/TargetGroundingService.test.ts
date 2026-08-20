import {
  foldDiacritics,
  levenshteinDistance,
  matchTargetAgainstVocabulary,
  normalizeSpokenLabel,
  phoneticKey,
} from '../src/services/TargetGroundingService';
import { setAppLanguage } from '../src/i18n';

const vocabulary = [
  { label: 'Cereal', mapId: 'map-1', mapName: 'Store Route' },
  { label: 'Onions', mapId: 'map-1', mapName: 'Store Route' },
  { label: 'Milk', mapId: 'map-2', mapName: 'Dairy Route' },
  { label: 'Aisle 3', mapId: 'map-2', mapName: 'Dairy Route' },
];

describe('TargetGroundingService', () => {
  // The grounding cascade reads the active language from the i18n store, so
  // every English assertion below depends on it being English.
  beforeEach(() => setAppLanguage('en'));

  it('normalizes articles, case, and punctuation', () => {
    expect(normalizeSpokenLabel('The Cereal!')).toBe('cereal');
    expect(normalizeSpokenLabel('aisle-3')).toBe('aisle 3');
  });

  it('computes edit distance', () => {
    expect(levenshteinDistance('onion', 'onions')).toBe(1);
    expect(levenshteinDistance('serial', 'cereal')).toBe(2);
  });

  it('reduces phonetic misrecognitions to the same key', () => {
    expect(phoneticKey('serial')).toBe(phoneticKey('cereal'));
    expect(phoneticKey('milk')).not.toBe(phoneticKey('silk'));
  });

  it('matches exact labels first', () => {
    const result = matchTargetAgainstVocabulary('cereal', vocabulary);
    expect(result.status).toBe('matched');
    expect(result.label).toBe('Cereal');
    expect(result.method).toBe('exact');
    expect(result.mapId).toBe('map-1');
  });

  it('absorbs plural drift via fuzzy matching', () => {
    const result = matchTargetAgainstVocabulary('onion', vocabulary);
    expect(result.status).toBe('matched');
    expect(result.label).toBe('Onions');
    expect(result.method).toBe('fuzzy');
  });

  it('resolves accent-driven ASR slips phonetically', () => {
    const result = matchTargetAgainstVocabulary('serial', vocabulary);
    expect(result.status).toBe('matched');
    expect(result.label).toBe('Cereal');
    expect(result.method).toBe('phonetic');
  });

  it('resolves a phonetic slip stacked on plural drift', () => {
    // "cereals" (spoken) misheard as "serials" carries both a plural 's' the
    // saved singular "Cereal" doesn't have AND the c/s phonetic swap — either
    // drift alone is absorbed by an earlier rung, but stacked together they
    // used to miss every rung and dead-end with "not found".
    const result = matchTargetAgainstVocabulary('serials', vocabulary);
    expect(result.status).toBe('matched');
    expect(result.label).toBe('Cereal');
    expect(result.method).toBe('phonetic');
  });

  it('never lets short labels cross to different words', () => {
    const result = matchTargetAgainstVocabulary('silk', vocabulary);
    expect(result.status).toBe('no_match');
  });

  it('keeps numbered aisles distinct', () => {
    const result = matchTargetAgainstVocabulary('aisle 4', vocabulary);
    expect(result.status).toBe('no_match');
  });

  it('tolerates an extra spoken word around a saved label', () => {
    const rooms = [
      { label: '400 Lounge', mapId: 'map-3', mapName: 'Office Route' },
      { label: 'Kitchen', mapId: 'map-3', mapName: 'Office Route' },
    ];
    const result = matchTargetAgainstVocabulary('400 lounge room', rooms);
    expect(result.status).toBe('matched');
    expect(result.label).toBe('400 Lounge');
    expect(result.method).toBe('contains');
  });

  it('prefers the most specific label when several are contained', () => {
    const rooms = [
      { label: 'Lounge', mapId: 'map-3', mapName: 'Office Route' },
      { label: '400 Lounge', mapId: 'map-3', mapName: 'Office Route' },
    ];
    const result = matchTargetAgainstVocabulary('the 400 lounge room', rooms);
    expect(result.status).toBe('matched');
    expect(result.label).toBe('400 Lounge');
  });

  it('refuses to guess when containment is ambiguous', () => {
    const rooms = [
      { label: 'North Lounge', mapId: 'map-3', mapName: 'Office Route' },
      { label: 'South Lounge', mapId: 'map-3', mapName: 'Office Route' },
    ];
    const result = matchTargetAgainstVocabulary('lounge', rooms);
    expect(result.status).toBe('no_match');
  });

  it('never lets containment cross a room number', () => {
    const rooms = [
      { label: '400 Lounge', mapId: 'map-3', mapName: 'Office Route' },
      { label: '500 Lounge', mapId: 'map-3', mapName: 'Office Route' },
    ];
    expect(matchTargetAgainstVocabulary('500 lounge room', rooms).label).toBe('500 Lounge');
    expect(matchTargetAgainstVocabulary('lounge room', rooms).status).toBe('no_match');
  });

  // ── Phonetic containment ────────────────────────────────────────────────
  // Field failure, 20 Aug 2026: the saved label was "Krave cereal" and the
  // request kept dead-ending with "I could not find … saved destinations
  // include Krave cereal". Dictation hears "crave"/"serial", and the target
  // handed down is often only part of the label or the label plus a filler —
  // none of which reach the whole-string phonetic rung, because that compares
  // the full string. Whether a query worked came down to whether the
  // classifier happened to return the exact label, which is why the same
  // request succeeded roughly once in ten.
  describe('phonetic containment', () => {
    const shelves = [
      { label: 'Krave cereal', mapId: 'map-4', mapName: 'Store Route' },
      { label: 'Onions', mapId: 'map-4', mapName: 'Store Route' },
    ];

    it.each([
      ['crave', 'a partial label with a hard-c slip'],
      ['serials', 'a partial label with a soft-c slip and plural drift'],
      ['cereals', 'a partial label with plural drift'],
      ['crave cereal aisle', 'the full label plus a filler word'],
      ['the crave serial', 'an article, plus slips in both tokens'],
    ])('resolves %s (%s)', requested => {
      const result = matchTargetAgainstVocabulary(requested, shelves);
      expect(result.status).toBe('matched');
      expect(result.label).toBe('Krave cereal');
    });

    it('never outranks a literal containment match', () => {
      // "contains", not "phonetic_contains": the literal pass runs first so a
      // label that matches on the words themselves is never displaced by one
      // that only matches by sound.
      const rooms = [
        { label: '400 Lounge', mapId: 'map-5', mapName: 'Office Route' },
        { label: 'Kitchen', mapId: 'map-5', mapName: 'Office Route' },
      ];
      expect(matchTargetAgainstVocabulary('400 lounge room', rooms).method).toBe('contains');
    });

    it('still refuses the invariants the looser rung could have crossed', () => {
      // Short words must not cross on sound alone, digits must still agree,
      // and an unrelated word must not collide with a short skeleton.
      expect(matchTargetAgainstVocabulary('silk', vocabulary).status).toBe('no_match');
      expect(matchTargetAgainstVocabulary('aisle 4', vocabulary).status).toBe('no_match');
      expect(matchTargetAgainstVocabulary('quinoa', vocabulary).status).toBe('no_match');
    });

    it('keeps working for numbered labels', () => {
      // phoneticKey passes digits through, so "Cereal 3" keys to ["srl", "3"].
      // A blanket minimum-skeleton-length test would trip on that single-digit
      // "3" and silently disable this rung for every numbered label — while the
      // digit guard is already what keeps "3" and "4" apart.
      const aisles = [
        { label: 'Cereal 3', mapId: 'map-6', mapName: 'Store Route' },
        { label: 'Kitchen', mapId: 'map-6', mapName: 'Store Route' },
      ];
      const result = matchTargetAgainstVocabulary('serials 3 shelf', aisles);
      expect(result.status).toBe('matched');
      expect(result.label).toBe('Cereal 3');

      // The digit still has to agree.
      expect(matchTargetAgainstVocabulary('serials 4 shelf', aisles).status).toBe('no_match');
    });

    it('refuses to guess between two labels that tie on sound', () => {
      const rooms = [
        { label: 'North Lounge', mapId: 'map-7', mapName: 'Office Route' },
        { label: 'South Lounge', mapId: 'map-7', mapName: 'Office Route' },
      ];
      expect(matchTargetAgainstVocabulary('lounge', rooms).status).toBe('no_match');
    });
  });

  it('reports available targets for spoken feedback on a miss', () => {
    const result = matchTargetAgainstVocabulary('quinoa', vocabulary);
    expect(result.status).toBe('no_match');
    expect(result.availableTargets).toEqual(['Cereal', 'Onions', 'Milk', 'Aisle 3']);
  });

  it('reports no_vocabulary when no maps are saved', () => {
    const result = matchTargetAgainstVocabulary('cereal', []);
    expect(result.status).toBe('no_vocabulary');
  });
});

describe('TargetGroundingService — French (fr-CA)', () => {
  const vocabulaire = [
    { label: 'Oignons', mapId: 'map-1', mapName: 'Épicerie' },
    { label: 'Céréales', mapId: 'map-1', mapName: 'Épicerie' },
    { label: 'Crème', mapId: 'map-2', mapName: 'Produits laitiers' },
    { label: 'Allée 3', mapId: 'map-2', mapName: 'Produits laitiers' },
  ];

  beforeEach(() => setAppLanguage('fr'));
  afterAll(() => setAppLanguage('en'));

  it('folds accents so an accented label matches itself', () => {
    // Without folding the [^a-z0-9] strip turns "crème" into "cr me".
    expect(normalizeSpokenLabel('Crème')).toBe('creme');
    expect(normalizeSpokenLabel('Céréales')).toBe('cereales');
  });

  it('expands ligatures rather than dropping them', () => {
    // Swift counts "œ" as alphanumeric and the JS regex does not; expanding
    // keeps the two phonetic implementations in agreement.
    expect(foldDiacritics('œuf')).toBe('oeuf');
    expect(foldDiacritics('bœuf')).toBe('boeuf');
  });

  it('strips French articles and partitives', () => {
    expect(normalizeSpokenLabel('les oignons')).toBe('oignons');
    expect(normalizeSpokenLabel('des oignons')).toBe('oignons');
    expect(normalizeSpokenLabel('de la crème')).toBe('creme');
    expect(normalizeSpokenLabel("l'oignon")).toBe('oignon');
  });

  it('collapses singular and plural onto one phonetic key', () => {
    // French stacks a plural marker on an already-silent consonant
    // ("haricots" = haricot + s), so these only collide if the silent-letter
    // strip runs in the right order.
    for (const [singular, plural] of [
      ['oignon', 'oignons'],
      ['haricot', 'haricots'],
      ['biscuit', 'biscuits'],
      ['eau', 'eaux'],
      ['chou', 'choux'],
      ['gâteau', 'gâteaux'],
      ['légume', 'légumes'],
    ]) {
      expect([singular, phoneticKey(singular)]).toEqual([
        singular,
        phoneticKey(plural),
      ]);
    }
  });

  it('keeps genuinely different words apart', () => {
    expect(phoneticKey('sel')).not.toBe(phoneticKey('miel'));
    expect(phoneticKey('beurre')).not.toBe(phoneticKey('poisson'));
    expect(phoneticKey('farine')).not.toBe(phoneticKey('huile'));
  });

  it('grounds a partitive request against the saved label', () => {
    const result = matchTargetAgainstVocabulary(
      normalizeSpokenLabel('des oignons'),
      vocabulaire,
    );
    expect(result.status).toBe('matched');
    expect(result.label).toBe('Oignons');
  });

  it('grounds an unaccented transcript against an accented label', () => {
    // Recognisers drop accents inconsistently over a Bluetooth mic.
    const result = matchTargetAgainstVocabulary(
      normalizeSpokenLabel('cereales'),
      vocabulaire,
    );
    expect(result.status).toBe('matched');
    expect(result.label).toBe('Céréales');
  });

  it('keeps numbered aisles distinct in French too', () => {
    const result = matchTargetAgainstVocabulary(
      normalizeSpokenLabel('allée 4'),
      vocabulaire,
    );
    expect(result.status).toBe('no_match');
  });
});
