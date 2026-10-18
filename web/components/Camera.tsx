'use client';
import { useEffect, useRef, useState } from 'react';
import type { Box } from '@/lib/types';
import { FRAME_W, frameBoxToDisplay, frameHeight, tapToFrame } from '@/lib/frame';
import { propBase64, type PropName } from '@/lib/props';

const FRAME_MS = 500; // 2 fps
const QUALITY = 0.6;

export type CameraProps = {
  send: (msg: Record<string, unknown>) => boolean;
  /** Frames are sent only while enabled (run open or last call, socket connected). */
  enabled: boolean;
  /** The region the server is identifying, in frame pixels. */
  region: Box | null;
  /** Optional white label over the region ("Kirkland Eggs · $8.72"); a pending outline pulses. */
  label?: string | null;
  pending?: boolean;
  /** Link target for the "Use sample items" fallback. */
  mockHref: string;
};

/** Rear camera preview. Streams a 640 px JPEG frame every 500 ms; tapping the preview sends identifyAt. No shutter. */
export function Camera({ send, enabled, region, label, pending = true, mockHref }: CameraProps) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const boxRef = useRef<HTMLDivElement>(null);
  const [ready, setReady] = useState(false);
  const [denied, setDenied] = useState(false);
  const [, setTick] = useState(0);
  const sendRef = useRef(send);
  const enabledRef = useRef(enabled);
  sendRef.current = send;
  enabledRef.current = enabled;

  // Camera plus a screen wake lock. A phone that backgrounds or locks ends the track, so the stream is
  // re-acquired when the page is visible again or a track ends; the wake lock is re-requested on visible.
  useEffect(() => {
    let stopped = false;
    let stream: MediaStream | null = null;
    let acquiring = false;
    let wake: { release: () => Promise<void> } | null = null;

    const requestWake = async () => {
      try {
        const lock = (navigator as Navigator & { wakeLock?: { request: (t: 'screen') => Promise<{ release: () => Promise<void> }> } }).wakeLock;
        const s = await lock?.request('screen');
        if (!s) return;
        if (stopped) {
          void s.release().catch(() => undefined);
          return;
        }
        if (wake && wake !== s) void wake.release().catch(() => undefined);
        wake = s;
      } catch {
        /* not supported or refused: the README asks for Auto-Lock off */
      }
    };

    const healthy = (s: MediaStream | null): boolean =>
      !!s && s.getTracks().length > 0 && s.getTracks().every((t) => t.readyState === 'live' && !t.muted);

    const acquire = async () => {
      if (stopped || acquiring) return;
      acquiring = true;
      try {
        const next = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' }, audio: false });
        if (stopped) {
          next.getTracks().forEach((t) => t.stop());
          return;
        }
        stream?.getTracks().forEach((t) => t.stop());
        stream = next;
        next.getTracks().forEach((t) => {
          t.onended = () => {
            if (stream === next) void acquire();
          };
        });
        const v = videoRef.current;
        if (v) {
          v.srcObject = next;
          try {
            await v.play?.();
          } catch {
            /* autoplay is handled by the attributes */
          }
        }
        setReady(true);
        void requestWake();
      } catch {
        if (!stopped && !stream) setDenied(true);
      } finally {
        acquiring = false;
      }
    };

    const onVisibility = () => {
      if (document.visibilityState !== 'visible') return;
      if (!healthy(stream)) void acquire();
      else void requestWake();
    };

    void acquire();
    document.addEventListener('visibilitychange', onVisibility);
    return () => {
      stopped = true;
      document.removeEventListener('visibilitychange', onVisibility);
      stream?.getTracks().forEach((t) => t.stop());
      void wake?.release().catch(() => undefined);
    };
  }, []);

  useEffect(() => {
    if (!ready) return;
    const canvas = document.createElement('canvas');
    const id = setInterval(() => {
      const v = videoRef.current;
      if (!enabledRef.current || !v || !v.videoWidth) return;
      const h = frameHeight(v.videoWidth, v.videoHeight);
      if (canvas.width !== FRAME_W) canvas.width = FRAME_W;
      if (canvas.height !== h) canvas.height = h;
      const ctx = canvas.getContext('2d');
      if (!ctx) return;
      ctx.drawImage(v, 0, 0, FRAME_W, h);
      const jpegBase64 = canvas.toDataURL('image/jpeg', QUALITY).replace(/^data:image\/jpeg;base64,/, '');
      sendRef.current({ t: 'frame', jpegBase64, at: Date.now() });
    }, FRAME_MS);
    return () => clearInterval(id);
  }, [ready]);

  // Re-measure the outline when the box resizes.
  useEffect(() => {
    const on = () => setTick((n) => n + 1);
    window.addEventListener('resize', on);
    return () => window.removeEventListener('resize', on);
  }, []);

  if (denied) {
    return (
      <div className="camera-denied">
        <p>The camera is off. Allow camera access to stream the cart, or drop in sample items.</p>
        <a className="btn btn-sm btn-secondary" href={mockHref}>Use sample items</a>
      </div>
    );
  }

  const onTap = (e: React.MouseEvent) => {
    const v = videoRef.current;
    const el = boxRef.current;
    if (!v || !el || !v.videoWidth || !enabled) return;
    const r = el.getBoundingClientRect();
    const { x, y } = tapToFrame(r, v.videoWidth, v.videoHeight, e.clientX, e.clientY);
    sendRef.current({ t: 'identifyAt', x, y });
  };

  let outline: { left: number; top: number; width: number; height: number } | null = null;
  const v = videoRef.current;
  const el = boxRef.current;
  if (region && v?.videoWidth && el) {
    outline = frameBoxToDisplay(region, { width: el.clientWidth, height: el.clientHeight }, v.videoWidth, v.videoHeight);
  }

  return (
    <div className="camera" ref={boxRef} onClick={onTap} role="button" tabIndex={0} aria-label="Live view. Tap an item to identify it.">
      <video ref={videoRef} className="camera-video" autoPlay muted playsInline />
      {outline && <span className={`camera-outline${pending ? ' camera-outline-pending' : ''}`} style={outline} />}
      {outline && label && (
        <span className="region-label camera-label" style={{ left: outline.left, top: outline.top }}>
          <span className="region-label-dot" aria-hidden="true" />{label}
        </span>
      )}
    </div>
  );
}

/** Sample items for `?mock=1`: posts a bundled image with a hint, no basket needed. */
export function MockProps({ onPick, busy }: { onPick: (name: PropName, imageBase64: string) => void | Promise<void>; busy: boolean }) {
  const props: { name: PropName; label: string }[] = [
    { name: 'eggs', label: 'Eggs' },
    { name: 'towels', label: 'Towels' },
    { name: 'milk', label: 'Milk' },
  ];
  return (
    <div className="mock-props">
      <p className="mock-props-title">Drop an item into the cart</p>
      <div className="mock-props-row">
        {props.map((p) => (
          <button
            key={p.name}
            type="button"
            className="mock-pill"
            disabled={busy}
            onClick={async () => onPick(p.name, await propBase64(p.name))}
          >
            {p.label}
          </button>
        ))}
      </div>
    </div>
  );
}
