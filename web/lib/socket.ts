'use client';
import { useCallback, useEffect, useRef, useState } from 'react';
import { api } from './api';
import type { Box, Run } from './types';

export type ClientMsg = Record<string, unknown>;

export type UseRun = {
  run: Run | null;
  send: (msg: ClientMsg) => void;
  /** Latest relayed camera frame as a data URL (claimers only). */
  lastFrame: string | null;
  lastCallEndsAt: number | null;
  identifyingRegion: Box | null;
  error: string | null;
  connected: boolean;
};

export function wsUrl(runId: string, personId: string): string {
  const base =
    process.env.NEXT_PUBLIC_WS_URL ??
    `${window.location.protocol === 'https:' ? 'wss' : 'ws'}://${window.location.host}`;
  return `${base}/ws?run=${encodeURIComponent(runId)}&person=${encodeURIComponent(personId)}`;
}

export function useRun(runId: string | null, personId: string | null): UseRun {
  const [run, setRun] = useState<Run | null>(null);
  const [lastFrame, setLastFrame] = useState<string | null>(null);
  const [lastCallEndsAt, setLastCallEndsAt] = useState<number | null>(null);
  const [identifyingRegion, setIdentifyingRegion] = useState<Box | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [connected, setConnected] = useState(false);
  const wsRef = useRef<WebSocket | null>(null);

  useEffect(() => {
    if (!runId || !personId) return;
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
        // Re-sync after (re)connect; the server also pushes a run message on connect.
        api.getRun(runId).then((r) => !closed && setRun(r)).catch(() => {});
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
            break;
        }
      };
      ws.onclose = () => {
        setConnected(false);
        if (wsRef.current === ws) wsRef.current = null;
        if (closed) return;
        attempt += 1;
        retry = setTimeout(connect, Math.min(5000, 250 * 2 ** attempt));
      };
      ws.onerror = () => ws.close();
    };

    connect();
    return () => {
      closed = true;
      if (retry) clearTimeout(retry);
      wsRef.current?.close();
      wsRef.current = null;
    };
  }, [runId, personId]);

  const send = useCallback((msg: ClientMsg) => {
    const ws = wsRef.current;
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
  }, []);

  return { run, send, lastFrame, lastCallEndsAt, identifyingRegion, error, connected };
}
