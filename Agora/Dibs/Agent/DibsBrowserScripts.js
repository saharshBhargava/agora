(() => {
  'use strict';
  const doc = Array.from(crypto.getRandomValues(new Uint8Array(16)), n => n.toString(16).padStart(2, '0')).join('');
  let sequence = 0, refs = new Map(), observation = '';
  const visible = e => { const s = getComputedStyle(e); return !e.closest('[hidden],[inert],[aria-hidden="true"]') && s.visibility !== 'hidden' && s.display !== 'none' && e.getClientRects().length > 0; };
  const label = e => (e.getAttribute('aria-label') || (e.getAttribute('aria-labelledby') || '').split(' ').map(id => document.getElementById(id)?.textContent || '').join(' ').trim() || Array.from(e.labels || []).map(l => l.textContent).join(' ') || e.getAttribute('placeholder') || e.innerText || e.getAttribute('title') || '').trim().slice(0, 180);
  const identity = e => [e.tagName, e.type, e.getAttribute('role'), label(e), e.getAttribute('href')].join('|');
  const privatePage = () => Array.from(document.querySelectorAll('input')).some(e => visible(e) && (['password', 'file'].includes(e.type) || /cc-|password|one-time-code/.test(e.autocomplete))) || /(?:login|sign[-_]?in|checkout|payment|oauth|authorize)/i.test(location.pathname);
  const check = () => { if (privatePage()) throw Error('user_action_required: Private page. Complete this step directly, then Resume.'); };
  const invalidate = () => { refs.clear(); observation = ''; };
  // Ported from Agora/Browser/BrowserScripts.js. Dibs runs it unattended, so a trusted event
  // only invalidates references (there is no human-takeover handler to notify).
  const hint = event => {
    if (!event.isTrusted) return;
    invalidate();
  };
  ['pointerdown', 'keydown', 'input', 'change'].forEach(name => document.addEventListener(name, hint, true));
  function observe() {
    check(); refs.clear(); observation = `${doc}:${++sequence}`;
    const candidates = Array.from(document.querySelectorAll('a[href],button,input,textarea,select,summary,[role="button"],[role="link"],[contenteditable="true"]')).filter(visible);
    const elements = candidates.slice(0, 100).map((e, i) => {
      const id = `e${i}`; refs.set(id, { node: e, identity: identity(e) });
      return { id, role: e.getAttribute('role') || e.tagName.toLowerCase(), name: label(e), type: e.type || '', disabled: !!e.disabled, editable: e.matches('input,textarea,[contenteditable="true"]') };
    });
    // Extract rendered text only; input values, HTML, storage and cookies are never serialized.
    let text = ''; const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
    while (walker.nextNode() && text.length <= 16000) {
      const n = walker.currentNode, e = n.parentElement;
      if (e && !e.closest('script,style,noscript,textarea,input,[contenteditable], [data-private]') && visible(e)) text += n.textContent.trim() + ' ';
    }
    return { documentId: doc, observationId: observation, title: document.title.slice(0, 300), text: text.slice(0,16000), elements,
      viewport: { width: innerWidth, height: innerHeight, scrollX, scrollY },
      truncated: { text: text.length > 16000, elements: candidates.length > 100 },
      limitations: ['Main-frame DOM only; shadow DOM and canvas controls unsupported.', ...(document.querySelector('iframe') ? ['unsupported_frame'] : [])] };
  }
  function act(r) {
    check();
    if (r.documentId !== doc || r.observationId !== observation || !observation) throw Error('stale_reference');
    if (r.action === 'scroll') { scrollBy(0, r.direction === 'up' ? -innerHeight * .75 : innerHeight * .75); invalidate(); return { dispatched: true }; }
    const saved = refs.get(r.elementId), e = saved?.node;
    if (!e || !e.isConnected || saved.identity !== identity(e) || !visible(e) || e.disabled) throw Error('stale_reference');
    if (e.matches('input[type="password"],input[type="file"]') || /cc-|password|one-time-code/.test(e.autocomplete || '')) throw Error('user_action_required');
    e.scrollIntoView({ block: 'center' });
    if (r.action === 'click') e.click();
    else if (r.action === 'focus') e.focus();
    else if (r.action === 'type' || r.action === 'clear') {
      if (!e.matches('textarea,input[type="text"],input[type="search"],input[type="email"],input[type="url"],input:not([type])') || e.readOnly) throw Error('unsupported_action');
      const proto = e.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto,'value').set.call(e, r.action === 'clear' ? '' : r.text);
      e.dispatchEvent(new Event('input',{bubbles:true})); e.dispatchEvent(new Event('change',{bubbles:true}));
    } else if (r.action === 'select') {
      if (!e.matches('select') || !Array.from(e.options).some(o => o.value === r.text)) throw Error('unsupported_action');
      e.value = r.text; e.dispatchEvent(new Event('change',{bubbles:true}));
    } else if (r.action === 'check' || r.action === 'uncheck') {
      if (!e.matches('input[type="checkbox"]')) throw Error('unsupported_action');
      if (e.checked !== (r.action === 'check')) e.click();
    } else throw Error('unsupported_action');
    invalidate(); return { dispatched: true, note: 'Event dispatched. Observe to verify the actual outcome.' };
  }
  globalThis.appBrowser = { dispatch(r) {
    try {
      if (r.operation === 'invalidate') { invalidate(); return { ok: true }; }
      if (r.operation === 'privacy') return { private: privatePage() };
      if (r.operation === 'observe') return observe();
      if (r.operation === 'act') return act(r);
      throw Error('unsupported_action');
    } catch (e) { return { error: String(e.message || e) }; }
  }};
})();
