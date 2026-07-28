import { describe, expect, it } from 'vitest';
import { BUNDLED_COURSES, LEARNING_OUTCOMES_BY_COURSE_ID } from './courseCatalog';
import { GOALS_BY_COURSE_ID } from './courseGoals';

/**
 * Course data is hand-transcribed from the macOS Swift source, so the failure
 * mode is drift, not a crash: a course listed with no goals renders a card that
 * does nothing when tapped, and a goal set with no course is dead weight nobody
 * notices. Both shipped at once when the Mac cut its catalog to one flagship and
 * Windows kept listing four.
 */
describe('bundled course catalog', () => {
  it('ships at least one course', () => {
    expect(BUNDLED_COURSES.length).toBeGreaterThan(0);
  });

  it('has no duplicate course ids', () => {
    const courseIds = BUNDLED_COURSES.map((course) => course.id);
    expect(new Set(courseIds).size).toBe(courseIds.length);
  });

  it('gives every course the fields the Learn card renders', () => {
    for (const course of BUNDLED_COURSES) {
      expect(course.title.trim(), `${course.id} title`).not.toBe('');
      expect(course.subtitle.trim(), `${course.id} subtitle`).not.toBe('');
      expect(course.description.trim(), `${course.id} description`).not.toBe('');
      expect(course.glyph.trim(), `${course.id} glyph`).not.toBe('');
      expect(course.estimatedMinutes, `${course.id} duration`).toBeGreaterThan(0);
    }
  });

  it('only points startUrl at a real absolute URL when it sets one', () => {
    for (const course of BUNDLED_COURSES) {
      if (course.startUrl !== null) {
        expect(() => new URL(course.startUrl!), `${course.id} startUrl`).not.toThrow();
        expect(course.startUrl.startsWith('https://'), `${course.id} startUrl scheme`).toBe(true);
      }
    }
  });
});

describe('catalog and goals agree', () => {
  it('gives every listed course a non-empty goal set — a course with no goals cannot start', () => {
    for (const course of BUNDLED_COURSES) {
      const goals = GOALS_BY_COURSE_ID[course.id];
      expect(goals, `no goals for course "${course.id}"`).toBeDefined();
      expect(goals.length, `empty goal list for course "${course.id}"`).toBeGreaterThan(0);
    }
  });

  it('leaves no orphan goal sets behind after a catalog cut', () => {
    const catalogIds = new Set(BUNDLED_COURSES.map((course) => course.id));
    for (const courseIdWithGoals of Object.keys(GOALS_BY_COURSE_ID)) {
      expect(catalogIds.has(courseIdWithGoals), `goals for unlisted course "${courseIdWithGoals}"`).toBe(true);
    }
  });

  it('lists learning outcomes for every course', () => {
    for (const course of BUNDLED_COURSES) {
      const outcomes = LEARNING_OUTCOMES_BY_COURSE_ID[course.id];
      expect(outcomes, `no outcomes for "${course.id}"`).toBeDefined();
      expect(outcomes.length).toBeGreaterThan(0);
    }
  });
});

describe('goal shape', () => {
  it('keeps goal ids unique inside a course so progress cannot resume onto the wrong step', () => {
    for (const [courseId, goals] of Object.entries(GOALS_BY_COURSE_ID)) {
      const goalIds = goals.map((goal) => goal.id);
      expect(new Set(goalIds).size, `duplicate goal id in "${courseId}"`).toBe(goalIds.length);
    }
  });

  it('gives every goal the text the coach and HUD actually read', () => {
    for (const [courseId, goals] of Object.entries(GOALS_BY_COURSE_ID)) {
      for (const goal of goals) {
        const where = `${courseId}/${goal.id}`;
        expect(goal.title.trim(), `${where} title`).not.toBe('');
        expect(goal.goal.trim(), `${where} goal`).not.toBe('');
        expect(goal.outcome.trim(), `${where} outcome`).not.toBe('');
        // coachAsk is sent verbatim as the opening turn — an empty one means the
        // course starts by asking the model nothing.
        expect(goal.coachAsk.trim().length, `${where} coachAsk`).toBeGreaterThan(20);
        expect(Array.isArray(goal.tips), `${where} tips`).toBe(true);
      }
    }
  });

  it('writes doneWhen as real vision criteria or null, never an empty string', () => {
    for (const [courseId, goals] of Object.entries(GOALS_BY_COURSE_ID)) {
      for (const goal of goals) {
        if (goal.doneWhen !== null) {
          expect(goal.doneWhen.trim().length, `${courseId}/${goal.id} doneWhen`).toBeGreaterThan(10);
        }
      }
    }
  });

  it('writes teachBackPrompt as a real question or null, never an empty string', () => {
    for (const [courseId, goals] of Object.entries(GOALS_BY_COURSE_ID)) {
      for (const goal of goals) {
        if (goal.teachBackPrompt !== null) {
          expect(goal.teachBackPrompt.trim(), `${courseId}/${goal.id} teachBackPrompt`).not.toBe('');
        }
      }
    }
  });

  it('finishes each course on a goal the learner can actually complete', () => {
    // A course whose last goal advances only on the learner's word ends with no
    // verified artifact — the finish line stops meaning anything.
    for (const [courseId, goals] of Object.entries(GOALS_BY_COURSE_ID)) {
      const finalGoal = goals[goals.length - 1];
      expect(finalGoal.doneWhen, `${courseId} ends on an unverifiable goal`).not.toBeNull();
    }
  });
});
