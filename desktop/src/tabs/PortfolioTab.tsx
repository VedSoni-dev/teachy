import './tabs.css';

export function PortfolioTab() {
  return (
    <div className="empty-state">
      <div className="empty-state-glyph" style={{ color: 'var(--portfolio-accent)' }}>
        🗂
      </div>
      <div className="empty-state-title">Your portfolio is empty</div>
      <p className="empty-state-body">
        Finish course goals and Teachy captures the real things you build.
      </p>
    </div>
  );
}
