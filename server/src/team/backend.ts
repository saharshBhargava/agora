// Source A for the wish page: the team's household API (FastAPI, `backend/` on main). It reads the open
// hand-made shopping lists, the ranked wishlist suggestions and the 7-day run-out forecasts, as one of two people:
//   - the signed-in person: the app sends their own team-API bearer token (X-Household-Token) and their household
//     is read with it. This server never signs in for them, and a refused token means no household picks.
//   - no one in particular: with no token, and only when AGORA_DEMO_PASSWORD is set, this server signs in as the
//     household's demo account (POST /v1/dev/login) and reads that household. Without the password, no token
//     means run history only.
// Configured only by env (never by a request):
//   TEAM_API_BASE_URL    the API origin, e.g. https://agora-api-yq3m.onrender.com (a trailing /v1 is fine);
//                        on its own it is enough for the token path
//   AGORA_DEMO_PASSWORD  optional: the password the hosted API requires for dev login (its own AGORA_DEMO_PASSWORD);
//                        enables only the no-token demo path
// Neither the password nor a person's token is ever logged, returned, stored on disk, or sent anywhere but
// TEAM_API_BASE_URL. Every answer is untrusted data: it is clamped and shown, never followed.
import { createHash } from 'node:crypto';
import { cleanSentence, cleanText } from './clean.js';
import { MAX_NAME, type HouseholdList, type HouseholdPicks, type HouseholdSource, type WishSuggestion } from '../wish-picks.js';

/** The dev-login alias of the backend's one demo account (backend/app/demo_account.py DEMO_HANDLE). */
export const TEAM_HANDLE = 'demo';
const DAY = 86_400_000;
const MAX_BODY = 2_000_000;
/** How many people's answers are kept at once; the oldest goes first. */
const MAX_CACHED_TOKENS = 100;
const MAX_TOKEN = 4096;

/**
 * The person's team-API bearer token from the X-Household-Token header: 1 to 4096 printable ASCII characters,
 * no whitespace. Anything else (missing, repeated, oversized, odd characters) is treated as absent.
 */
export function householdToken(value: unknown): string | undefined {
  return typeof value === 'string' && value.length <= MAX_TOKEN && /^[\x21-\x7E]+$/.test(value) ? value : undefined;
}

/** `password` is null when only the signed-in person's own token may be used (no demo login). */
export type TeamConfig = { baseUrl: string; password: string | null };

export type TeamOptions = {
  fetchImpl?: typeof fetch;
  now?: () => number;
  /** Per request. */
  timeoutMs?: number;
  /** How long a good answer is reused. */
  cacheMs?: number;
  /** How long a failure is remembered, so a down backend costs one wait and one log line, not one per page. */
  failCacheMs?: number;
  log?: (line: string) => void;
};

/** Why a call failed, in words safe to log (never a URL, token or password). */
export class TeamError extends Error {
  constructor(readonly kind: string) {
    super(kind);
  }
}

const localHosts = new Set(['localhost', '127.0.0.1', '[::1]', '::1']);

/** The origin to call, from TEAM_API_BASE_URL: https, or http only on this machine. Null when unusable. */
export function teamBaseUrl(raw: string | undefined): string | null {
  const text = raw?.trim();
  if (!text) return null;
  let url: URL;
  try {
    url = new URL(text);
  } catch {
    return null;
  }
  if (url.username || url.password || url.search || url.hash) return null;
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && localHosts.has(url.hostname))) return null;
  const path = url.pathname.replace(/\/+$/, '').replace(/\/v1$/, '');
  return `${url.origin}${path}`;
}

/**
 * Null (Source A off) unless TEAM_API_BASE_URL is set and usable. AGORA_DEMO_PASSWORD is optional: without it
 * only the signed-in person's own token reaches the household.
 */
export function teamConfigFromEnv(env: NodeJS.ProcessEnv, log: (line: string) => void = console.warn): TeamConfig | null {
  if (!env.TEAM_API_BASE_URL?.trim()) return null;
  const baseUrl = teamBaseUrl(env.TEAM_API_BASE_URL);
  if (!baseUrl) {
    log('wish-picks: TEAM_API_BASE_URL must be an https origin (http only for localhost); using run history');
    return null;
  }
  return { baseUrl, password: env.AGORA_DEMO_PASSWORD || null };
}

export function teamBackendFromEnv(env: NodeJS.ProcessEnv = process.env, options: TeamOptions = {}): TeamBackend | null {
  const config = teamConfigFromEnv(env, options.log);
  return config ? new TeamBackend(config, options) : null;
}

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => typeof v === 'object' && v !== null && !Array.isArray(v);

/** What is remembered for one person's token: their picks until `until`, or why there are none. */
type TokenEntry = { until: number; picks: HouseholdPicks; error?: undefined } | { until: number; error: TeamError; picks?: undefined };

