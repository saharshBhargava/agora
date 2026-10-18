# Agora + Dibs integration (branch agora-dibs)

Goal: one iOS app built around the Dibs loop (start or join a run, stream the cart, claim, split, settle). The team app's features (lists, inventory, wishlist, suggestions, chat, capture) are supporting pieces that feed the run, the whole app adopts the Dibs visual design, and Dibs uses the Agora sign-in for identity and the household's lists and suggestions. Main is not touched; this branch builds on `dibs-into-main` (origin/main + dibs-mock-demo side by side).

Decisions (user, 2026-10-18): one app; merge the UI style to the Dibs style app-wide; the merged app is named **Dibs**; don't merge to main yet. Revised the same day: "the key component is the loop we designed in dibs, the stuff in agora is ancillary to the key loop" — so the app is Dibs-first, not Agora with a Dibs tab.

## Shape (old Dibs UI is the core)
Revised again the same day: "shift it back to the core ui of old dibs and figure out a way to add the new stuff". No tab bar; the app is the old Dibs flow with the team features added as entries on its home.
- The app opens on the **Dibs home** exactly as before (gear, wordmark, tagline, "Join with a link" card, "Start a run"), inside one NavigationStack, light scheme. No sign-in gate; a typed name is enough, and the signed-in account's name prefills it.
- New on the home, between the tagline and the join card, in Dibs cards:
  - **For your next run**: the household's running-low items, wishlist and suggestions (the old Agora Home cards), a few lines each.
  - **Your household**: rows that push Dibs-styled screens: **Lists** (shopping lists, trips), **Pantry** (inventory, with "Scan items" opening Capture), **Wishlist** (wishlist + watch list + suggestions), **Assistant** (chat). Signed out, the card is one line and a "Sign in" button instead.
- The gear opens one Settings sheet: the Dibs server/store settings plus Account (sign in/out), Models, Preferences, Connected accounts, Autonomy, Spending limits.
- Inside a run nothing changes, except the "+ Wish" page also offers the household's lists and suggestions (Task 4).
- The home scrolls; "Start a run" stays pinned at the bottom.
- The old standalone Dibs (dev.dibs.app) stays on the phone as the fallback; this app installs as dev.ansonchen.agora, labeled "Dibs New" locally.

## Tasks
1. Port: move `ios/Dibs/**` into `Agora/Dibs/**` and its tests into `AgoraTests/` (flat, `Dibs` prefix), resolve name collisions, add the Dibs tab, Info.plist/xcconfig keys, a bundle-id/team override for personal signing, regenerate the project, both apps' tests green.
2. Shell: the root becomes the Dibs home (no tab bar, no launch gate) with the two new cards and the combined Settings sheet; the Dibs tokens and components become the app-wide design; sign-in becomes a pushed Dibs-styled screen; the old Agora Home and tab bar are removed.
3. Restyle the remaining Agora screens (Chat, Capture, Inventory, Lists/Trips, Wishlist/Shopping, Calendar) to the Dibs design; behavior and tests unchanged.
4. Identity and wish bridge: Run uses the signed-in Agora account (display name as shopper/claimer name; Agora bearer token sent to the Dibs server so wish-picks reads the user's own household lists and suggestions).
5. Verify: full Agora + Dibs tests, server/web/backend suites, simulated two-person runs in the combined app (shopper on a simulator with the debug fixtures, claimer on a second simulator and on the web), screenshots of every screen, then flash "Dibs New" to the phone beside the old Dibs. The live camera scan with the phone in hand is the one case left for Anson.

Hosting and server stay as on dibs-mock-demo (laptop + tunnel for the demo).
