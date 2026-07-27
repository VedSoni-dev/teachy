// Progress tab — the per-learner tracker, ported from the SwiftUI
// NotchProgressTabView. Foundation build uses a sample learner; Week 2 swaps
// this for the ported TeachyEngine state (streak, portfolio items, learned
// skills, active-course progress, recent teach-backs).

interface Moment {
  icon: 'ship' | 'explain' | 'verify'
  title: string
  subtitle: string
  time: string
}

interface Learner {
  name: string
  tagline: string
  streakDays: number
  thingsBuilt: number
  skillsLearned: number
  course: { name: string; percent: number } | null
  recent: Moment[]
  nextUp: { title: string; subtitle: string } | null
}

// The nail-salon → website learner from the founding thesis. Real-shaped sample
// data so the surface is legible before the engine is wired.
const SAMPLE_LEARNER: Learner = {
  name: 'Maria',
  tagline: 'learning to build',
  streakDays: 6,
  thingsBuilt: 4,
  skillsLearned: 7,
  course: { name: 'Ship Your First Website', percent: 80 },
  recent: [
    { icon: 'ship', title: 'Shipped', subtitle: 'maria-nails.vercel.app', time: '2d ago' },
    { icon: 'explain', title: 'Explained', subtitle: 'how deploying works', time: '2d ago' },
    { icon: 'verify', title: 'Recalled', subtitle: 'writing a good prompt', time: '5d ago' }
  ],
  nextUp: { title: 'Add a booking page', subtitle: 'the natural next step for your site' }
}

export function ProgressTab(): JSX.Element {
  const learner = SAMPLE_LEARNER

  return (
    <>
      <div className="section-head">
        <h1>Your Progress</h1>
        <p>Everything you&apos;ve built and learned, at a glance.</p>
      </div>

      {/* Stats hero */}
      <div className="glass-card glass-card--prominent" style={hero}>
        <div>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 5 }}>
            <span style={{ fontSize: 15 }}>🔥</span>
            <span style={{ ...bigNum, color: 'var(--color-warning)' }}>{learner.streakDays}</span>
          </div>
          <div style={statLabel}>day streak</div>
        </div>
        <div style={vDivider} />
        <div>
          <div style={bigNum}>{learner.thingsBuilt}</div>
          <div style={statLabel}>things built</div>
        </div>
        <div>
          <div style={{ ...bigNum, color: 'var(--color-success)' }}>{learner.skillsLearned}</div>
          <div style={statLabel}>skills learned</div>
        </div>
      </div>

      {/* Current course */}
      {learner.course && (
        <div className="glass-card" style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
            <div>
              <div style={eyebrow}>CURRENT COURSE</div>
              <div style={{ fontSize: 13, fontWeight: 600, marginTop: 3 }}>{learner.course.name}</div>
            </div>
            <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--color-success)' }}>
              {learner.course.percent}%
            </div>
          </div>
          <div style={track}>
            <div style={{ ...trackFill, width: `${learner.course.percent}%` }} />
          </div>
        </div>
      )}

      {/* Recent moments */}
      {learner.recent.length > 0 && (
        <div className="glass-card" style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <div style={{ fontSize: 12, fontWeight: 600 }}>Recently</div>
          {learner.recent.map((moment, index) => (
            <div key={index} style={momentRow}>
              <div style={{ ...momentIcon, background: momentTint(moment.icon, 0.14), color: momentTint(moment.icon, 1) }}>
                {momentGlyph(moment.icon)}
              </div>
              <div style={{ minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                <span style={{ fontSize: 12, fontWeight: 600 }}>{moment.title}</span>
                <span style={{ fontSize: 12, color: 'var(--color-text-tertiary)' }}> {moment.subtitle}</span>
              </div>
              <div style={{ fontSize: 9, color: 'var(--color-text-tertiary)', whiteSpace: 'nowrap' }}>
                {moment.time}
              </div>
            </div>
          ))}
        </div>
      )}

      {/* Next up */}
      {learner.nextUp && (
        <button style={nudge}>
          <span style={nudgeDot} />
          <span style={{ flex: 1, textAlign: 'left' }}>
            <div style={{ fontSize: 12, fontWeight: 600 }}>Next up · {learner.nextUp.title}</div>
            <div style={{ fontSize: 11, color: 'var(--color-text-tertiary)', marginTop: 1 }}>
              {learner.nextUp.subtitle}
            </div>
          </span>
          <span style={{ color: 'var(--color-success)', fontSize: 15 }}>→</span>
        </button>
      )}
    </>
  )
}

// ── local style objects ──────────────────────────────────────

const hero: React.CSSProperties = { display: 'flex', alignItems: 'center', gap: 14 }
const bigNum: React.CSSProperties = {
  fontSize: 24,
  fontWeight: 800,
  letterSpacing: '-0.02em',
  fontVariantNumeric: 'tabular-nums',
  color: 'var(--color-text-primary)'
}
const statLabel: React.CSSProperties = { fontSize: 10, color: 'var(--color-text-tertiary)', marginTop: 1 }
const vDivider: React.CSSProperties = { width: 1, height: 34, background: 'var(--color-border-subtle)' }
const eyebrow: React.CSSProperties = {
  fontSize: 10,
  fontWeight: 600,
  letterSpacing: '0.06em',
  color: 'var(--color-text-tertiary)'
}
const track: React.CSSProperties = {
  height: 7,
  borderRadius: 99,
  background: 'rgba(255,255,255,0.07)',
  overflow: 'hidden'
}
const trackFill: React.CSSProperties = {
  height: '100%',
  borderRadius: 99,
  background: 'var(--color-success)',
  transition: 'width 0.5s cubic-bezier(.22,1,.36,1)'
}
const momentRow: React.CSSProperties = {
  display: 'grid',
  gridTemplateColumns: '26px 1fr auto',
  alignItems: 'center',
  gap: 10,
  padding: 9,
  background: 'rgba(255,255,255,0.04)',
  borderRadius: 12
}
const momentIcon: React.CSSProperties = {
  width: 26,
  height: 26,
  borderRadius: 8,
  display: 'grid',
  placeItems: 'center',
  fontSize: 12
}
const nudge: React.CSSProperties = {
  appearance: 'none',
  display: 'flex',
  alignItems: 'center',
  gap: 10,
  padding: 13,
  borderRadius: 14,
  cursor: 'pointer',
  color: 'var(--color-text-primary)',
  background: 'color-mix(in srgb, var(--color-success) 10%, transparent)',
  border: '1px solid color-mix(in srgb, var(--color-success) 28%, transparent)'
}
const nudgeDot: React.CSSProperties = {
  width: 8,
  height: 8,
  borderRadius: '50%',
  background: 'var(--color-success)',
  boxShadow: '0 0 0 4px color-mix(in srgb, var(--color-success) 25%, transparent)',
  flex: '0 0 auto'
}

function momentGlyph(icon: Moment['icon']): string {
  return icon === 'ship' ? '🚀' : icon === 'explain' ? '🗣️' : '✅'
}
function momentTint(icon: Moment['icon'], alpha: number): string {
  const base = icon === 'ship' ? 'var(--color-success)' : icon === 'explain' ? 'var(--color-skills-accent)' : 'var(--color-success)'
  return alpha === 1 ? base : `color-mix(in srgb, ${base} ${alpha * 100}%, transparent)`
}