export class TeamBackend implements HouseholdSource {
  private readonly fetchImpl: typeof fetch;
  private readonly now: () => number;
  private readonly timeoutMs: number;
  private readonly cacheMs: number;
  private readonly failCacheMs: number;
  private readonly log: (line: string) => void;
  // The demo account's own state (the no-token path).
  private token: { value: string; expiresAt: number } | null = null;
  private cached: { at: number; picks: HouseholdPicks } | null = null;
  private failed: { at: number; error: TeamError } | null = null;
  private inflight: Promise<HouseholdPicks> | null = null;
  // People's own answers, by SHA-256 of their token (never the token), oldest first. Entries are only ever
  // served for the token that made them.
  private readonly byToken = new Map<string, TokenEntry>();
  private readonly loading = new Map<string, Promise<HouseholdPicks>>();

  constructor(private readonly config: TeamConfig, options: TeamOptions = {}) {
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.now = options.now ?? Date.now;
    this.timeoutMs = options.timeoutMs ?? 4000;
    this.cacheMs = options.cacheMs ?? 60_000;
    this.failCacheMs = options.failCacheMs ?? 20_000;
    this.log = options.log ?? console.warn;
  }

  /**
   * The household's picks, cached for a minute; concurrent callers share one load. With `token` (a person's
   * own team-API bearer token) it is that person's household, read with that token alone: no dev login, no
   * retry, no fallback to another account. Without one it is the demo account's household, when configured.
   */
  async picks(token?: string): Promise<HouseholdPicks> {
    if (token !== undefined) return this.picksFor(token);
    if (!this.config.password) throw new TeamError('no demo account configured');
    const t = this.now();
    if (this.cached && t - this.cached.at < this.cacheMs) return this.cached.picks;
    if (this.failed && t - this.failed.at < this.failCacheMs) throw this.failed.error;
    this.inflight ??= this.load().finally(() => {
      this.inflight = null;
    });
    return this.inflight;
  }

  private async picksFor(token: string): Promise<HouseholdPicks> {
    const key = createHash('sha256').update(token).digest('hex');
    const t = this.now();
    for (const [k, entry] of this.byToken) if (entry.until <= t) this.byToken.delete(k);
    const hit = this.byToken.get(key);
    if (hit) {
      if (hit.error) throw hit.error;
      return hit.picks;
    }
    let load = this.loading.get(key);
    if (!load) {
      load = this.loadFor(key, token).finally(() => {
        this.loading.delete(key);
      });
      this.loading.set(key, load);
    }
    return load;
  }

  private async loadFor(key: string, token: string): Promise<HouseholdPicks> {
    try {
      const picks = await this.fetchAll(token);
      this.remember(key, { until: this.now() + this.cacheMs, picks });
      return picks;
    } catch (e) {
      const error = e instanceof TeamError ? e : new TeamError('unexpected error');
      this.remember(key, { until: this.now() + this.failCacheMs, error });
      this.log(`wish-picks: team backend unavailable (${error.kind}); using run history`);
      throw error;
    }
  }

  private remember(key: string, entry: TokenEntry): void {
    this.byToken.delete(key);
    this.byToken.set(key, entry);
    for (const oldest of this.byToken.keys()) {
      if (this.byToken.size <= MAX_CACHED_TOKENS) break;
      this.byToken.delete(oldest);
    }
  }

  private async load(): Promise<HouseholdPicks> {
    try {
      let picks: HouseholdPicks;
      try {
        picks = await this.fetchAll(await this.signIn());
      } catch (e) {
        // A token the backend no longer accepts (restart, new secret): sign in again once.
        if (!(e instanceof TeamError) || e.kind !== 'token refused') throw e;
        this.token = null;
        picks = await this.fetchAll(await this.signIn());
      }
      this.cached = { at: this.now(), picks };
      this.failed = null;
      return picks;
    } catch (e) {
      const error = e instanceof TeamError ? e : new TeamError('unexpected error');
      this.failed = { at: this.now(), error };
      this.log(`wish-picks: team backend unavailable (${error.kind}); using run history`);
      throw error;
    }
  }

  private async fetchAll(token: string): Promise<HouseholdPicks> {
    const [lists, suggestions, runouts] = await Promise.all([
      this.get('/v1/lists?status=open', token),
      this.get('/v1/wishlist/suggestions', token),
      this.get('/v1/forecasts/runouts?within=7d', token),
    ]);
    return mapHousehold(lists, suggestions, runouts, this.now());
  }

