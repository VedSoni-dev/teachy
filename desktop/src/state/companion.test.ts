import { describe, expect, it } from 'vitest';
import {
  buildCompanionSystemPrompt,
  parseModelReply,
  resolvePointTagToScreenPixel,
} from './companion';
import type { CapturedScreen } from '../types/global';

/**
 * The [POINT:...] contract is the one piece of model output the app parses and
 * then acts on physically — it moves a cursor on the learner's real screen. A
 * parse slip either strips nothing (the tag gets spoken aloud, which sounds
 * broken) or points somewhere wrong (worse than not pointing).
 */
describe('parseModelReply', () => {
  it('strips the tag from what gets spoken', () => {
    const { spokenText, pointTag } = parseModelReply('Click the green button [POINT:M7:the button] over there.');
    expect(spokenText).toBe('Click the green button over there.');
    expect(pointTag?.gridCell).toBe('M7');
  });

  it('prefers a UI Automation element over a grid cell', () => {
    const { pointTag } = parseModelReply('Here [POINT:ax:7:Sign in] and [POINT:M7:somewhere]');
    expect(pointTag?.automationElementId).toBe(7);
    expect(pointTag?.gridCell).toBeNull();
  });

  it('uppercases a lowercase grid cell so resolution does not silently fail', () => {
    expect(parseModelReply('[POINT:m7:x]').pointTag?.gridCell).toBe('M7');
  });

  it('reads raw pixel coordinates', () => {
    const { pointTag } = parseModelReply('Look [POINT:842,310:the tab]');
    expect(pointTag?.pixelCoordinate).toEqual({ x: 842, y: 310 });
  });

  it('treats [POINT:none] as no target but still removes it from speech', () => {
    const { spokenText, pointTag } = parseModelReply('Nothing to show you here. [POINT:none]');
    expect(pointTag).toBeNull();
    expect(spokenText).toBe('Nothing to show you here.');
  });

  it('leaves no tag residue when the model emits several', () => {
    const { spokenText } = parseModelReply('One [POINT:M7:a] two [POINT:ax:3:b] three');
    expect(spokenText).not.toContain('[POINT');
    expect(spokenText).toBe('One two three');
  });

  it('returns plain text untouched when there is no tag', () => {
    const { spokenText, pointTag } = parseModelReply('Just talking.');
    expect(spokenText).toBe('Just talking.');
    expect(pointTag).toBeNull();
  });
});

const screenFixture: CapturedScreen = {
  width: 2400,
  height: 1600,
  jpegBase64: '',
  elements: [{ id: 7, line: '7: Sign in button', centerX: 100, centerY: 200 }],
} as CapturedScreen;

describe('resolvePointTagToScreenPixel', () => {
  it('uses the element centre when the tag names a UI Automation element', () => {
    const target = resolvePointTagToScreenPixel(
      { automationElementId: 7, gridCell: null, pixelCoordinate: null, label: null },
      screenFixture,
    );
    expect(target).toEqual({ x: 100, y: 200 });
  });

  it('falls back to the grid when the element id is not on screen any more', () => {
    const target = resolvePointTagToScreenPixel(
      { automationElementId: 99, gridCell: 'A1', pixelCoordinate: null, label: null },
      screenFixture,
    );
    expect(target).not.toBeNull();
  });

  it('centres A1 in the first cell of a 24x16 grid', () => {
    const target = resolvePointTagToScreenPixel(
      { automationElementId: null, gridCell: 'A1', pixelCoordinate: null, label: null },
      screenFixture,
    );
    expect(target).toEqual({ x: 50, y: 50 });
  });

  it('centres X16 in the last cell, still inside the screen', () => {
    const target = resolvePointTagToScreenPixel(
      { automationElementId: null, gridCell: 'X16', pixelCoordinate: null, label: null },
      screenFixture,
    );
    expect(target).toEqual({ x: 2350, y: 1550 });
    expect(target!.x).toBeLessThan(screenFixture.width);
    expect(target!.y).toBeLessThan(screenFixture.height);
  });

  it('refuses an out-of-range cell rather than pointing off screen', () => {
    const target = resolvePointTagToScreenPixel(
      { automationElementId: null, gridCell: 'Z9', pixelCoordinate: null, label: null },
      screenFixture,
    );
    expect(target).toBeNull();
  });
});

describe('buildCompanionSystemPrompt', () => {
  it('states the real screenshot dimensions so pixel tags are in the right space', () => {
    const prompt = buildCompanionSystemPrompt(1920, 1080, null, null);
    expect(prompt).toContain('1920x1080');
  });

  it('only offers the ax: tag form when elements were actually inspected', () => {
    expect(buildCompanionSystemPrompt(800, 600, null, null)).not.toContain('[POINT:ax:');
    expect(
      buildCompanionSystemPrompt(800, 600, [{ id: 1, line: '1: Save button' }] as never, null),
    ).toContain('[POINT:ax:');
  });

  it('tells the model what the learner circled', () => {
    const prompt = buildCompanionSystemPrompt(800, 600, null, 'M7, M8, N7');
    expect(prompt).toContain('M7, M8, N7');
  });
});
