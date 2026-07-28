// Temporary stand-in for tabs not yet ported. Keeps the shell navigable and
// honest about what's real vs. coming, instead of faking a finished screen.
export function PlaceholderTab({ title, note }: { title: string; note: string }): JSX.Element {
  return (
    <>
      <div className="section-head">
        <h1>{title}</h1>
      </div>
      <div className="glass-card" style={{ textAlign: 'center', padding: 24 }}>
        <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--color-text-secondary)', marginBottom: 6 }}>
          Coming in the migration
        </div>
        <div style={{ fontSize: 11, color: 'var(--color-text-tertiary)', lineHeight: 1.5 }}>{note}</div>
      </div>
    </>
  )
}
