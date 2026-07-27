import { useEffect, useRef, useState } from 'react';
import { useCompanionLoop } from '../state/useCompanionLoop';
import { useCourseSession } from '../state/useCourseSession';
import { LessonHUD } from '../course/LessonHUD';
import { buildNotchPath, buildTriangleMarkPoints, NOTCH_RADII, NOTCH_SIZE } from './notchShape';
import { LearnTab } from '../tabs/LearnTab';
import { ProgressTab } from '../tabs/ProgressTab';
import { PortfolioTab } from '../tabs/PortfolioTab';
import { SkillsTab } from '../tabs/SkillsTab';
import { SettingsTab } from '../tabs/SettingsTab';
import './notch.css';

export type NotchTab = 'learn' | 'progress' | 'portfolio' | 'skills' | 'settings';

/** Header tabs, in the same order and with the same accents as the Mac header. */
const TAB_DEFINITIONS: { id: NotchTab; label: string; accentVariable: string }[] = [
  { id: 'learn', label: 'Learn', accentVariable: '--learn-accent' },
  { id: 'progress', label: 'Progress', accentVariable: '--progress-accent' },
  { id: 'portfolio', label: 'Portfolio', accentVariable: '--portfolio-accent' },
  { id: 'skills', label: 'Skills', accentVariable: '--skills-accent' },
  { id: 'settings', label: 'Settings', accentVariable: '--text-primary' },
];

export function Notch() {
  const [isExpanded, setIsExpanded] = useState(false);
  const [selectedTab, setSelectedTab] = useState<NotchTab>('learn');
  const collapseTimerRef = useRef<number | null>(null);

  const { session, startCourse, exitCourse, requestHint, requestVerification, requestDoItForMe,
    handleVoiceTeachBackAnswer } = useCourseSession();

  // The always-on voice loop lives here, in the single long-lived window.
  // When a course teach-back is pending, voice answers flow through the callback.
  const teachBackCallback = session?.isAwaitingTeachBack ? handleVoiceTeachBackAnswer : undefined;
  const { handleTypedQuestion } = useCompanionLoop(teachBackCallback);

  // A running course keeps the notch open — it is the teaching surface.
  const isCourseActive = session !== null;

  const width = isExpanded ? NOTCH_SIZE.openWidth : NOTCH_SIZE.closedWidth;
  const height = isExpanded ? NOTCH_SIZE.openHeight : NOTCH_SIZE.closedHeight;
  const radii = isExpanded ? NOTCH_RADII.opened : NOTCH_RADII.closed;

  // Only accept clicks while the pointer is genuinely over the notch, so the
  // transparent rest of the window stays click-through.
  function reportInteractive(isInteractive: boolean) {
    window.teachy?.setInteractive(isInteractive);
  }

  function handlePointerEnter() {
    if (collapseTimerRef.current !== null) {
      window.clearTimeout(collapseTimerRef.current);
      collapseTimerRef.current = null;
    }
    reportInteractive(true);
    setIsExpanded(true);
  }

  function handlePointerLeave() {
    // A live course must stay open — collapsing would hide the lesson controls.
    if (isCourseActive) {
      return;
    }
    // Small grace period so crossing a gap between controls doesn't collapse it.
    collapseTimerRef.current = window.setTimeout(() => {
      setIsExpanded(false);
      reportInteractive(false);
    }, 260);
  }

  useEffect(() => {
    return () => {
      if (collapseTimerRef.current !== null) {
        window.clearTimeout(collapseTimerRef.current);
      }
    };
  }, []);

  // The tray icon asks the notch to open.
  useEffect(() => {
    const unsubscribe = window.teachy?.notch.onOpenRequested(() => {
      reportInteractive(true);
      setIsExpanded(true);
    });
    return () => unsubscribe?.();
  }, []);

  /**
   * Drag the collapsed notch to reposition it. Pointer capture keeps the moves
   * coming even when the pointer leaves the small bar mid-drag.
   */
  function handleDragPointerDown(pointerEvent: React.PointerEvent<HTMLDivElement>) {
    if (isExpanded) {
      return;
    }

    const dragElement = pointerEvent.currentTarget;
    dragElement.setPointerCapture(pointerEvent.pointerId);

    let lastScreenX = pointerEvent.screenX;
    let lastScreenY = pointerEvent.screenY;
    let hasMoved = false;

    function handleDragMove(moveEvent: PointerEvent) {
      const deltaX = moveEvent.screenX - lastScreenX;
      const deltaY = moveEvent.screenY - lastScreenY;
      if (deltaX === 0 && deltaY === 0) {
        return;
      }
      hasMoved = true;
      lastScreenX = moveEvent.screenX;
      lastScreenY = moveEvent.screenY;
      window.teachy?.notch.moveBy(deltaX, deltaY);
    }

    async function handleDragEnd() {
      dragElement.removeEventListener('pointermove', handleDragMove);
      dragElement.removeEventListener('pointerup', handleDragEnd);
      if (hasMoved) {
        // A hand-placed notch is a Custom placement from now on.
        await window.teachy?.invoke('set-config', { notchPlacement: 'Custom' });
      }
    }

    dragElement.addEventListener('pointermove', handleDragMove);
    dragElement.addEventListener('pointerup', handleDragEnd);
  }

  const notchPath = buildNotchPath(width, height, radii.top, radii.bottom);

  return (
    <div className="notch-root">
      <div
        className={`notch ${isExpanded ? 'is-expanded' : 'is-collapsed'}`}
        style={{
          width,
          height,
          // The exact Mac silhouette, clipping the vibrancy layer inside it.
          clipPath: `path('${notchPath}')`,
        }}
        onMouseEnter={handlePointerEnter}
        onMouseLeave={handlePointerLeave}
        onPointerDown={handleDragPointerDown}
      >
        <div className="notch-surface" />

        {isExpanded ? (
          <div className="notch-content">
            <header className="notch-header">
              <nav className="tab-strip">
                {TAB_DEFINITIONS.map((tab) => (
                  <button
                    key={tab.id}
                    type="button"
                    className={`tab-button ${selectedTab === tab.id ? 'is-selected' : ''}`}
                    style={{ ['--tab-accent' as string]: `var(${tab.accentVariable})` }}
                    onClick={() => setSelectedTab(tab.id)}
                    title={tab.label}
                  >
                    <TabGlyph tab={tab.id} />
                  </button>
                ))}
              </nav>

              <div className="header-right">
                <TeachyMark size={18} />
                <button
                  type="button"
                  className="collapse-button"
                  onClick={() => setIsExpanded(false)}
                  title="Collapse"
                >
                  <svg viewBox="0 0 12 12" width="11" height="11" aria-hidden="true">
                    <path
                      d="M2 7.5 L6 3.5 L10 7.5"
                      fill="none"
                      stroke="currentColor"
                      strokeWidth="1.6"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                    />
                  </svg>
                </button>
              </div>
            </header>

            <div className="tab-body">
              {session ? (
                <LessonHUD
                  session={session}
                  onHint={requestHint}
                  onDoItForMe={() => void requestDoItForMe()}
                  onIDidIt={() => void requestVerification()}
                  onExit={exitCourse}
                />
              ) : (
                <>
                  {selectedTab === 'learn' && <LearnTab onStartCourse={startCourse} />}
                  {selectedTab === 'progress' && <ProgressTab />}
                  {selectedTab === 'portfolio' && <PortfolioTab />}
                  {selectedTab === 'skills' && <SkillsTab />}
                  {selectedTab === 'settings' && <SettingsTab onAskQuestion={handleTypedQuestion} />}
                </>
              )}
            </div>
          </div>
        ) : (
          <div className="notch-idle" />
        )}
      </div>

      {/* Idle wing: the glowing Teachy mark past the bar, as on the Mac. */}
      {!isExpanded && (
        <div
          className="idle-wing"
          style={{ left: `calc(50% + ${NOTCH_SIZE.closedWidth / 2 + 12}px)` }}
          onMouseEnter={handlePointerEnter}
        >
          <TeachyMark size={13} glowing />
        </div>
      )}
    </div>
  );
}

