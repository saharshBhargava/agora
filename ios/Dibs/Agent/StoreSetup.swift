import Foundation

/// The store QFC prices at. QFC prices differ per store, and the site defaults to another one.
struct StoreLocation: Codable, Sendable, Equatable, Hashable {
    /// As the site shows it in the header: "Pickup at University Village".
    let name: String
    let postalCode: String
    /// Street address, used to tell stores with similar names apart ("2746 NE 45th St").
    var address: String? = nil

    static let universityVillage = StoreLocation(name: "University Village", postalCode: "98105", address: "2746 NE 45th St")
}

enum StoreSetupResult: Equatable, Sendable {
    /// The header already named the store (cookies from an earlier launch).
    case already
    /// The scripted flow switched the store and the header now names it.
    case set
    case failed(String)

    var ok: Bool { self == .already || self == .set }
}

/// Scripted "change how you are shopping" flow on qfc.com, run in the store browser's content world:
/// header button → "Start Your Shopping Trip" modal → postal code → the store's row → Start Shopping.
enum StoreSetupScript {
    /// Shared helpers (prepended to both scripts).
    private static let helpers = #"""
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const norm = s => (s || '').replace(/\s+/g, ' ').trim();
    const low = s => norm(s).toLowerCase();
    const visible = e => { if (!e) return false; const s = getComputedStyle(e); return s.visibility !== 'hidden' && s.display !== 'none' && e.getClientRects().length > 0; };
    async function waitFor(fn, ms) { const end = Date.now() + ms; while (Date.now() < end) { const v = fn(); if (v) return v; await sleep(200); } return null; }
    const modeButton = () => Array.from(document.querySelectorAll('button,[role="button"],a')).find(e => visible(e) && low(e.getAttribute('aria-label')).includes('change how you are shopping'));
    const headerText = e => norm((e.getAttribute('aria-label') || '') + ' | ' + (e.innerText || ''));
    """#

    /// Reads the header's shopping-mode button. Returns `{header}` or `{header: null}`.
    static let header = helpers + #"""
    const b = await waitFor(modeButton, 3000);
    return JSON.stringify({ header: b ? headerText(b) : null });
    """#

    /// Arguments: name, postalCode, address. Returns `{status: already|submitted|failed, step?, header?}`.
    /// The page may reload after Start Shopping, so the caller verifies the header afterwards.
    static let run = helpers + #"""
    const want = low(name), addrKey = low((address || '').split(' ')[0]);
    const fail = step => {
      const dialog = document.querySelector('[role="dialog"]');
      const radios = document.querySelectorAll('input[type="radio"],[role="radio"]').length;
      return JSON.stringify({ status: 'failed', step: step + ' (radios ' + radios + ', dialog: ' + norm(dialog ? dialog.innerText : 'none').slice(0, 160) + ')' });
    };
    const button = await waitFor(modeButton, 12000);
    if (!button) return fail('store button');
    if (low(button.innerText).includes(want)) return JSON.stringify({ status: 'already', header: headerText(button) });
    button.click();

    const postal = e => /postal|zip/i.test([e.placeholder, e.getAttribute('aria-label'), e.name, e.id,
      Array.from(e.labels || []).map(l => l.textContent).join(' ')].join(' '));
    const input = await waitFor(() => Array.from(document.querySelectorAll('input')).find(e => visible(e) && postal(e)), 10000);
    if (!input) return fail('postal code input');
    await sleep(600);   // let the modal finish mounting before typing
    const type = () => {
      input.focus();
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, postalCode);
      input.dispatchEvent(new Event('input', { bubbles: true }));
      input.dispatchEvent(new Event('change', { bubbles: true }));
    };
    const enter = () => { for (const t of ['keydown', 'keypress', 'keyup'])
      input.dispatchEvent(new KeyboardEvent(t, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true })); };
    type();
    await sleep(300);
    enter();

    // The store's radio: the one whose own row (holding no other radio) names the store and address.
    const findRadio = () => {
      for (const r of document.querySelectorAll('input[type="radio"],[role="radio"]')) {
        let c = r;
        for (let i = 0; i < 8 && c.parentElement; i++) {
          c = c.parentElement;
          if (c.querySelectorAll('input[type="radio"],[role="radio"]').length > 1) break;
          const t = low(c.innerText);
          if (t.includes(want) && (!addrKey || t.includes(addrKey))) return r;
        }
      }
      return null;
    };
    let radio = await waitFor(findRadio, 3000);
    if (!radio) {
      // Untrusted Enter may not submit: type again, then submit the form or press the search button.
      type(); await sleep(300); enter();
      if (input.form && input.form.requestSubmit) { try { input.form.requestSubmit(); } catch (e) {} }
      const scope = input.closest('[role="dialog"]') || document;
      const search = Array.from(scope.querySelectorAll('button')).find(b => visible(b) && /search/i.test((b.getAttribute('aria-label') || '') + ' ' + b.innerText));
      if (search) search.click();
      radio = await waitFor(findRadio, 15000);
    }
    if (!radio) return fail('store row');
    const label = radio.labels && radio.labels[0];
    (label || radio).click();
    await sleep(300);

    const start = await waitFor(() => Array.from(document.querySelectorAll('button')).find(b => visible(b) && !b.disabled && low(b.innerText) === 'start shopping'), 5000);
    if (!start) return fail('start shopping');
    start.click();
    return JSON.stringify({ status: 'submitted' });
    """#
}

extension BrowserToolExecutor {
    /// Switches the store browser's pickup store, or confirms it is already set. A failed script
    /// (seen once in three live runs: a page script threw mid-flow) gets one retry on a fresh home page.
    func setStore(_ location: StoreLocation) async -> StoreSetupResult {
        guard let home = URL(string: "https://www.qfc.com/") else { return .failed("home url") }
        var result = StoreSetupResult.failed("not run")
        for attempt in 1...2 {
            if attempt == 2 || !session.isOpen {
                restrict(to: home)
                guard (try? await session.open(home)) != nil else { result = .failed("home page"); continue }
            }
            result = await runStoreScript(location)
            if result.ok || Task.isCancelled { return result }
            PriceLog.event("price store script attempt \(attempt) failed: \(result)")
        }
        return result
    }

    private func runStoreScript(_ location: StoreLocation) async -> StoreSetupResult {
        do {
            let args: [String: Any] = ["name": location.name, "postalCode": location.postalCode, "address": location.address ?? ""]
            let result = try await session.evaluate(StoreSetupScript.run, arguments: args, timeout: .seconds(45))
            switch result["status"] as? String {
            case "already": return .already
            case "submitted": break
            default: return .failed(result["step"] as? String ?? "script")
            }
            // Start Shopping may reload the page: read the header until it names the store.
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if let header = try? await session.evaluate(StoreSetupScript.header, arguments: [:], timeout: .seconds(6))["header"] as? String,
                   header.localizedCaseInsensitiveContains("at \(location.name)") {
                    return .set
                }
            }
            return .failed("header check")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
