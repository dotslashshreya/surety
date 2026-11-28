/** A strong ease-out (easeOutQuint): fast at first, settling gently, close to cubic-bezier(0.23, 1, 0.32, 1). */
export function easeOut(x: number): number {
  return 1 - Math.pow(1 - x, 5);
}

/** The value `elapsed` ms into a `duration` ms ease-out from `from` to `to`. */
export function tween(from: number, to: number, elapsed: number, duration: number): number {
  if (duration <= 0 || elapsed >= duration) return to;
  if (elapsed <= 0) return from;
  return from + (to - from) * easeOut(elapsed / duration);
}