/** The Teachy triangle, drawn from the Mac's own rotated-equilateral geometry. */
function TeachyMark({ size, glowing = false }: { size: number; glowing?: boolean }) {
  return (
    <svg
      className={`teachy-mark ${glowing ? 'is-glowing' : ''}`}
      width={size}
      height={size}
      viewBox={`0 0 ${size} ${size}`}
      aria-hidden="true"
    >
      <polygon points={buildTriangleMarkPoints(size)} fill="var(--overlay-cursor)" />
    </svg>
  );
}

function TabGlyph({ tab }: { tab: NotchTab }) {
  const commonProps = {
    width: 13,
    height: 13,
    viewBox: '0 0 16 16',
    fill: 'none',
    stroke: 'currentColor',
    strokeWidth: 1.5,
    strokeLinecap: 'round' as const,
    strokeLinejoin: 'round' as const,
  };

  switch (tab) {
    case 'learn': // book
      return (
        <svg {...commonProps} aria-hidden="true">
          <path d="M2.5 3.2v9.6c1.8-.9 3.7-.9 5.5 0 1.8-.9 3.7-.9 5.5 0V3.2c-1.8-.9-3.7-.9-5.5 0-1.8-.9-3.7-.9-5.5 0Z" />
          <path d="M8 3.2v9.6" />
        </svg>
      );
    case 'progress': // upward trend
      return (
        <svg {...commonProps} aria-hidden="true">
          <path d="M2 11 L6 7 L9 10 L14 4" />
          <path d="M11 4h3v3" />
        </svg>
      );
    case 'portfolio': // folder
      return (
        <svg {...commonProps} aria-hidden="true">
          <path d="M2 4.5A1.5 1.5 0 0 1 3.5 3h2.4c.4 0 .8.2 1.1.5l.9.9h4.6A1.5 1.5 0 0 1 14 5.9v5.6A1.5 1.5 0 0 1 12.5 13h-9A1.5 1.5 0 0 1 2 11.5Z" />
        </svg>
      );
    case 'skills': // bar chart
      return (
        <svg {...commonProps} aria-hidden="true">
          <path d="M3 13V8.5M8 13V4M13 13v-6" />
        </svg>
      );
    case 'settings': // sliders
      return (
        <svg {...commonProps} aria-hidden="true">
          <path d="M2.5 5h11M2.5 11h11" />
          <circle cx="6" cy="5" r="1.6" fill="currentColor" stroke="none" />
          <circle cx="10.5" cy="11" r="1.6" fill="currentColor" stroke="none" />
        </svg>
      );
  }
}
