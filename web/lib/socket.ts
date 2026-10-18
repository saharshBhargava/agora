'use client';
import { useCallback, useEffect, useRef, useState } from 'react';
import { adoptKeyFromHash, keyFor } from './keys';
import type { Box, Run } from './types';

export type ClientMsg = Record<string, unknown>;

export type UseRun = {
  run: Run | null;
  /** Returns false (and sets error to "Reconnecting…") when the socket is not open. */
  send: (msg: ClientMsg) => boolean;
  /** Latest relayed camera frame as a data URL (claimers only). */
  lastFrame: string | null;
  lastCallEndsAt: number | null;
  identifyingRegion: Box | null;
  error: string | null;
  /** Every server {t:'error'} bumps seq, so identical repeats are distinguishable. */
  errorEvent: { reason: string; seq: number } | null;
  connected: boolean;
  /** The server refused the socket (close code 1008: unknown run or person, or a missing key). No more reconnects. */
  ended: boolean;
  /** The server's close reason for `ended` ("old run", "not allowed", ...); see `endedMessage` (lib/ended). */
  endedReason: string | null;
};

/** `/ws?run=&person=&key=`: the key proves this browser is that person (lib/keys). */
export function wsUrl(runId: string, personId: string): string {
  const base =
    process.env.NEXT_PUBLIC_WS_URL ??
    `${window.location.protocol === 'https:' ? 'wss' : 'ws'}://${window.location.host}`;
  const key = keyFor(runId, personId);
  return `${base}/ws?run=${encodeURIComponent(runId)}&person=${encodeURIComponent(personId)}${key ? `&key=${encodeURIComponent(key)}` : ''}`;
}

export function useRun(runId: string | null, personId: string | null): UseRun {
  const [run, setRun] = useState<Run | null>(null);
  const [lastFrame, setLastFrame] = useState<string | null>(null);
  const [lastCallEndsAt, setLastCallEndsAt] = useState<number | null>(null);
  const [identifyingRegion, setIdentifyingRegion] = useState<Box | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [errorEvent, setErrorEvent] = useState<{ reason: string; seq: number } | null>(null);
  const [connected, setConnected] = useState(false);
  const [ended, setEnded] = useState(false);
  const [endedReason, setEndedReason] = useState<string | null>(null);
  const wsRef = useRef<WebSocket | null>(null);

  useEffect(() => {
    setRun(null);
    setLastFrame(null);
    setLastCallEndsAt(null);
    setIdentifyingRegion(null);
    setError(null);
    setErrorEvent(null);
    setEnded(false);
    setEndedReason(null);
    if (!runId || !personId) return;
    adoptKeyFromHash(runId, personId);
    let closed = false;
    let retry: ReturnType<typeof setTimeout> | undefined;
    let attempt = 0;

    const connect = () => {
      if (closed) return;
      const ws = new WebSocket(wsUrl(runId, personId));
      wsRef.current = ws;
      ws.onopen = () => {
        attempt = 0;
        setConnected(true);
        setError(null);
        // The server pushes a {t:'run'} snapshot on every connect, which re-syncs state.
      };
      ws.onmessage = (ev) => {
        let m: { t: string; [k: string]: unknown };
        try {
          m = JSON.parse(String(ev.data));
        } catch {
          return;
        }
        switch (m.t) {
          case 'run': {
            const r = m.run as Run;
            setRun(r);
            if (r.lastCallEndsAt == null) setLastCallEndsAt(null);
            // No chip is identifying any more: clear the outline.
            if (!(r.chips ?? []).some((c) => c.state === 'identifying' && !c.dropped)) setIdentifyingRegion(null);
            break;
          }
          case 'frame':
            // Keep only the latest frame.
            setLastFrame(`data:image/jpeg;base64,${m.jpegBase64 as string}`);
            break;
          case 'lastCall':
            setLastCallEndsAt(m.endsAt as number);
            break;
          case 'identifying':
            setIdentifyingRegion((m.region as Box | null) ?? null);
            break;
          case 'error':
            setError(String(m.reason));
            setErrorEvent((e) => ({ reason: String(m.reason), seq: (e?.seq ?? 0) + 1 }));
            break;
        }
      };
      ws.onclose = (ev?: { code?: number; reason?: string }) => {
        setConnected(false);
        if (wsRef.current === ws) wsRef.current = null;
        if (closed) return;
        if (ev?.code === 1008) {
          closed = true;
          setEnded(true);
          setEndedReason(ev.reason || null);
          return;
        }
        attempt += 1;
        retry = setTimeout(connect, Math.min(5000, 250 * 2 ** attempt));
      };
      ws.onerror = () => ws.close();
    };

    connect();
    return () => {
      closed = true;
      if (retry) clearTimeout(retry);
      const ws = wsRef.current;
      if (ws) {
        ws.onmessage = null;
        ws.onclose = null;
        ws.close();
      }
      wsRef.current = null;
    };
  }, [runId, personId]);

  const send = useCallback((msg: ClientMsg) => {
    const ws = wsRef.current;
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(msg));
      return true;
    }
    setError('Reconnecting…');
    return false;
  }, []);

  return { run, send, lastFrame, lastCallEndsAt, identifyingRegion, error, errorEvent, connected, ended, endedReason };
}
