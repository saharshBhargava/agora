# Vision and identification: edge-case test script

Run on the real iPhone with the debug launch (`-DibsAutoShop YES -DibsDebugCrops YES`). For each case, note the result and the `DIBS:` log lines. "Pass" is what a shopper would expect.

## Adding

| # | Do this | Pass |
|---|---|---|
| A1 | Put one item in an empty basket, let go | One row, named, then priced |
| A2 | Put two different items in at the same moment, side by side | Two rows |
| A3 | Put two identical items in, a minute apart | Two rows (merge window is 10 s) |
| A4 | Put a new item on top of an existing one (stacking) | One new row, the old one stays |
| A5 | Drop an item and pull it out within 1 s | Nothing added |
| A6 | Small item (gum, spice jar) | One row |
| A7 | Large item (paper towels, case of water) | One row, not split into several |
| A8 | Produce in a clear plastic bag | One row, sensible name |
| A9 | Transparent or shiny item (water bottle, clamshell) | One row |

## Removing and moving

| # | Do this | Pass |
|---|---|---|
| R1 | Take one item out | Its row disappears after about 2 s, with an undo toast |
| R2 | Take one of two identical items out | Exactly one row disappears |
| R3 | Slide an item to another spot | No new row, no removal |
| R4 | Take out the top item of a stack | Only the top item's row disappears |
| R5 | Reach in and hold your hand there for 5 s | Nothing added or removed |

## Things that should do nothing

| # | Do this | Pass |
|---|---|---|
| N1 | Bump or roll the cart (camera shifts) | No adds, no removals |
| N2 | Change the lighting or cast a shadow | No adds, no removals |
| N3 | Someone walks past behind the basket | No adds |
| N4 | Shelf items visible at the frame edge | No adds |

## Naming and pricing

| # | Do this | Pass |
|---|---|---|
| P1 | Coke vs Coke Zero vs Diet Coke | Correct variant named |
| P2 | Zucchini vs cucumber, loose produce | Correct produce named, priced per each |
| P3 | An item QFC doesn't carry | "No price found · Add price" within about 15 s |
| P4 | Gemini rate-limited or offline for a moment | Item retried and added once the service is back, not lost |
| P5 | Store prices | Prices match QFC University Village |
