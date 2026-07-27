import { useEffect, useState } from 'react';
import { BUNDLED_COURSES } from '../data/courseCatalog';
import { GOALS_BY_COURSE_ID } from '../data/courseGoals';
import type { CourseProgressEntry } from '../state/useCourseSession';
import './tabs.css';

// Per-learner tracker, mirroring the Mac NotchProgressTabView. v1 shows only the
// fields the Windows data plane can derive today from `get-progress`
// (things-built, skills-learned-approx, current course, next-up). `streak` and
// `recent moments` need per-goal timestamps + a streak field the sidecar's
// LearnerProgressStore does not yet store — added when the learner model lands
// (assessment P1 #6). Showing them as zeros would be dishonest, so they're
// deferred rather than faked.
interface ProgressSnapshot {
  thingsBuilt: number;
  skillsLearned: number;
  currentCourse: { title: string; percent: number; nextUp: string | null } | null;
}

export function ProgressTab() {
  const [snapshot, setSnapshot] = useState<ProgressSnapshot | null>(null);

  useEffect(() => {
    void (async () => {
      try {
        const allProgress = await window.teachy?.invoke<Record<string, CourseProgressEntry>>('get-progress');
        if (!allProgress) {
          setSnapshot(null);
          return;
        }

        let thingsBuilt = 0;
        let skillsLearned = 0;
        // The current course is the most recently active one that's started but
        // not finished — the same "resume here" a learner expects to see.
        let current:
          | { title: string; percent: number; nextUp: string | null; lastActivityUtc: string }
          | null = null;

        for (const course of BUNDLED_COURSES) {
          const progress = allProgress[course.id];
          if (!progress) continue;

          if (progress.completed) thingsBuilt += 1;
          if (progress.completedGoals > 0) skillsLearned += 1;

          if (!progress.completed && progress.completedGoals > 0) {
            const percent = Math.round(
              Math.min(1, Math.max(0, progress.completedGoals / Math.max(1, progress.totalGoals))) * 100,
            );
            const goals = GOALS_BY_COURSE_ID[course.id] ?? [];
            const nextGoal = goals[Math.min(progress.completedGoals, Math.max(0, goals.length - 1))];
            const candidate = {
              title: course.title,
              percent,
              nextUp: nextGoal?.title ?? null,
              lastActivityUtc: progress.lastActivityUtc,
            };
            if (!current || candidate.lastActivityUtc > current.lastActivityUtc) {
              current = candidate;
            }
          }
        }

        setSnapshot({
          thingsBuilt,
          skillsLearned,
          currentCourse: current
            ? { title: current.title, percent: current.percent, nextUp: current.nextUp }
            : null,
        });
      } catch {
        setSnapshot(null);
      }
    })();
  }, []);

  const isEmpty =
    !snapshot || (snapshot.thingsBuilt === 0 && snapshot.skillsLearned === 0 && !snapshot.currentCourse);

  if (isEmpty) {
    return (
      <div className="empty-state">
        <div className="empty-state-glyph" style={{ color: 'var(--progress-accent)' }}>
          △
        </div>
        <div className="empty-state-title">Your progress starts with your first course</div>
        <p className="empty-state-body">
          The things you build and the skills you pick up all show up here.
        </p>
      </div>
    );
  }

  return (
    <div className="progress-stack">
      <div className="glass-card progress-hero">
        <div className="progress-stat">
          <span className="progress-stat-num">{snapshot!.thingsBuilt}</span>
          <span className="progress-stat-label">things built</span>
        </div>
        <div className="progress-stat">
          <span className="progress-stat-num" style={{ color: 'var(--progress-accent)' }}>
            {snapshot!.skillsLearned}
          </span>
          <span className="progress-stat-label">skills learned</span>
        </div>
      </div>

      {snapshot!.currentCourse && (
        <div className="glass-card">
          <div className="progress-course-head">
            <div>
              <div className="progress-eyebrow">CURRENT COURSE</div>
              <div className="progress-course-title">{snapshot!.currentCourse.title}</div>
            </div>
            <div className="progress-percent">{snapshot!.currentCourse.percent}%</div>
          </div>
          <div className="progress-track">
            <div className="progress-fill" style={{ width: `${snapshot!.currentCourse.percent}%` }} />
          </div>
        </div>
      )}

      {snapshot!.currentCourse?.nextUp && (
        <div className="glass-card progress-nudge">
          <span className="progress-nudge-dot" />
          <div className="progress-nudge-copy">
            <div className="progress-nudge-title">Next up · {snapshot!.currentCourse.nextUp}</div>
          </div>
          <span className="progress-nudge-arrow">→</span>
        </div>
      )}
    </div>
  );
}
