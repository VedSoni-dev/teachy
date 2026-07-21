import './tabs.css';

export function SkillsTab() {
  return (
    <div className="empty-state">
      <div className="empty-state-glyph" style={{ color: 'var(--skills-accent)' }}>
        ▨
      </div>
      <div className="empty-state-title">No skills tracked yet</div>
      <p className="empty-state-body">
        Your learner model grows as you complete courses and teach-backs.
      </p>
    </div>
  );
}
