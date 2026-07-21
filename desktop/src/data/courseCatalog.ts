/**
 * Bundled course catalog — titles, subtitles, descriptions and durations copied
 * verbatim from the macOS ClickyCourseCatalog.bundledCourses.
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
    title: 'Build & Deploy a Website',
    subtitle: 'From zero to a live site the world can visit',
    description:
      'Build a real personal website from scratch with HTML & CSS, then deploy it to GitHub Pages so anyone on the internet can see it.',
    estimatedMinutes: 45,
    glyph: '🖥',
    startUrl: 'https://github.com/new',
  },
  {
    id: 'code-with-ai',
    title: 'Code with AI',
    subtitle: 'Direct an AI coding agent like a pro',
    description:
      "Non-developers bounce off coding agents because they don't know how to instruct them. This course teaches you the instruct → verify → iterate loop so you can actually ship things.",
    estimatedMinutes: 40,
    glyph: '{ }',
    startUrl: null,
  },
  {
    id: 'build-a-phone-agent',
    title: 'Build a Phone Agent',
    subtitle: 'A voice AI that answers calls for you',
    description:
      'Build a working voice AI assistant that can handle phone calls — without writing a single line of code. You will have something you can actually talk to in the browser before this course ends.',
    estimatedMinutes: 35,
    glyph: '☎',
    startUrl: 'https://dashboard.vapi.ai',
  },
  {
    id: 'ai-fluency-essentials',
    title: 'AI Fluency Essentials',
    subtitle: 'Prompt, pick tools, and trust — the core skills',
    description:
      'The mental models behind getting reliable results from AI — not tricks, but durable habits that apply to every tool you will ever use.',
    estimatedMinutes: 25,
    glyph: '✦',
    startUrl: null,
  },
];
