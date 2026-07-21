import { useEffect, useState } from 'react';
import { BUNDLED_COURSES, type CourseCatalogEntry } from '../data/courseCatalog';
import type { CourseProgressEntry } from '../state/useCourseSession';
import './tabs.css';

/**
 * Course catalog. Type sizes, padding and radii are transcribed from
 * NotchCoursesTabView.swift: title 13/semibold, subtitle 10, meta 11/semibold,
 * row padding 12, card radius 10.
 */
export function LearnTab({ onStartCourse }: { onStartCourse: (course: CourseCatalogEntry) => void }) {
  const [expandedCourseId, setExpandedCourseId] = useState<string | null>(null);
  const [progressByCourseId, setProgressByCourseId] = useState<Record<string, CourseProgressEntry>>({});

  useEffect(() => {
    void (async () => {
      try {
        const savedProgress =
          await window.teachy?.invoke<Record<string, CourseProgressEntry>>('get-progress');
        setProgressByCourseId(savedProgress ?? {});
      } catch {
        // No saved progress yet is a normal first-run state.
      }
    })();
  }, []);

  return (
    <div className="course-list">
      {BUNDLED_COURSES.map((course) => (
        <CourseRow
          key={course.id}
          course={course}
          progress={progressByCourseId[course.id] ?? null}
          isExpanded={expandedCourseId === course.id}
          onToggle={() =>
            setExpandedCourseId((current) => (current === course.id ? null : course.id))
          }
          onStart={() => onStartCourse(course)}
        />
      ))}
    </div>
  );
}

function CourseRow({
  course,
  progress,
  isExpanded,
  onToggle,
  onStart,
}: {
  course: CourseCatalogEntry;
  progress: CourseProgressEntry | null;
  isExpanded: boolean;
  onToggle: () => void;
  onStart: () => void;
}) {
  const hasStarted = progress !== null && progress.completedGoals > 0;
  const progressFraction = hasStarted
    ? Math.min(1, progress.completedGoals / Math.max(1, progress.totalGoals))
    : 0;

  return (
    <div className="course-row glass-card" onClick={onToggle}>
      <div className="course-row-main">
        <div className="course-icon" aria-hidden="true">
          {course.glyph}
        </div>

        <div className="course-text">
          <div className="course-title">{course.title}</div>
          <div className="course-subtitle">{course.subtitle}</div>

          {hasStarted && (
            <>
              <div className="course-progress-track">
                <div
                  className="course-progress-fill"
                  style={{ width: `${progressFraction * 100}%` }}
                />
              </div>
              <div className="course-progress-label">
                {progress.completed
                  ? 'Completed'
                  : `${progress.completedGoals} of ${progress.totalGoals} goals`}
              </div>
            </>
          )}
        </div>

        <div className="course-actions">
          <span className="course-duration">{course.estimatedMinutes} min</span>
          <button
            type="button"
            className="start-button"
            onClick={(clickEvent) => {
              clickEvent.stopPropagation();
              onStart();
            }}
          >
            {hasStarted && !progress.completed ? 'Continue' : 'Start'}
          </button>
        </div>
      </div>

      {isExpanded && <p className="course-description">{course.description}</p>}
    </div>
  );
}
