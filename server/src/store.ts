// In-memory runs with a JSON snapshot on every change. Every state change goes through `update`.
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { WebSocket } from 'ws';
import type { ServerMsg } from './protocol.js';
import type { Run } from './types.js';

export type Refusal = { error: string };
export type UpdateResult = { run: Run } | Refusal;

export type Store = ReturnType<typeof createStore>;

export function createStore(dataDir: string) {
  const file = join(dataDir, 'runs.json');
  const runs = new Map<string, Run>();
  const sockets = new Map<string, Set<WebSocket>>();

  if (existsSync(file)) {
    try {
      for (const r of Object.values(JSON.parse(readFileSync(file, 'utf8')) as Record<string, Run>)) runs.set(r.id, r);
    } catch {
      // A corrupt snapshot starts empty rather than blocking the server.
    }
  }

  /** A failed write is logged and never thrown: memory stays authoritative and clients still get the broadcast. */
  function snapshot(): void {
    try {
      mkdirSync(dataDir, { recursive: true });
      const tmp = `${file}.tmp`;
      writeFileSync(tmp, JSON.stringify(Object.fromEntries(runs)));
      renameSync(tmp, file);
    } catch (e) {
      console.error('snapshot failed', e);
    }
  }

  function send(ws: WebSocket, msg: ServerMsg): void {
    if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(msg));
  }

  function broadcast(runId: string, msg: ServerMsg): void {
    for (const ws of sockets.get(runId) ?? []) send(ws, msg);
  }

  /** Store, snapshot and broadcast a run. The settle sequence uses this as its `persist`. */
  async function save(run: Run): Promise<void> {
    runs.set(run.id, run);
    snapshot();
    broadcast(run.id, { t: 'run', run });
  }

  /** Applies a pure function. A refusal is returned to the caller and never persisted or broadcast. */
  function update(runId: string, fn: (run: Run) => Run | Refusal): UpdateResult {
    const cur = runs.get(runId);
    if (!cur) return { error: 'unknown run' };
    const next = fn(cur);
    if ('error' in next) return { error: next.error };
    runs.set(runId, next);
    snapshot();
    broadcast(runId, { t: 'run', run: next });
    return { run: next };
  }

  return {
    get: (id: string): Run | undefined => runs.get(id),
    add(run: Run): void {
      runs.set(run.id, run);
      snapshot();
    },
    update,
    save,
    send,
    broadcast,
    attach(runId: string, ws: WebSocket): void {
      let set = sockets.get(runId);
      if (!set) sockets.set(runId, (set = new Set()));
      set.add(ws);
      ws.on('close', () => set.delete(ws));
    },
  };
}
