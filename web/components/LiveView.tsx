'use client';

/** The latest relayed frame with a live dot and the shopper's name. Used small on the claimer screen. */
export function LiveView({ frame, shopperName, small }: { frame: string | null; shopperName: string; small?: boolean }) {
  return (
    <div className={`liveview${small ? ' liveview-small' : ''}`}>
      {frame ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={frame} alt={`${shopperName}'s cart, live`} draggable={false} />
      ) : (
        <p className="muted liveview-wait">Waiting for the cart</p>
      )}
      <span className="liveview-tag"><span className="watching-dot" aria-hidden="true" />live · {shopperName}</span>
    </div>
  );
}
