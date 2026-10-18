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
    async function waitFor(fn, ms) { const end = Date.now() + ms; while (Date.now() < end) { const v = fn(); if (v) return v; await sleep(250); } return null; }
    const modeButtons = () => Array.from(document.querySelectorAll('button,[role="button"],a')).filter(e => low(e.getAttribute('aria-label')).includes('change how you are shopping'));
    const modeButton = () => modeButtons().find(visible);
    // What the page actually shows, for the log when a step fails.
    const diagnose = () => {
      const buttons = Array.from(document.querySelectorAll('button,[role="button"]')).filter(visible)
        .map(b => norm(b.getAttribute('aria-label') || b.innerText).slice(0, 60)).filter(Boolean).slice(0, 10);
      const dialog = document.querySelector('[role="dialog"]');
      return 'url ' + location.origin + location.pathname + ', readyState ' + document.readyState + ', title "' + norm(document.title).slice(0, 80)
        + '", radios ' + document.querySelectorAll('input[type="radio"],[role="radio"]').length
        + ', hidden store buttons ' + modeButtons().filter(e => !visible(e)).length
        + ', dialog "' + norm(dialog ? dialog.innerText : 'none').slice(0, 160) + '"'
        + ', buttons [' + buttons.join(' | ') + ']'
        + ', body "' + norm(document.body ? document.body.innerText : '').slice(0, 300) + '"';
    };
    const headerText = e => norm((e.getAttribute('aria-label') || '') + ' | ' + (e.innerText || ''));
    """#

    /// Reads the header's shopping-mode button. Returns `{header}` or `{header: null}`.
    static let header = helpers + #"""
    const b = (await waitFor(modeButton, 3000)) || modeButtons()[0];
    return JSON.stringify({ header: b ? headerText(b) : null });
    """#

    /// Arguments: name, postalCode, address. Returns `{status: already|submitted|failed, step?, header?}`.
    /// The page may reload after Start Shopping, so the caller verifies the header afterwards.
    static let run = helpers + #"""
    const want = low(name), addrKey = low((address || '').split(' ')[0]);
    const fail = step => JSON.stringify({ status: 'failed', step: step + ' (' + diagnose() + ')' });
    // Up to 10 s for the header button (5 s, then again from the top of the page).
    let button = await waitFor(modeButton, 5000);
    if (!button) { window.scrollTo(0, 0); button = await waitFor(modeButton, 5000); }
    if (!button) button = modeButtons()[0];   // present but not laid out: clicking still opens the modal
    if (!button) return fail('store button');
    if (low((button.getAttribute('aria-label') || '') + ' ' + button.innerText).includes(want)) return JSON.stringify({ status: 'already', header: headerText(button) });
    const postal = e => /postal|zip/i.test([e.placeholder, e.getAttribute('aria-label'), e.name, e.id,
      Array.from(e.labels || []).map(l => l.textContent).join(' ')].join(' '));
    const postalInput = () => Array.from(document.querySelectorAll('input')).find(e => visible(e) && postal(e));
    // Before the page hydrates the button ignores clicks: click again every 3 s, up to 15 s.
    let input = null;
    for (let i = 0; i < 5 && !input; i++) {
      (modeButton() || modeButtons()[0] || button).click();
      input = await waitFor(postalInput, 3000);
    }
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
      // Untrusted Enter may not search: type again, then press the search button next to the field.
      // (No native form submit: it navigates the page away mid-script.)
      type(); await sleep(300); enter();
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

extension DibsBrowserToolExecutor {
    /// Switches the site's pickup store, or confirms it is already set: one attempt on a freshly
    /// loaded home page (the worker spaces out retries).
    func setStore(_ location: StoreLocation) async -> StoreSetupResult {
        guard let home = URL(string: "https://www.qfc.com/") else { return .failed("home url") }
        restrict(to: home)
        do { _ = try await session.open(home) } catch { return .failed("home page: \(error.localizedDescription)") }
        await settle()
        var result = await runStoreScript(location)
        if case .failed(let step) = result, step.contains("no longer reachable") {
            // The page navigated mid-script (a redirect or late reload): once more on the new page.
            PriceLog.event("price store page navigated during setup; running it again")
            await settle()
            result = await runStoreScript(location)
        }
        return result
    }

    /// Lets the page finish loading (up to 10 s) so its scripts handle clicks.
    private func settle() async {
        let deadline = ContinuousClock.now + .seconds(10)
        while session.webView.isLoading, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
        try? await Task.sleep(for: .milliseconds(500))
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
