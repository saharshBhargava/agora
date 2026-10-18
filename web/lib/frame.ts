/** Camera frames are sent 640 px wide; these helpers map between that frame and an object-fit: cover video box. */
export const FRAME_W = 640;

type Size = { width: number; height: number };

function fit(box: Size, vw: number, vh: number) {
  const s = Math.max(box.width / vw, box.height / vh);
  return { s, ox: (box.width - vw * s) / 2, oy: (box.height - vh * s) / 2, k: FRAME_W / vw };
}

export function frameHeight(vw: number, vh: number): number {
  return Math.round((FRAME_W * vh) / vw);
}

/** Tap (client coords) on the displayed video to frame pixels, clamped to the frame. */
export function tapToFrame(
  box: { left: number; top: number; width: number; height: number },
  vw: number,
  vh: number,
  clientX: number,
  clientY: number,
): { x: number; y: number } {
  const { s, ox, oy, k } = fit(box, vw, vh);
  const x = ((clientX - box.left - ox) / s) * k;
  const y = ((clientY - box.top - oy) / s) * k;
  const h = frameHeight(vw, vh);
  return {
    x: Math.round(Math.min(FRAME_W, Math.max(0, x))),
    y: Math.round(Math.min(h, Math.max(0, y))),
  };
}

/** A region in frame pixels to a rectangle in the displayed box. */
export function frameBoxToDisplay(
  r: { x: number; y: number; w: number; h: number },
  box: Size,
  vw: number,
  vh: number,
) {
  const { s, ox, oy, k } = fit(box, vw, vh);
  const f = s / k;
  return { left: ox + r.x * f, top: oy + r.y * f, width: r.w * f, height: r.h * f };
}
