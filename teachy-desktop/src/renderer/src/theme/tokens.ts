/**
 * tokens.ts
 * Typed accessors for the design tokens defined in `theme.css`.
 *
 * Every value references a CSS custom property (`var(--...)`) so the single
 * source of truth for the actual color/size remains `theme.css` — including its
 * dark/light theming. Import these in React components (inline styles,
 * styled-components, etc.) instead of hardcoding `var(--color-...)` strings.
 *
 * Ported 1:1 from the macOS SwiftUI design system (DesignSystem.swift → `DS`).
 * Swift camelCase key names are preserved here; CSS vars use kebab-case.
 */

export const colors = {
  // ── Backgrounds ──────────────────────────────────────────────
  background: 'var(--color-background)',
  surface1: 'var(--color-surface-1)',
  surface2: 'var(--color-surface-2)',
  surface3: 'var(--color-surface-3)',
  surface4: 'var(--color-surface-4)',

  // ── Borders ──────────────────────────────────────────────────
  borderSubtle: 'var(--color-border-subtle)',
  borderStrong: 'var(--color-border-strong)',

  // ── Text ─────────────────────────────────────────────────────
  textPrimary: 'var(--color-text-primary)',
  textSecondary: 'var(--color-text-secondary)',
  textTertiary: 'var(--color-text-tertiary)',
  textOnAccent: 'var(--color-text-on-accent)',

  // ── Blue accent scale (raw palette) ──────────────────────────
  blue50: 'var(--color-blue-50)',
  blue100: 'var(--color-blue-100)',
  blue200: 'var(--color-blue-200)',
  blue300: 'var(--color-blue-300)',
  blue400: 'var(--color-blue-400)',
  blue500: 'var(--color-blue-500)',
  blue600: 'var(--color-blue-600)',
  blue700: 'var(--color-blue-700)',
  blue800: 'var(--color-blue-800)',
  blue900: 'var(--color-blue-900)',
  blue950: 'var(--color-blue-950)',

  // ── Accent (derived) ─────────────────────────────────────────
  accent: 'var(--color-accent)',
  accentHover: 'var(--color-accent-hover)',
  accentText: 'var(--color-accent-text)',
  accentSubtle: 'var(--color-accent-subtle)',

  // ── Tab / domain accents ─────────────────────────────────────
  learnAccent: 'var(--color-learn-accent)',
  learnAccentSoft: 'var(--color-learn-accent-soft)',
  portfolioAccent: 'var(--color-portfolio-accent)',
  portfolioAccentSoft: 'var(--color-portfolio-accent-soft)',
  skillsAccent: 'var(--color-skills-accent)',
  skillsAccentSoft: 'var(--color-skills-accent-soft)',

  // ── Semantic ─────────────────────────────────────────────────
  destructive: 'var(--color-destructive)',
  destructiveHover: 'var(--color-destructive-hover)',
  destructiveText: 'var(--color-destructive-text)',
  success: 'var(--color-success)',
  warning: 'var(--color-warning)',
  warningText: 'var(--color-warning-text)',
  info: 'var(--color-info)',
  codeText: 'var(--color-code-text)',

  // ── Overlay cursor ───────────────────────────────────────────
  overlayCursorBlue: 'var(--color-overlay-cursor-blue)',

  // ── Floating button gradient ─────────────────────────────────
  floatingGradientPurple: 'var(--color-floating-gradient-purple)',
  floatingGradientPink: 'var(--color-floating-gradient-pink)',
  floatingGradientOrange: 'var(--color-floating-gradient-orange)',

  // ── Help chat ────────────────────────────────────────────────
  helpChatUserBubble: 'var(--color-help-chat-user-bubble)',
  helpChatUserBubbleHover: 'var(--color-help-chat-user-bubble-hover)',
  helpChatBackdrop: 'var(--color-help-chat-backdrop)',

  // ── Disabled state ───────────────────────────────────────────
  disabledBackground: 'var(--color-disabled-background)',
  disabledText: 'var(--color-disabled-text)',

  // ── Buddy composer waveform ──────────────────────────────────
  waveformLeading: 'var(--color-waveform-leading)',
  waveformTrailing: 'var(--color-waveform-trailing)',
  waveformGlow: 'var(--color-waveform-glow)',
} as const

export const radius = {
  small: 'var(--radius-small)',
  medium: 'var(--radius-medium)',
  large: 'var(--radius-large)',
  extraLarge: 'var(--radius-extra-large)',
  glassCard: 'var(--radius-glass-card)',
  pill: 'var(--radius-pill)',
} as const

export const space = {
  xs: 'var(--space-xs)',
  sm: 'var(--space-sm)',
  md: 'var(--space-md)',
  lg: 'var(--space-lg)',
  xl: 'var(--space-xl)',
  xxl: 'var(--space-xxl)',
  xxxl: 'var(--space-xxxl)',
} as const

export const font = {
  caption: 'var(--font-size-caption)',
  sm: 'var(--font-size-sm)',
  base: 'var(--font-size-base)',
} as const

export const duration = {
  fast: 'var(--duration-fast)',
  normal: 'var(--duration-normal)',
  slow: 'var(--duration-slow)',
} as const

export const stateLayer = {
  hover: 'var(--state-layer-hover)',
  focus: 'var(--state-layer-focus)',
  pressed: 'var(--state-layer-pressed)',
  dragged: 'var(--state-layer-dragged)',
} as const

export type ColorToken = keyof typeof colors
export type RadiusToken = keyof typeof radius
export type SpaceToken = keyof typeof space
export type FontToken = keyof typeof font
