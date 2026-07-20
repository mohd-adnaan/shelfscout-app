import {
  levenshteinDistance,
  matchTargetAgainstVocabulary,
  normalizeSpokenLabel,
  phoneticKey,
} from '../src/services/TargetGroundingService';

const vocabulary = [
  { label: 'Cereal', mapId: 'map-1', mapName: 'Store Route' },
  { label: 'Onions', mapId: 'map-1', mapName: 'Store Route' },
  { label: 'Milk', mapId: 'map-2', mapName: 'Dairy Route' },
  { label: 'Aisle 3', mapId: 'map-2', mapName: 'Dairy Route' },
];

describe('TargetGroundingService', () => {
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

  it('never lets short labels cross to different words', () => {
    const result = matchTargetAgainstVocabulary('silk', vocabulary);
    expect(result.status).toBe('no_match');
  });

  it('keeps numbered aisles distinct', () => {
    const result = matchTargetAgainstVocabulary('aisle 4', vocabulary);
    expect(result.status).toBe('no_match');
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
