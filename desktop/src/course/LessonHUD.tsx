import type { CourseSessionState } from '../state/useCourseSession';
import './lessonHUD.css';

/**
 * The floating teaching HUD — port of the macOS CourseLessonHUDWindow. Shows
 * the active goal, the last coach line, and Hint / Do it for me / I did it.
 */
export function LessonHUD({
  session,
  onHint,
  onDoItForMe,
  onIDidIt,
  onExit,
}: {
  session: CourseSessionState;
  onHint: () => void;
  onDoItForMe: () => void;
  onIDidIt: () => void;
  onExit: () => void;
}) {
  const currentGoal = session.goals[session.currentGoalIndex];

  return (
    <div className="lesson-hud">
      <div className="lesson-hud-header">
        <span className="lesson-hud-title">{session.course.title}</span>
        <span className="lesson-hud-progress">
          goal {session.currentGoalIndex + 1} of {session.goals.length}
        </span>
      </div>

      <div className="lesson-hud-goal">{currentGoal.title}</div>
      <div className="lesson-hud-coach">{session.coachLine}</div>

      <div className="lesson-hud-actions">
        <button type="button" className="hud-button" onClick={onHint} disabled={session.isBusy}>
          Hint
        </button>
        <button type="button" className="hud-button is-accent" onClick={onDoItForMe} disabled={session.isBusy}>
          Do it for me
        </button>
        <button type="button" className="hud-button is-primary" onClick={onIDidIt} disabled={session.isBusy}>
          {session.isAwaitingTeachBack ? 'Skip' : 'I did it'}
        </button>
        <button type="button" className="hud-button is-quiet" onClick={onExit}>
          Exit course
        </button>
      </div>
    </div>
  );
}
