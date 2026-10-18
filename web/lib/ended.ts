/** What to show when the server refused a run's socket (useRun's `ended`), from its close reason. */
export function endedMessage(reason: string | null): string {
  if (reason === 'old run') return 'This run was started before an update. Start a new run.';
  if (reason === 'not allowed') return 'This run is open on another device. Open it from the phone that joined.';
  return 'This run has ended';
}
