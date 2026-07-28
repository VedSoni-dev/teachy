/**
 * Bundled course catalog — titles, subtitles, descriptions and durations copied
 * verbatim from the macOS ClickyCourseCatalog.bundledCourses.
 *
 * The Mac now ships exactly one flagship course ("Make a Website"); Code with AI,
 * Build a Phone Agent and AI Fluency Essentials were deleted upstream, so they are
 * gone here too rather than lingering as Windows-only ghosts.
 */
export interface CourseCatalogEntry {
  id: string;
  title: string;
  subtitle: string;
  description: string;
  estimatedMinutes: number;
  /** Simple glyph stand-in for the Mac's SF Symbol. */
  glyph: string;
  startUrl: string | null;
}

export const BUNDLED_COURSES: CourseCatalogEntry[] = [
  {
    id: 'build-a-website',
    title: 'Make a Website',
    subtitle: 'Plan in ChatGPT. Build. Live on Vercel.',
    description:
      'Teachy runs the interview you skip, writes a great ChatGPT prompt, helps you mock and build, then ships a live Vercel URL you can text someone.',
    estimatedMinutes: 45,
    glyph: '🖥',
    // Mac has startURL: nil — the coach opens chatgpt.com itself once intake is
    // done, so opening a tab at course start would race that flow.
    startUrl: null,
  },
];

/** What the learner walks away able to do — mirrors `learningOutcomes` on Mac. */
export const LEARNING_OUTCOMES_BY_COURSE_ID: Record<string, string[]> = {
  'build-a-website': [
    'Answer sharp intake questions so an AI gets real context — not a vague one-liner',
    'Use a Teachy-written prompt in ChatGPT to produce a concrete site plan',
    'Generate a landing mock (and more pages only if image quota allows)',
    'Build the site in Replit or a coding agent matched to what they already pay for',
    'Deploy to Vercel and share a live URL',
  ],
};
