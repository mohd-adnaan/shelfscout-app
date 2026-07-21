import { stripWakePhrase } from '../src/hooks/wakePhrases';
import { setAppLanguage } from '../src/i18n';

describe('wake phrase matching — English', () => {
  beforeEach(() => setAppLanguage('en'));

  it('extracts the query after the canonical wake phrase', () => {
    expect(stripWakePhrase('hey shelfscout where is the milk')).toBe(
      'where is the milk',
    );
  });

  it('matches the mis-heard variants seen in device logs', () => {
    expect(stripWakePhrase('hey scout take me to aisle 3')).toBe(
      'take me to aisle 3',
    );
    expect(stripWakePhrase('shell scout find the cereal')).toBe(
      'find the cereal',
    );
  });

  it('matches capitalised variants', () => {
    // These entries are written with capitals in the phrase list. Matching
    // runs on folded, lower-cased text, so the list is folded too — without
    // that, every capitalised entry is silently dead.
    expect(stripWakePhrase('Hey Scout where am I')).toBe('where am I');
    expect(stripWakePhrase('Asian Scout find milk')).toBe('find milk');
  });

  it('uses the LAST wake phrase when the transcript accumulates', () => {
    // iOS keeps appending to one FINAL transcript; the newest query wins.
    expect(
      stripWakePhrase('hey scout find milk hey scout find cereal'),
    ).toBe('find cereal');
  });

  it('preserves query casing and leading-whitespace offsets', () => {
    // stripWakePhrase slices the ORIGINAL string by index, so any
    // length-changing normalisation would corrupt the query here.
    expect(stripWakePhrase('   hey scout Where Is The Milk')).toBe(
      'Where Is The Milk',
    );
  });

  it('returns null when no wake phrase is present', () => {
    expect(stripWakePhrase('where is the milk')).toBeNull();
    expect(stripWakePhrase('')).toBeNull();
  });

  it('terminates when a phrase sits at index 0 and fails the boundary check', () => {
    // Regression: lastIndexOf clamps a negative fromIndex to 0 instead of
    // returning -1, so a phrase matching at index 0 whose boundary check
    // fails was re-found at 0 forever. "hey she" is in the phrase list and
    // matches at index 0 of "hey shelfscout ...", followed by "l" — the
    // canonical wake phrase used to hang the JS thread here.
    expect(stripWakePhrase('hey shelfscout find milk')).toBe('find milk');
    expect(stripWakePhrase('hey shelf scout find milk')).toBe('find milk');
    // Phrase at index 0 with no valid match anywhere must still terminate.
    expect(stripWakePhrase('scoutx')).toBeNull();
  });
});

describe('wake phrase matching — French', () => {
  beforeEach(() => setAppLanguage('fr'));
  afterAll(() => setAppLanguage('en'));

  it('matches French renderings of the wake phrase', () => {
    expect(stripWakePhrase('hé écoute où sont les oignons')).toBe(
      'où sont les oignons',
    );
    expect(stripWakePhrase('chef scout amène-moi aux céréales')).toBe(
      'amène-moi aux céréales',
    );
  });

  it('matches whether or not the recogniser emits accents', () => {
    expect(stripWakePhrase('he ecoute trouve le lait')).toBe('trouve le lait');
    expect(stripWakePhrase('hé écoute trouve le lait')).toBe('trouve le lait');
  });

  it('keeps accents in the extracted query', () => {
    // Folding is for MATCHING only — the query is sliced from the original
    // text, so the intent router still sees properly accented French.
    expect(stripWakePhrase('hé scout où est la crème')).toBe('où est la crème');
  });

  it('still accepts the bare "scout" fallback', () => {
    // The leading interjection is routinely lost to Bluetooth compression, so
    // bare "scout" is deliberately in the French list too.
    expect(stripWakePhrase('scout trouve le lait')).toBe('trouve le lait');
  });

  it('does not fire on French-recogniser artefacts absent from the list', () => {
    // "shelves code" / "haitian" are English-list-only entries; they must not
    // consume a French utterance.
    expect(stripWakePhrase('shelves code trouve le lait')).toBeNull();
    expect(stripWakePhrase('haitian trouve le lait')).toBeNull();
  });

  it('returns null when no wake phrase is present', () => {
    expect(stripWakePhrase('où est le lait')).toBeNull();
  });
});
