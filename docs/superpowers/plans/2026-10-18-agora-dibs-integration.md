# Agora + Dibs integration (branch agora-dibs)

Goal: one iOS app. The team app (Agora) gains a Dibs tab, the whole app adopts the Dibs visual design, and Dibs uses the Agora sign-in for identity and the household's lists and suggestions. Main is not touched; this branch builds on `dibs-into-main` (origin/main + dibs-mock-demo side by side).

Decisions (user, 2026-10-18): one app with Dibs as a tab; merge the UI style to the Dibs style app-wide; the merged app is named **Dibs**; don't merge to main yet.

## Tasks
1. Port: move `ios/Dibs/**` into `Agora/Dibs/**` and its tests into `AgoraTests/` (flat, `Dibs` prefix), resolve name collisions, add the Dibs tab, Info.plist/xcconfig keys, a bundle-id/team override for personal signing, regenerate the project, both apps' tests green.
2. Design system: the Dibs tokens and components become the app-wide design (`Agora/Design/`); restyle the app shell, sign-in, Home, Settings.
3. Restyle the remaining Agora screens (Chat, Capture, Inventory, Lists/Trips, Wishlist/Shopping) to the Dibs design; behavior and tests unchanged.
4. Identity and wish bridge: the Dibs tab uses the signed-in Agora account (display name as shopper/claimer name; Agora bearer token sent to the Dibs server so wish-picks reads the user's own household lists and suggestions).
5. Verify: full Agora + Dibs tests, server/web suites, flash to the phone, two-account run inside the combined app.

Hosting and server stay as on dibs-mock-demo (laptop + tunnel for the demo).
