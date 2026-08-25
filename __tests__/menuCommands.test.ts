/**
 * Menu row + spoken fragment → one unambiguous command.
 *
 * The point of the menu is that pressing a row settles the intent, so the
 * spoken part only has to carry a target. But a user who just pressed a button
 * labelled "Find an object" will still say "find the cereal" — that is how
 * people talk to assistants, and no amount of labelling changes it.
 *
 * These tests pin both halves: the request verb is stripped so target
 * extraction downstream sees a noun phrase, and the stripping never eats the
 * target itself.
 *
 * @format
 */

import {
  canonicalizeMenuCommand,
  extractTargetPhrase,
} from '../src/a11y/menuCommands';
import { en } from '../src/i18n/strings/en';
import { fr } from '../src/i18n/strings/fr';

describe('extractTargetPhrase (English)', () => {
  it.each([
    ['cereal', 'cereal'],
    ['the cereal', 'the cereal'],
    ['find the cereal', 'the cereal'],
    ['Find the cereal box', 'the cereal box'],
    ['can you find the milk', 'the milk'],
    ['please help me find the milk', 'the milk'],
    ['grab the water bottle', 'the water bottle'],
    ['reach the mug', 'the mug'],
    ["where's the yogurt", 'the yogurt'],
    ['I want to find the bread', 'the bread'],
    ['find the cereal please', 'the cereal'],
    ['the cereal, thanks', 'the cereal'],
  ])('%j → %j', (input, expected) => {
    expect(extractTargetPhrase(input, 'en')).toBe(expected);
  });

  it('leaves a target that merely starts like a request verb intact', () => {
    // "search light" must survive; only "search for " is a request phrase.
    expect(extractTargetPhrase('search light', 'en')).toBe('search light');
    expect(extractTargetPhrase('getting cream', 'en')).toBe('getting cream');
    expect(extractTargetPhrase('reacher grabber', 'en')).toBe('reacher grabber');
  });

  it('falls back to the original when stripping would leave nothing', () => {
    // An empty target is a guaranteed failure; a vague one at least reaches
    // the classifier's own disambiguation.
    expect(extractTargetPhrase('find', 'en')).toBe('find');
  });

  it('returns empty for empty input', () => {
    expect(extractTargetPhrase('   ', 'en')).toBe('');
  });
});

describe('extractTargetPhrase (French)', () => {
  it.each([
    ['les céréales', 'les céréales'],
    ['trouve les céréales', 'les céréales'],
    ['peux-tu trouver le lait', 'le lait'],
    ['où est le yogourt', 'le yogourt'],
    ['attrape la bouteille d’eau', 'la bouteille d’eau'],
    ['je veux trouver le pain', 'le pain'],
    ['trouve le lait s’il te plaît', 'le lait'],
  ])('%j → %j', (input, expected) => {
    expect(extractTargetPhrase(input, 'fr')).toBe(expected);
  });
});

describe('canonicalizeMenuCommand', () => {
  it('wraps a bare noun into a command that can only route to reaching', () => {
    // "cereal" alone has no verb, and the intent prompt sends a verbless
    // utterance to `chat` — which is why pressing "Find an object" and saying
    // "cereal" used to return a description instead of guidance.
    expect(canonicalizeMenuCommand('cereal', en.commands.findObject, 'en')).toBe(
      'Guide my hand to cereal.',
    );
  });

  it('does not double the request verb when the user speaks a full sentence', () => {
    expect(
      canonicalizeMenuCommand('find the cereal', en.commands.findObject, 'en'),
    ).toBe('Guide my hand to the cereal.');
  });

  it('does not double the article', () => {
    const result = canonicalizeMenuCommand('the milk', en.commands.findObject, 'en');
    expect(result).toBe('Guide my hand to the milk.');
    expect(result).not.toContain('the the');
  });

  it('builds the French command from the French catalog', () => {
    expect(
      canonicalizeMenuCommand('trouve le lait', fr.commands.findObject, 'fr'),
    ).toBe('Guide ma main vers le lait.');
  });

  it('passes an unrecognisable fragment through rather than dropping it', () => {
    expect(canonicalizeMenuCommand('   ', en.commands.findObject, 'en')).toBe('');
  });
});

describe('the no-speech command is a constant', () => {
  it('sends identical text every time, in both languages', () => {
    // The entire reliability argument for "Describe my surroundings" is that
    // the request cannot be misheard, so the classifier sees the same sentence
    // on every press and routes it the same way. If this ever becomes dynamic,
    // that guarantee is gone.
    expect(typeof en.commands.describeScene).toBe('string');
    expect(typeof fr.commands.describeScene).toBe('string');
  });

  it('is phrased so the intent router reads it as a scene request', () => {
    // Both catalogs must ask about the surroundings rather than about a
    // specific object: the router sends a named-object question to `chat`,
    // which answers about that object instead of describing the scene.
    expect(en.commands.describeScene.toLowerCase()).toContain('in front of me');
    expect(fr.commands.describeScene.toLowerCase()).toContain('devant moi');
  });
});
