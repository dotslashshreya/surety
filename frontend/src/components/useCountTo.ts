import { useEffect, useRef, useState } from "react";
import { tween } from "../model/tween";

/**
 * Shows `target`, counting to it over `duration` ms whenever it changes (e.g. a bond being slashed).
 * Interruptible: a new target starts from whatever is on screen. With reduced motion it jumps straight there.
 * Returns the value to display and whether it is still moving.
 */
export function useCountTo(target: number, duration = 900): [number, boolean] {
  const [shown, setShown] = useState(target);
  const shownRef = useRef(target);

  useEffect(() => {
    const from = shownRef.current;
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (Math.abs(target - from) < 0.5 || reduce) {
      shownRef.current = target;
      setShown(target);
      return;
    }
    const start = performance.now();
    let raf = 0;
    const step = (now: number) => {
      const v = tween(from, target, now - start, duration);
      shownRef.current = v;
      setShown(v);
      if (now - start < duration) raf = requestAnimationFrame(step);
    };
    raf = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf);
  }, [target, duration]);

  return [shown, Math.abs(shown - target) >= 0.5];
}
