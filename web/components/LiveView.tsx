'use client';
import { useEffect, useRef, useState } from 'react';
import { frameBoxToDisplay } from '@/lib/frame';
import type { Highlight } from '@/lib/highlight';

/** The latest relayed frame as a rounded hero with the "<Shopper>'s cart" pill and the identify outline. */
export function LiveView({ frame, shopperName, small, highlight }: { frame: string | null; shopperName: string; small?: boolean; highlight?: Highlight | null }) {
  const boxRef = useRef<HTMLDivElement>(null);
  const imgRef = useRef<HTMLImageElement>(null);
  const [, setTick] = useState(0);
  useEffect(() => {
    const on = () => setTick((n) => n + 1);
    window.addEventListener('resize', on);
    return () => window.removeEventListener('resize', on);
  }, []);

  let outline: { left: number; top: number; width: number; height: number } | null = null;
  const img = imgRef.current;
  const box = boxRef.current;
  if (highlight && frame && img?.naturalWidth && box) {
    outline = frameBoxToDisplay(highlight.region, { width: box.clientWidth, height: box.clientHeight }, img.naturalWidth, img.naturalHeight);
  }

  return (
    <div ref={boxRef} className={`liveview${small ? '' : ' liveview-large'}`}>
      {frame ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img ref={imgRef} src={frame} alt={`${shopperName}'s cart, live`} draggable={false} onLoad={() => setTick((n) => n + 1)} />
      ) : (
        <p className="liveview-wait">Waiting for the cart</p>
      )}
      {outline && highlight && (
        <>
          <span className={`region-outline${highlight.pending ? ' region-outline-pending' : ''}`} style={outline} aria-hidden="true" />
          <span className="region-label" style={{ left: outline.left, top: outline.top }}>{highlight.label}</span>
        </>
      )}
      <span className="liveview-tag"><span className="live-dot" aria-hidden="true" />{shopperName}&apos;s cart</span>
    </div>
  );
}
