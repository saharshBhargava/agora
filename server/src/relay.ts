// Latest-frame relay helpers. Only the newest frame per run is kept; it is never written to disk.
export type Frame = { jpegBase64: string; at: number };

export function shouldSendFrame(bufferedAmount: number, limit = 200_000): boolean {
  return bufferedAmount <= limit;
}

export function createFrameRelay() {
  const latest = new Map<string, Frame>();
  return {
    set: (runId: string, frame: Frame): void => void latest.set(runId, frame),
    get: (runId: string): Frame | undefined => latest.get(runId),
    drop: (runId: string): void => void latest.delete(runId),
  };
}
