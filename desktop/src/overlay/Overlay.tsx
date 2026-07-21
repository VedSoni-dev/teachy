import { useEffect, useRef, useState } from 'react';
import { buildTriangleMarkPoints } from '../notch/notchShape';
import './overlay.css';

/**
 * 'idle' is the Mac's default "Show Teachy" state: the companion trails the
 * pointer permanently with no bubble. 'hidden' is only for when the user turns
 * the companion off (macOS transient cursor mode).
 */
type OverlayMode = 'hidden' | 'idle' | 'listening' | 'thinking' | 'responding';

interface OverlayState {
  type: 'set-mode';
  mode: OverlayMode;
  statusText?: string;
  bodyText?: string;
}

/** How far below-right of the real pointer the companion trails, in DIP. Mac: 35x25. */
const CURSOR_TRAIL_OFFSET_X = 35;
const CURSOR_TRAIL_OFFSET_Y = 25;

/** Per-frame easing toward the pointer. Lower drags further behind. */
const CURSOR_FOLLOW_EASING = 0.18;

export function Overlay() {
  const [mode, setMode] = useState<OverlayMode>('hidden');
  const [statusText, setStatusText] = useState<string | null>(null);
  const [bodyText, setBodyText] = useState<string>('');
  const [pointingTarget, setPointingTarget] = useState<{ x: number; y: number } | null>(null);

  const companionElementRef = useRef<HTMLDivElement | null>(null);
  const bubbleElementRef = useRef<HTMLDivElement | null>(null);

  // Live positions kept in refs — animating through React state at 60fps
  // would re-render the whole tree every frame.
  const companionPositionRef = useRef({ x: 0, y: 0 });
  const targetPositionRef = useRef({ x: 0, y: 0 });
  const isPointingRef = useRef(false);
  const hasInitialPositionRef = useRef(false);

  // Follow the real cursor, eased, unless a pointing glide owns the companion.
  useEffect(() => {
    const unsubscribeCursor = window.teachy?.overlay.onCursor((point) => {
      targetPositionRef.current = {
        x: point.x + CURSOR_TRAIL_OFFSET_X,
        y: point.y + CURSOR_TRAIL_OFFSET_Y,
      };
      if (!hasInitialPositionRef.current) {
        companionPositionRef.current = { ...targetPositionRef.current };
        hasInitialPositionRef.current = true;
      }
    });

    let animationFrameId = 0;
    function stepAnimation() {
      if (!isPointingRef.current) {
        const currentPosition = companionPositionRef.current;
        const targetPosition = targetPositionRef.current;
        currentPosition.x += (targetPosition.x - currentPosition.x) * CURSOR_FOLLOW_EASING;
        currentPosition.y += (targetPosition.y - currentPosition.y) * CURSOR_FOLLOW_EASING;
      }

      const companionElement = companionElementRef.current;
      if (companionElement) {
        const { x, y } = companionPositionRef.current;
        companionElement.style.transform = `translate3d(${x}px, ${y}px, 0)`;
      }

      const bubbleElement = bubbleElementRef.current;
      if (bubbleElement) {
        const { x, y } = companionPositionRef.current;
        // Flip the bubble when it would run off the right/bottom edge.
        const bubbleWidth = bubbleElement.offsetWidth;
        const bubbleHeight = bubbleElement.offsetHeight;
        const bubbleX = x + bubbleWidth + 34 > window.innerWidth ? x - bubbleWidth - 18 : x + 30;
        const bubbleY = y + bubbleHeight + 34 > window.innerHeight ? y - bubbleHeight - 18 : y + 26;
        bubbleElement.style.transform = `translate3d(${Math.max(8, bubbleX)}px, ${Math.max(8, bubbleY)}px, 0)`;
      }

      animationFrameId = requestAnimationFrame(stepAnimation);
    }
    animationFrameId = requestAnimationFrame(stepAnimation);

    return () => {
      cancelAnimationFrame(animationFrameId);
      unsubscribeCursor?.();
    };
  }, []);

  // Status / streaming text pushed from the notch window's companion loop.
  useEffect(() => {
    const unsubscribeState = window.teachy?.overlay.onState((state: OverlayState) => {
      if (state.type !== 'set-mode') {
        return;
      }
      setMode(state.mode);
      setStatusText(state.statusText ?? null);
      setBodyText(state.bodyText ?? '');
    });
    return () => unsubscribeState?.();
  }, []);

  // Pointing: bezier-arc glide to the target with scale pulse, then resume follow.
  // Mac uses distance-based duration (0.6–1.4s) and a 1.3x scale at midpoint.
  useEffect(() => {
    const unsubscribePointAt = window.teachy?.overlay.onPointAt((target) => {
      isPointingRef.current = true;
      setPointingTarget({ x: target.x, y: target.y });

      const startPosition = { ...companionPositionRef.current };
      const distancePx = Math.hypot(target.x - startPosition.x, target.y - startPosition.y);
      const glideDurationMs = Math.min(1400, Math.max(600, distancePx * 0.8));
      const glideStartTime = performance.now();

      // Bezier arc control point — perpendicular offset for a curved flight path.
      const midX = (startPosition.x + target.x) / 2;
      const midY = (startPosition.y + target.y) / 2;
      const perpOffset = Math.min(80, distancePx * 0.25);
      const anglePerpendicular = Math.atan2(target.y - startPosition.y, target.x - startPosition.x) + Math.PI / 2;
      const controlPointX = midX + Math.cos(anglePerpendicular) * perpOffset;
      const controlPointY = midY + Math.sin(anglePerpendicular) * perpOffset;

      function glideStep(now: number) {
        const progress = Math.min(1, (now - glideStartTime) / glideDurationMs);
        const eased =
          progress < 0.5
            ? 4 * progress * progress * progress
            : 1 - Math.pow(-2 * progress + 2, 3) / 2;

        // Quadratic bezier arc through control point.
        const oneMinusEased = 1 - eased;
        companionPositionRef.current = {
          x: oneMinusEased * oneMinusEased * startPosition.x + 2 * oneMinusEased * eased * controlPointX + eased * eased * target.x,
          y: oneMinusEased * oneMinusEased * startPosition.y + 2 * oneMinusEased * eased * controlPointY + eased * eased * target.y,
        };

        // Scale pulse: 1.0 → 1.3 at midpoint → 1.0, matching Mac's pointing emphasis.
        const scalePulse = 1.0 + 0.3 * Math.sin(eased * Math.PI);
        const companionElement = companionElementRef.current;
        if (companionElement) {
          const { x, y } = companionPositionRef.current;
          companionElement.style.transform = `translate3d(${x}px, ${y}px, 0) scale(${scalePulse.toFixed(3)})`;
        }

        if (progress < 1) {
          requestAnimationFrame(glideStep);
        } else {
          window.setTimeout(() => {
            isPointingRef.current = false;
            setPointingTarget(null);
          }, 1600);
        }
      }
      requestAnimationFrame(glideStep);
    });

    return () => unsubscribePointAt?.();
  }, []);

  const isCompanionVisible = mode !== 'hidden';
  const isBubbleVisible = mode === 'listening' || mode === 'thinking' || mode === 'responding';

  return (
    <div className="overlay-root">
      {pointingTarget && (
        <div
          className="pointing-ring"
          style={{ transform: `translate3d(${pointingTarget.x - 23}px, ${pointingTarget.y - 23}px, 0)` }}
        />
      )}

      <div
        ref={companionElementRef}
        className="companion-cursor"
        style={{ opacity: isCompanionVisible ? 1 : 0 }}
      >
        <svg width="30" height="30" viewBox="0 0 30 30" aria-hidden="true">
          <polygon
            points={buildTriangleMarkPoints(26)}
            fill="var(--overlay-cursor-blue)"
            opacity="0.5"
            filter="url(#companion-glow)"
          />
          <polygon points={buildTriangleMarkPoints(20)} fill="var(--overlay-cursor-blue)" />
          <defs>
            <filter id="companion-glow" x="-50%" y="-50%" width="200%" height="200%">
              <feGaussianBlur stdDeviation="3" />
            </filter>
          </defs>
        </svg>
      </div>

      <div
        ref={bubbleElementRef}
        className="response-bubble"
        style={{ opacity: isBubbleVisible ? 1 : 0 }}
      >
        {statusText && <div className="response-status">{statusText}</div>}
        {bodyText && <div className="response-body">{bodyText}</div>}
      </div>
    </div>
  );
}
