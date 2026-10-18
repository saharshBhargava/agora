// Standalone Cybersource sandbox gate. Not part of the app and not run by tests.
// Run: CYBS_MERCHANT_ID=.. CYBS_KEY_ID=.. CYBS_SHARED_SECRET=.. pnpm -C server exec tsx scripts/payments-gate.ts
import CyberSource from 'cybersource-rest-client';

const merchantID = process.env.CYBS_MERCHANT_ID;
const merchantKeyId = process.env.CYBS_KEY_ID;
const merchantsecretKey = process.env.CYBS_SHARED_SECRET;
if (!merchantID || !merchantKeyId || !merchantsecretKey) {
  console.error('Missing credentials: set CYBS_MERCHANT_ID, CYBS_KEY_ID and CYBS_SHARED_SECRET (see .env.example).');
  process.exit(1);
}

const config = {
  authenticationType: 'http_signature',
  runEnvironment: 'apitest.cybersource.com',
  merchantID,
  merchantKeyId,
  merchantsecretKey,
  enableLog: false,
};
const client = new CyberSource.ApiClient();
const payments = new CyberSource.PaymentsApi(config, client);
const reversals = new CyberSource.ReversalApi(config, client);
const captures = new CyberSource.CaptureApi(config, client);

type Step = { ok: boolean; status: string; id: string; processor: string; detail: string };

function call(fn: (cb: (e: unknown, d: any, r: any) => void) => void): Promise<Step> {
  return new Promise((resolve) => {
    fn((error, data, response) => {
      const body = data ?? (() => { try { return JSON.parse(response?.text ?? '{}'); } catch { return {}; } })();
      const code = response?.status ?? response?.statusCode;
      resolve({
        ok: !error,
        status: String(body?.status ?? code ?? 'ERROR'),
        id: String(body?.id ?? ''),
        processor: String(body?.processorInformation?.processor?.name ?? 'n/a'),
        detail: error ? String(body?.message ?? body?.reason ?? (error as Error)?.message ?? error) : '',
      });
    });
  });
}

function print(label: string, s: Step): void {
  console.log(`${label}: ${s.ok ? 'OK' : 'FAIL'} status=${s.status} id=${s.id || '-'} processor=${s.processor}${s.detail ? ` detail=${s.detail}` : ''}`);
}

async function main(): Promise<void> {
  const auth = await call((cb) =>
    payments.createPayment(
      {
        clientReferenceInformation: { code: 'gate-1' },
        processingInformation: { capture: false, authorizationOptions: { authIndicator: '0' } },
        orderInformation: {
          amountDetails: { totalAmount: '40.00', currency: 'USD' },
          billTo: {
            firstName: 'Test', lastName: 'Dibs', address1: '1 Market St', locality: 'San Francisco',
            administrativeArea: 'CA', postalCode: '94105', country: 'US', email: 'test@example.com',
          },
        },
        paymentInformation: { card: { number: '4111111111111111', expirationMonth: '12', expirationYear: '2031' } },
      },
      cb,
    ),
  );
  print('authorize 40.00 (pre-auth)', auth);
  if (!auth.ok || !auth.id) {
    console.log('RAISE_CAP=off (authorization failed; fix credentials or account before relying on the result)');
    process.exit(2);
  }

  const inc = await call((cb) =>
    payments.incrementAuth(
      auth.id,
      {
        clientReferenceInformation: { code: 'gate-1-inc' },
        orderInformation: { amountDetails: { additionalAmount: '5.00', currency: 'USD' } },
      },
      cb,
    ),
  );
  print('incremental +5.00', inc);
  // Authorized total in cents: 40.00, plus 5.00 only if the increment landed.
  const authorizedCents = 4000 + (inc.ok ? 500 : 0);
  const captureCents = 436;
  const reverseStr = ((authorizedCents - captureCents) / 100).toFixed(2);

  const rev = await call((cb) =>
    reversals.authReversal(
      auth.id,
      {
        clientReferenceInformation: { code: 'gate-1-rev' },
        reversalInformation: { amountDetails: { totalAmount: reverseStr }, reason: 'partial release of unused hold' },
      },
      cb,
    ),
  );
  print(`partial reversal ${reverseStr}`, rev);

  const cap = await call((cb) =>
    captures.capturePayment(
      {
        clientReferenceInformation: { code: 'gate-1-cap' },
        orderInformation: { amountDetails: { totalAmount: '4.36', currency: 'USD' } },
      },
      auth.id,
      cb,
    ),
  );
  print('capture 4.36', cap);

  console.log(`\nprocessor: ${auth.processor}`);
  const settleOk = rev.ok && cap.ok;
  console.log(`SETTLE_FLOW=${settleOk ? 'ok' : 'broken'}`);
  console.log(`RAISE_CAP=${inc.ok && settleOk ? 'on' : 'off'}`);
  if (!settleOk) {
    console.log('WARNING: reversal and/or capture failed. The settle design itself (reverse the unused hold, capture exact shares) is NOT supported by this sandbox account. Do not proceed with PAYMENTS=cybersource.');
  }
}

main().catch((e) => {
  console.error('gate failed:', e instanceof Error ? e.message : e);
  process.exit(1);
});
