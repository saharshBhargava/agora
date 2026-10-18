// Narrow local shim: cybersource-rest-client ships no typings.
declare module 'cybersource-rest-client' {
  type Callback = (error: unknown, data: any, response: any) => void;
  const CyberSource: {
    ApiClient: new () => { merchantConfig: unknown };
    PaymentsApi: new (config: unknown, client: unknown) => {
      createPayment(body: unknown, cb: Callback): void;
      incrementAuth(id: string, body: unknown, cb: Callback): void;
    };
    ReversalApi: new (config: unknown, client: unknown) => {
      authReversal(id: string, body: unknown, cb: Callback): void;
    };
    CaptureApi: new (config: unknown, client: unknown) => {
      capturePayment(body: unknown, id: string, cb: Callback): void;
    };
  };
  export default CyberSource;
}
