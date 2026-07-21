import { useEffect, useState } from 'react';
import { BUNDLED_COURSES } from '../data/courseCatalog';
import type { CourseProgressEntry } from '../state/useCourseSession';
import './tabs.css';

interface SkillRow {
  courseTitle: string;
  completedGoals: number;
  totalGoals: number;
  proficiencyLabel: string;
  progressFraction: number;
  lastPracticed: string;
}

export function SkillsTab() {
  const [skills, setSkills] = useState<SkillRow[]>([]);

  useEffect(() => {
    void (async () => {
      try {
        const allProgress = await window.teachy?.invoke<Record<string, CourseProgressEntry>>('get-progress');
        if (!allProgress) return;

        const rows: SkillRow[] = [];
        for (const course of BUNDLED_COURSES) {
          const progress = allProgress[course.id];
          if (progress && progress.completedGoals > 0) {
            const progressFraction = Math.min(
              1,
              Math.max(0, progress.completedGoals / Math.max(1, progress.totalGoals)),
            );
            const proficiencyLabel = progress.completed
              ? 'proficient'
              : progress.completedGoals >= progress.totalGoals / 2
                ? 'developing'
                : 'learning';
            const lastPracticed = new Date(progress.lastActivityUtc).toLocaleDateString(undefined, {
              month: 'short',
              day: 'numeric',
            });
            rows.push({
              courseTitle: course.title,
              completedGoals: progress.completedGoals,
              totalGoals: progress.totalGoals,
              proficiencyLabel,
              progressFraction,
              lastPracticed,
            });
          }
        }
        setSkills(rows);
      } catch {
        // No progress data — keep empty state.
      }
    })();
  }, []);

  if (skills.length === 0) {
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

  return (
    <div className="skills-list">
      {skills.map((skill) => (
        <div key={skill.courseTitle} className="glass-card skill-card">
          <div className="skill-card-header">
            <span className="skill-card-title">{skill.courseTitle}</span>
            <span className="skill-proficiency-label">{skill.proficiencyLabel}</span>
          </div>
          <div className="skill-progress-track">
            <div
              className="skill-progress-fill"
              style={{ width: `${skill.progressFraction * 100}%` }}
            />
          </div>
          <div className="skill-card-meta">
            {skill.completedGoals} of {skill.totalGoals} goals · last practiced {skill.lastPracticed}
          </div>
        </div>
      ))}
    </div>
  );
}