  /** A bearer token from dev login, reused until a minute before it expires. */
  private async signIn(): Promise<string> {
    if (this.token && this.now() < this.token.expiresAt - 60_000) return this.token.value;
    if (!this.config.password) throw new TeamError('no demo account configured');
    const body = await this.call('/v1/dev/login', {
      method: 'POST',
      headers: { 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({ handle: TEAM_HANDLE, password: this.config.password }),
    }, 'login refused');
    const value = isObj(body) && typeof body.access_token === 'string' ? body.access_token : '';
    if (!value || value.length > 4096) throw new TeamError('bad login response');
    const exp = isObj(body) && typeof body.expires_at === 'number' ? body.expires_at * 1000 : this.now() + 10 * 60_000;
    this.token = { value, expiresAt: exp };
    return value;
  }

  private get(path: string, token: string): Promise<unknown> {
    return this.call(path, { headers: { authorization: `Bearer ${token}`, accept: 'application/json' } }, 'token refused');
  }

  private async call(path: string, init: RequestInit, on401: string): Promise<unknown> {
    let res: Response;
    try {
      // No redirects: a password or token goes only to the configured origin.
      res = await this.fetchImpl(`${this.config.baseUrl}${path}`, {
        ...init,
        redirect: 'error',
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (e) {
      const name = (e as { name?: string } | null)?.name;
      throw new TeamError(name === 'TimeoutError' || name === 'AbortError' ? 'timeout' : 'network error');
    }
    if (res.status === 401 || res.status === 403) throw new TeamError(on401);
    if (!res.ok) throw new TeamError(`http ${res.status}`);
    try {
      const text = await res.text();
      if (text.length > MAX_BODY) throw new Error('too big');
      return JSON.parse(text) as unknown;
    } catch (e) {
      const name = (e as { name?: string } | null)?.name;
      throw new TeamError(name === 'TimeoutError' || name === 'AbortError' ? 'timeout' : 'bad response');
    }
  }
}

// ---- mapping (pure) ----

/** "2 bottles", "1 pack", "×4" (no unit), "" (one, no unit). */
export function itemDetail(quantity: unknown, unit: unknown): string {
  const q = typeof quantity === 'number' && Number.isFinite(quantity) && quantity > 0 && quantity <= 1000 ? quantity : null;
  const qs = q === null ? '' : String(Number.isInteger(q) ? q : Math.round(q * 100) / 100);
  const u = cleanText(unit, 20);
  const realUnit = u && !/^units?$/i.test(u) ? u : '';
  if (realUnit) return q === null ? realUnit : `${qs} ${realUnit}`;
  return q !== null && q !== 1 ? `×${qs}` : '';
}

/** "Running low · about 2 days left"; "Running low · probably out now" once it has run out. */
export function runoutReason(status: unknown, runoutAt: unknown, now: number): string {
  const at = typeof runoutAt === 'string' ? Date.parse(runoutAt) : NaN;
  const days = Number.isFinite(at) ? Math.ceil((at - now) / DAY) : NaN;
  if (status === 'out' || (Number.isFinite(days) && days <= 0)) return 'Running low · probably out now';
  if (!Number.isFinite(days)) return 'Running low';
  return `Running low · about ${days} ${days === 1 ? 'day' : 'days'} left`;
}

/** A suggestion's rationale cut to its first clause: "You finish 2% milk about every 6 days". */
export function shortReason(rationale: unknown): string {
  const text = cleanText(rationale, 400);
  const first = text.split(/[.;!?](?=\s|$)/)[0]?.trim() ?? '';
  return cleanSentence(first.length >= 8 ? first : text, 60);
}

/**
 * The backend's answers to what the wish page needs. Lists: open ones made by hand (`source` "user"),
 * with their unchecked items. Suggestions: run-outs first (soonest first, as sent), then the
 * wishlist's ranked suggestions. Anything malformed is skipped.
 */
export function mapHousehold(lists: unknown, suggestions: unknown, runouts: unknown, now: number): HouseholdPicks {
  const outLists: HouseholdList[] = [];
  for (const l of Array.isArray(lists) ? lists.slice(0, 100) : []) {
    if (!isObj(l) || l.source !== 'user' || l.status !== 'open') continue;
    const items = (Array.isArray(l.items) ? l.items : [])
      .filter((i): i is Obj => isObj(i) && i.checked === false)
      .map((i) => ({ name: cleanText(i.title, MAX_NAME), detail: itemDetail(i.quantity, i.unit) }))
      .filter((i) => i.name)
      .slice(0, 50);
    const updated = typeof l.updated_at === 'string' ? Date.parse(l.updated_at) : NaN;
    outLists.push({
      name: cleanText(l.name, MAX_NAME) || 'Shopping list',
      store: (isObj(l.merchant) && cleanText(l.merchant.name, 40)) || null,
      items,
      updatedAt: Number.isFinite(updated) ? updated : 0,
    });
  }

  const out: WishSuggestion[] = [];
  const runoutList = isObj(runouts) && Array.isArray(runouts.runouts) ? runouts.runouts : [];
  for (const r of runoutList.slice(0, 50)) {
    if (!isObj(r) || !isObj(r.item) || !isObj(r.forecast)) continue;
    const name = cleanText(r.item.display_name, MAX_NAME);
    if (name) out.push({ name, reason: runoutReason(r.forecast.status, r.forecast.runout_at, now) });
  }
  for (const s of Array.isArray(suggestions) ? suggestions.slice(0, 50) : []) {
    if (!isObj(s) || (s.status !== undefined && s.status !== 'suggested')) continue;
    const name = cleanText(s.title, MAX_NAME);
    if (name) out.push({ name, reason: shortReason(s.rationale) || 'Picked for your home' });
  }
  return { lists: outLists, suggestions: out };
}
