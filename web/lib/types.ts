// Types only, no imports: this file is copied verbatim into the web app.

export type RunState = 'open' | 'lastCall' | 'locked' | 'receipt' | 'settled' | 'partlySettled';

export type ChipState =
  | 'wish'
  | 'identifying'
  | 'open'
  | 'claimed'
  | 'locked'
  | 'matched'
  | 'unmatched'
  | 'settled'
  | 'removed';

export type Box = { x: number; y: number; w: number; h: number };

export type Chip = {
  id: string;
  name: string;
  priceCents: number | null;
  priceSource: 'sticker' | 'web' | 'receipt' | 'none';
  photoUrl: string | null;
  region: Box | null;
  /** How many of this item are in the cart (1 to 20). `priceCents` is the price of one. */
  quantity: number;
  /** The receipt's exact line total for this chip, tax included; once set it replaces priceCents × quantity. */
  receiptTotalCents?: number | null;
  /** When the camera last counted this item (ms); a re-detection within the merge window is the same item. */
  lastSeenAt?: number;
  /** Ordered by claim time. */
  claimers: string[];
  state: ChipState;
  wishedBy: string | null;
  duplicateOf: string | null;
  putBack: boolean;
  dropped: boolean;
  /** Person ids whose tray broke the rule when a price arrived. */
  overCap: string[];
  removedAt: number | null;
  /** When the chip was added (ms); drives the 5 second duplicate window. */
  addedAt: number;
};

export type Person = {
  id: string;
  name: string;
  initial: string;
  isShopper: boolean;
  authorizedCents: number | null;
  authId: string | null;
  /** Approval code from the authorization (or the latest incremental one). */
  approvalCode: string | null;
  payoutPan: string | null;
};

export type ReceiptLine = { text: string; cents: number; quantity: number; isTax: boolean };

export type ReceiptState = {
  lines: ReceiptLine[];
  matches: { chipId: string; lineIndex: number; confidence: number }[];
  unmatchedLines: number[];
  /** Lines the shopper claimed as their own. */
  mine?: number[];
  /** Each chip's count before the receipt changed it: how many items' worth of lines it may take. */
  cartQuantities?: Record<string, number>;
};

export type SettleStep = 'joined' | 'settling' | 'incremented' | 'reversed' | 'captured' | 'failed';

export type PersonSettle = {
  step: SettleStep;
  shareCents: number;
  capturedCents: number;
  releasedCents: number;
  owedCents: number;
  approvalCode: string | null;
  captureId: string | null;
  error: string | null;
};

export type PayoutRecord = {
  simulated: true;
  businessApplicationId: 'FD';
  amountCents: number;
  recipientPan: string;
  requestId: string;
};

export type Run = {
  id: string;
  state: RunState;
  store: string;
  shopperId: string;
  people: Person[];
  chips: Chip[];
  taxRate: number;
  lastCallEndsAt: number | null;
  receipt: ReceiptState | null;
  settle: Record<string, PersonSettle>;
  payout: PayoutRecord | null;
};
