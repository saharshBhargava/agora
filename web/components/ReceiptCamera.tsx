'use client';
import { useRef, type ChangeEvent } from 'react';
import { Camera } from './Camera';

/** Reads an image file as base64 (no data: prefix). */
export function fileToBase64(file: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(String(r.result).replace(/^data:[^,]*,/, ''));
    r.onerror = () => reject(new Error('Could not read that photo'));
    r.readAsDataURL(file);
  });
}

/**
 * Full-screen receipt camera for the shopper. Reuses the cart camera's stream when there is one.
 * The shutter sends the latest frame; "From photos" sends a picked image instead.
 */
export function ReceiptCamera({
  busy,
  mock,
  mockHref,
  error,
  onSubmit,
  onError,
}: {
  busy: boolean;
  mock: boolean;
  mockHref: string;
  error: string | null;
  onSubmit: (imageBase64: string) => void;
  onError: (message: string) => void;
}) {
  const frameRef = useRef<string | null>(null);

  const pick = async (e: ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    e.target.value = '';
    if (!file) return;
    try {
      onSubmit(await fileToBase64(file));
    } catch (err) {
      onError(err instanceof Error ? err.message : 'Could not read that photo');
    }
  };

  return (
    <div className="receipt-cam bleed">
      <div className="receipt-cam-head">
        <h1>Snap the receipt</h1>
        <p>Fit the whole receipt in the frame. We match each line to what was claimed.</p>
      </div>
      <div className="receipt-cam-stage">
        {mock ? (
          <div className="receipt-paper" aria-hidden="true">
            <span>PRINTED RECEIPT</span>
          </div>
        ) : (
          <Camera
            send={(m) => {
              if (typeof m.jpegBase64 === 'string') frameRef.current = m.jpegBase64;
              return true;
            }}
            enabled
            region={null}
            mockHref={mockHref}
            hideFallback
          />
        )}
        <span className="receipt-frame" aria-hidden="true" />
        <span className="receipt-cam-pill">{busy ? 'Reading the receipt…' : 'Hold steady'}</span>
      </div>
      {error && <p className="receipt-cam-error" role="alert">{error}</p>}
      <div className="receipt-cam-bar">
        <label className="receipt-cam-photos">
          <input type="file" accept="image/*" className="sr-only" onChange={pick} disabled={busy} />
          <span>From photos</span>
        </label>
        {mock ? (
          <button type="button" className="btn btn-sm receipt-cam-use" disabled={busy} onClick={() => onSubmit('')}>
            Use printed receipt
          </button>
        ) : (
          <button
            type="button"
            className="shutter"
            aria-label="Take the receipt photo"
            disabled={busy}
            onClick={() => {
              if (!frameRef.current) onError('Point the camera at the receipt first');
              else onSubmit(frameRef.current);
            }}
          >
            <span aria-hidden="true" />
          </button>
        )}
        <span className="receipt-cam-spacer" aria-hidden="true" />
      </div>
    </div>
  );
}
