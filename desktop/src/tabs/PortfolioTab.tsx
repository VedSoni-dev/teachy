import { useEffect, useState } from 'react';
import { BUNDLED_COURSES } from '../data/courseCatalog';
import type { CourseProgressEntry } from '../state/useCourseSession';
import './tabs.css';

export function PortfolioTab() {
  const [completedCourses, setCompletedCourses] = useState<
    Array<{ title: string; subtitle: string; completedDate: string }>
  >([]);

  useEffect(() => {
    void (async () => {
      try {
        const allProgress = await window.teachy?.invoke<Record<string, CourseProgressEntry>>('get-progress');
        if (!allProgress) return;

        const artifacts: typeof completedCourses = [];
        for (const course of BUNDLED_COURSES) {
          const progress = allProgress[course.id];
          if (progress?.completed) {
            const completedDate = new Date(progress.lastActivityUtc).toLocaleDateString(undefined, {
              year: 'numeric',
              month: 'long',
              day: 'numeric',
            });
            artifacts.push({ title: course.title, subtitle: course.subtitle, completedDate });
          }
        }
        setCompletedCourses(artifacts);
      } catch {
        // No progress data — keep empty state.
      }
    })();
  }, []);

  if (completedCourses.length === 0) {
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

  return (
    <div className="portfolio-list">
      {completedCourses.map((artifact) => (
        <div key={artifact.title} className="glass-card portfolio-card">
          <div className="portfolio-card-header">
            <span className="portfolio-card-title">{artifact.title}</span>
            <span className="portfolio-shipped-badge">shipped</span>
          </div>
          <div className="portfolio-card-subtitle">{artifact.subtitle}</div>
          <div className="portfolio-card-date">completed {artifact.completedDate}</div>
        </div>
      ))}
    </div>
  );
}
