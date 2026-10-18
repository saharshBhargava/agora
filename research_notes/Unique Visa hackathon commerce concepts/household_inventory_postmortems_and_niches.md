# Household Inventory & Auto-Replenishment: Post-Mortems, Under-Served Niches, Data Economics, UI Inspiration

Scope note: the assignment asked for "current as of October 2025." The search index used here returned several items dated 2026 (App Store listings, Ibotta earnings, a Yembo podcast). Those are flagged inline as "(dated 2026)" so the writer can decide whether to use them. Most status checks on small apps (Hiku, Ovie, Chefling, NoWaste, KitchenPal) could not be confirmed either way; see Gaps.

## Key Question 1: Post-mortem catalog — why did household inventory / replenishment products die or stall, and what exactly was the friction?

### Takeaway
Every product in this category died on one of three frictions: (a) data entry at the moment of consumption (you must tell the system when something is used up), (b) product recognition that doesn't work on packaged goods, or (c) a trust/price problem that made "automatic" reordering feel like a trap. A phone video walkthrough removes friction (b) for *shelf state* and partially (a) for *stock-take*, but it does not remove the consumption-event problem; it moves it from "log each use" to "re-scan periodically" and infers consumption by differencing. That is a real improvement only if the re-scan is cheap and the inference is good enough to be trusted.

### Cited Findings

**Amazon Dash Buttons (2015–2019)**
- Amazon stopped selling Dash buttons Feb 28, 2019; the service was fully ended at the end of August 2019 after a spokesperson told CNET use had "significantly slowed." — [TechSpot](https://www.techspot.com/news/78983-amazon-has-discontinued-dash-buttons.html); [Android Police](https://www.androidpolice.com/2019/03/01/amazon-kills-off-dash-buttons-but-existing-ones-will-continue-to-work/)
- Amazon's stated reasons: virtual Dash buttons in the app cost nothing to offer; Dash Replenishment embedded in appliances; growth of Alexa Shopping and Subscribe & Save. — [GearBrain](https://www.gearbrain.com/amp/amazon-dash-buttons-discontinued-2630354089); [PYMNTS](https://www.pymnts.com/amazon/2019/amazon-discontinues-physical-dash-buttons/)
- Slice Intelligence panel data: fewer than 50% of people who bought a Dash button ever placed an order with it; buyers were "a very small subset of the online shopping population." — [Chain Store Age](https://chainstoreage.com/news/analysis-consumers-not-rushing-amazon-dash)
- Price-trust friction, specific anecdote: a consumer dropped her Gatorade button after a 12-pack went from $9 to $22 between orders: "If I have to check on the price every time, it's not actually saving me time." — [Chain Store Age](https://chainstoreage.com/news/analysis-amazon-dash-not-yet-fast-track)
- GlobalData's failure case study: Amazon never created a "habit" that triggered a behavior and generated loyalty. — [GlobalData](https://www.globaldata.com/store/?p=1882964)
- Failory's post-mortem: one button per SKU implies hundreds of buttons for a real household; virtual buttons and DRS made the hardware redundant. — [Failory](https://www.failory.com/amazon/dash-buttons)
- A German court ruled against the buttons in early 2019 (consumer-law grounds); Amazon said the retirement was not because of that ruling. — [TechSpot](https://www.techspot.com/news/78983-amazon-has-discontinued-dash-buttons.html)

**Amazon Dash Replenishment Service (DRS) and Dash Smart Shelf**
- DRS continued after the buttons died; 2019 coverage notes Amazon still offered DRS on devices like printers plus digital Dash buttons in the app. — [Retail Dive](https://www.retaildive.com/news/amazon-ends-dash-button-sales/549618)
- Dash Smart Shelf (announced Nov 2019): a weight-sensing Wi-Fi scale in three sizes (7x7, 12x10, 18x13 in), $20, four AAA batteries, initially for Amazon Business supply rooms with up to 15% discounts on auto-reordered items, later sold to consumers. — [TechHive](https://www.techhive.com/article/578913/amazon-s-dash-smart-shelf-automatically-reorders-supplies-when-you-re-running-low.html); [The Recycler](https://therecycler.com/posts/meet-the-amazon-dash-shelf/); [Adweek](https://www.adweek.com/?p=1101790)
- Weight sensing is notable because it is the one approach that measures *consumption* rather than *presence*; it was the architectural successor to the button, not the camera.

**Samsung Family Hub / AI Vision Inside (smart fridge cameras)**
- Consumer Reports' early test of the ~$5,800 Family Hub: the shelf cameras "don't show everything and can easily be blocked by a tall bottle of orange juice"; smart features were hard to set up; execution lagged the concept. — [Consumer Reports](https://www.consumerreports.org/french-door-refrigerators/samsung-family-hub-refrigerator-review/)
- Owner reports of interior-view staleness after firmware updates (images one and six days old) and black screens with a ~$1,200 repair quote. Single anecdotes. — [SmartThings community](https://community.smartthings.com/t/samsung-family-hub-camera-door-view/295877); [Samsung EU community](https://eu.community.samsung.com/t5/home-appliances/inside-fridge-picture-not-working/td-p/1920720)
- Samsung's AI Vision Inside identifies ~33 types of fresh food and cannot reliably distinguish cilantro from parsley; the same piece argues fridges last 10–15 years while camera software stops getting updates, and humidity degrades anti-fog coatings. — [Ponderworthy](https://ponderworthy.com/buying-a-fridge-with-camera-inside-is-it-actually-worth-the-hype-rlx)
- Structural argument: reliably tracking packaged food would have required cooperation among all packaged-food makers (standardized machine-readable packaging), which never happened. — [Philip Greenspun blog, 2024](https://philip.greenspun.com/blog/2024/04/09/why-isnt-chatgpt-inside-our-refrigerators/)
- Wikipedia's overview notes camera-based fridge inventory has mostly remained in proposal/research stage; a 2021 IEEE study tested multi-camera CNN inventory. — [Wikipedia: Smart refrigerator](https://en.wikipedia.org/wiki/Smart_refrigerator)

**Smarter FridgeCam (retrofit camera) and Chefling**
- Expert Reviews, after two weeks of testing: "the software has failed to recognise a single item," including well-known branded products placed in front of the lens; manual tagging called tedious; maker's answer was that recognition would improve as users tagged items. — [Expert Reviews](https://www.expertreviews.co.uk/home-garden/large-appliances/smarter-fridgecam-review)
- Tech Advisor: connection problems and fiddly setup; "doesn't deliver on it yet." — [Tech Advisor](https://www.techadvisor.com/article/719327/smarter-fridgecam-review.html)
- Which?: door-open alert never fired in tests; "too much work for the payoff." — [Which?](https://www.which.co.uk/news/article/is-it-worth-buying-a-fridge-camera-aNLE02N0tb1Z)
- Jan 2023: Smarter launched FridgeCam2 and FridgeCam Pro (for appliance OEMs) at CES and acquired Chefling (pantry inventory + shopping list + meal planning software). — [The Spoon](https://thespoon.tech/fridge-cam-maker-smarter-launches-new-models-at-ces-announces-acquisition-of-chefling/)

**Ovie Smarterware**
- Kickstarter-origin "Connected Food Storage System": LED tags on containers that change color as food ages, Alexa integration; Chicago-based. — [TechRadar](https://www.techradar.com/news/amazon-alexa-enabled-tupperware-tells-you-when-its-time-to-throw-out-food); [Built In Chicago](https://www.builtinchicago.org/company/ovie-smarterware)
- Friction visible in the design: each tag must be pressed and the food named when a container is filled, i.e., per-event manual entry at the moment of storage. (Inference from product description; see Inferences.)

**Hiku scanner**
- $80 Wi-Fi handheld barcode scanner + mic (2013) that added items to a grocery list; Waitrose planned a UK rollout via its incubator. — [Engadget](https://www.engadget.com/2013/10/24/hiku-handheld-barcode-scanner-for-groceries/); [Retail Week](https://www.retail-week.com/technology/waitrose-to-launch-hiku-home-scanner-as-part-of-new-incubator-programme/5065178.article)
- Friction: a dedicated $80 device whose only job is to make the user scan an empty package before throwing it away — the consumption event still requires a deliberate user action.

**Out of Milk**
- Out of Milk's developer Capigami was acquired by InfoScout (receipt-data company) June 19, 2014; InMarket later owned it and in 2021 terminated international accounts after July 21, 2021. — [Crunchbase: Capigami](https://crunchbase.com/organization/capigami); [Liliputing](https://liliputing.com/?p=143166)
- The acquirers were both consumer-purchase-data companies, which is the first direct evidence in this catalog that the value of a grocery-list app was the purchase signal, not the list.

**Whisk / Samsung Food**
- Samsung NEXT acquired Whisk in March 2019; rebranded to Samsung Food Aug 30, 2023; 160,000+ recipes, 100+ countries; Bespoke Family Hub fridges surface Samsung Food recipes; search results mention a "use in-stock ingredients" mode but no standalone pantry-tracking feature. — [9to5Google](https://9to5google.com/2023/08/30/whisk-samsung-food-app-rebrand/); [TechCrunch](https://techcrunch.com/2023/08/30/samsung-launches-a-meal-planning-and-recipe-discovery-platform-called-samsung-food); [SamMobile](https://www.sammobile.com/news/whisk-app-renamed-samsung-food/)

**Grocy (open source)**
- Self-hosted "ERP beyond your fridge," MIT license, maintained as a hobby project by Bernd Bestel; barcode fields fillable via USB scanner or phone camera; Open Food Facts lookup plugin. — [GitHub: grocy/grocy](https://github.com/grocy/grocy)
- LinuxLinks: "once products, barcodes, and locations are set up, day-to-day use can be fast" — i.e., heavy upfront master-data setup is the friction. — [LinuxLinks](https://www.linuxlinks.com/grocy-erp-beyond-fridge/)
- AlternativeTo reviews (5 reviews, 4.0): "most of the things is not configurable in the GUI"; "too complicated in a couple of workflows." — [AlternativeTo](https://alternativeto.net/software/grocy/about)

**Pantry Check and the current pantry-app long tail**
- Pantry Check (JOJO Apps): 4.5/5 from 161 ratings; manual quantity/unit/category entry; a different app with the same name (Sunroom Labs) is barcode-first. — [App Store: Pantry Check](https://apps.apple.com/us/app/id6670480023); [App Store: Pantry Check - Grocery List](https://apps.apple.com/us/app/pantry-check-grocery-list/id966702368)
- New entrants pitch directly against manual entry: PantryKeep ("snap a photo of your grocery receipt and let AI add every item," no ratings yet). — [App Store: PantryKeep](https://apps.apple.com/us/app/pantrykeep/id6777104608)

**Walmart InHome**
- $19.95/month, delivery into fridge/garage; expansion announced from 6M to 30M US households (announcement year not visible in excerpt; this was a 2022 announcement per coverage pattern — verify). Walmart and Microsoft discussed "automated replenishment" as a future InHome upgrade with no launch date announced. — [CNBC via NBC New York](https://www.nbcnewyork.com/news/business/money-report/walmart-expands-its-direct-to-fridge-inhome-delivery-service-to-30-million-homes/3479734/); [Supermarket News](https://www.supermarketnews.com/grocery-technology/walmart-further-expanding-inhome-delivery)

### Inferences
- The frictions are distinct and should be named separately in the product thesis:
  1. **Consumption-event logging** (Dash button, Hiku, Ovie tag, Grocy "consume" action, Out of Milk): the user must do something at the exact moment an item is used up. This is the dominant killer; nobody sustains it. Dash Smart Shelf's weight sensor is the only mass-market attempt to sense consumption passively.
  2. **Recognition failure on packaged goods** (FridgeCam, Family Hub, AI Vision Inside's ~33 fresh-food classes): 2017–2024 CV did not work on dense, occluded, branded packaging in a fridge. This is the friction most changed by 2024–2026 VLMs, and the one a video walkthrough attacks directly.
  3. **Trust in auto-reorder** (Dash price jump, German court): consumers want to see the price before money moves. Any "auto-replenish" must show a priced cart, not silently purchase.
  4. **Hardware obsolescence vs. appliance lifespan** (Family Hub): a 15-year fridge with 3-year software support is structurally wrong; phone-based approaches sidestep this.
  5. **Master-data setup** (Grocy): power tools die on configuration before first value.
- A video walkthrough **does** remove (2) and (4), and (5) if the model names and locates items without setup. It **does not** remove (1): a video is a snapshot of presence, not an event stream. Consumption can only be inferred by differencing two walkthroughs (rate = delta / time), which means the product needs a cheap habitual re-scan cadence (weekly) and should be honest that it estimates burn rate rather than records it. It **partially** removes (3) only if the output is a priced, editable cart rather than a purchase.
- Out of Milk being bought twice by receipt-data companies suggests the revenue in this category has historically been the purchase signal, not the consumer subscription (ties to Key Question 4).

### Gaps
- Could not confirm the current operating status of Hiku (believed shut down), Ovie Smarterware, Smarter Applications/FridgeCam, or Chefling post-acquisition; no shutdown notices surfaced in search.
- No sources found on NoWaste, Kitchen Pal, or Grocery TrackER specifically (status, reviews, or why they stalled).
- No LG ThinQ-specific inventory critique or adoption data found; no independent reliability survey of Family Hub cameras.
- No confirmation of whether Dash Smart Shelf or Dash Replenishment Service was discontinued after 2019; a 2024 shutdown rumor could not be verified.
- Walmart InHome current (2025) status and whether automated replenishment ever launched: not found. No Instacart "smart reorder" or Amazon Fresh reorder analysis found.
- No Verge/Wired/Ars long-form smart-fridge post-mortem surfaced in search despite the suggested-sources list.

## Key Question 2: Does video-based household inventory already exist? How do home-insurance inventory apps work and monetize?

### Takeaway
Yes, in two forms: (a) 2026-vintage consumer pantry apps (Shelfze, Pantry AI, Pantrio) that scan a shelf from a short video or photo, with no independent reviews yet; and (b) a mature B2B2C insurance/moving category (Yembo, Encircle, HomeZada since 2018, Scanlily, ClaimProof, Bevel) that turns a phone walkthrough into an itemized inventory. The insurance side monetizes through carriers, adjusters, restoration contractors, and moving companies — not consumers — and tracks durable goods with replacement values, not consumables with burn rates. Nobody found combines the two: video-derived inventory of *consumables* with *consumption rate* and payment.

### Cited Findings

**Consumer pantry-from-video apps (all developer-marketing claims, no independent reviews; dated 2026)**
- Shelfze (iOS): "Photo & Video Modes" — record a quick video to scan the entire shelf, extracts products and expiration dates; first released Jan 12, 2026. — [App Store: Shelfze](https://apps.apple.com/app/id6755694325)
- Pantry AI (iOS): AI visual scanning adds items, expiry alerts, storage-location tracking; v1.0.23, first release Feb 20, 2026. — [mwm.ai: Pantry AI](https://mwm.ai/apps/pantry-ai/6758572123)
- Pantrio (iOS): camera scanning of fridge/pantry items for recipes; first release May 1, 2026. — [mwm.ai: Pantrio](https://mwm.ai/apps/pantrio-ai/6763900379)
- AislePrompt (browser): single shelf photo "can yield 30+ items"; photo scanning needs no account. — [AislePrompt](https://aisleprompt.com/ai-pantry-scanner)
- EverShelf (open source, self-hosted): AI expiry tracking via user-supplied Gemini API key. — [Unraid apps: EverShelf](https://ca.unraid.net/apps/evershelf-0zbuofx02y7et5)
- None of these listings claim consumption-rate estimation, multi-person attribution, or payment.

**Academic / technical precedent**
- arXiv 2312.12486 (IEEE WI-IAT 2023): home grocery tracking model trained on retail shelf data + fruit datasets + "real-time 360 view data points collected from home grocery storage"; notes grocery tracking models for homes are rare. — [arXiv 2312.12486](https://arxiv.org/abs/2312.12486v1)
- UKM (Malaysia) study: YOLOv4 on custom household food dataset on a single-board computer, 93% reported accuracy, Telegram low-stock alerts. — [UKM journal PDF](https://ukm.my/jkukm/wp-content/uploads/2024/3605/06.pdf)
- Freiburg Groceries Dataset: 5,000 images, 25 grocery classes, collected in stores and apartments (classification, not detection). — [arXiv 1611.05799](https://www.arxiv.org/pdf/1611.05799)
- ShelfScanner (IEEE 2010): online detection of shopping-list items in video streams, store shelves. — [IEEE Xplore](https://ieeexplore.ieee.org/document/5543576)

**Insurance / moving video-inventory (B2B2C, mature)**
- Yembo: computer vision turns "a ten minute phone walkthrough into a full home inventory, 3D model, and floor plan"; deployed in 35 countries; serves moving companies and property insurers (podcast dated July 2026). — [Built This Week podcast](https://podcastaddict.com/built-this-week/episode/227523482)
- Yembo: 350+ customers across moving and insurance; $8.5M Series A (2021, Imagen Capital Partners), ~$20M total per one source vs $13.22M per another; expanding from moving to insurance to home services. — [Coverager](https://coverager.com/yembo-raises-8-5-million/); [San Diego Business Journal](https://sdbj.com/technology/software/yembo-partners-with-atlas-van-lines/); [CB Insights](https://www.cbinsights.com/company/yembo)
- Encircle (Kitchener, ON, founded 2012): field documentation (photos, video, sketches, notes, signatures) for restoration contractors, adjusters, underwriters, TPAs, carriers; Matterport 3D integration; ~$1.5M total funding per Craft. Consumer version free, unlimited items for up to two properties, PDF/Excel export. — [Encircle platform](https://getencircle.com/encircle-platform); [Craft.co](https://craft.co/getencircle); [Matterport news](https://matterport.com/news/encircle-improves-productivity-restoration-contractors-integrating-matterport); [ValuePenguin](https://valuepenguin.com/homeowners-insurance-inventory-checklist)
- HomeZada launched "Home Inventory Video Recognition AI" in 2018: users record and upload videos of each room and exterior; freemium. — [HomeZada press](https://homezada.com/press/homezada-launches-home-inventory-video-recognition-ai)
- Scanlily (iOS): "AI Video Inventory" from a narrated video; fields for RCV, ACV, comparable pricing for claims. — [App Store: Scanlily](https://apps.apple.com/app/1627766472)
- ClaimProof (iOS): room-by-room narrated video walkthroughs plus item catalog with serial numbers and purchase dates. — [App Store: ClaimProof](https://apps.apple.com/us/app/claimproof/id6761318890)
- Bevel: AI inventory for insurance documentation, founded after the Palisades Fire. — [NBC San Diego](https://www.nbcsandiego.com/nbc-7-responds-2/new-app-uses-ai-to-help-people-track-their-belongs-in-case-of-a-disaster-heres-how/3905836/)
- Claims AI (Houston) hired Kanda (June 2024) to build an app covering picture recognition through claim submission. — [Kanda](https://kandasoft.com/news/kanda-and-claims-ai-begin-work-to-develop-home-inventory-app-for-simplified-insurance-claims)
- Sortly (general small-business inventory, often listed as a home inventory app): Free (100 items, 1 user), Advanced $49/mo (500 items, 2 users, barcode/QR scanning, low-stock alerts), Ultra $149/mo (2,000 items, 5 users, purchase orders), Premium $299/mo (QuickBooks), Enterprise custom; ~50% off annually; 89% of reviewers are small businesses. — [Capterra: Sortly pricing](https://capterra.com/p/169199/Sortly-Pro/pricing/); [CostBench](https://costbench.com/software/inventory-management/sortly/)

### Inferences
- The insurance category proves (i) consumers will do a 10-minute narrated walkthrough when the payoff is concrete and rare (a claim), and (ii) the money is on the institution side (carrier/adjuster/mover pays per job or per seat). It does *not* prove consumers will re-scan weekly; those apps are built for a one-time or annual capture of durables.
- The consumer pantry-video apps that launched in 2026 show the recognition problem is now considered solvable with VLMs, but their feature lists (expiry alerts, recipes) are the same 2018 feature set with a better input method. None differentiates on consumption rate, attribution to people, or commerce. That is the open space.
- "Pantry scan" and "insurance inventory" have never been one product because they track different object classes (consumables vs. durables) for different buyers (self vs. insurer). A household-inventory-from-video app could plausibly do both captures from the same walkthrough and monetize the durable half via insurer/mover partnerships while the consumable half drives commerce.

### Gaps
- No independent review or accuracy benchmark of any 2026 video-pantry app (Shelfze, Pantry AI, Pantrio).
- Encircle's and Yembo's actual pricing/contract model (per-claim, per-seat, carrier license) not disclosed in any source found.
- No source on whether any US insurer gives a premium discount for using an inventory app; ValuePenguin only notes insurers offer free inventory forms.
- Itemtopia, Nest Egg, Memento: not surfaced in search; status unknown.

## Key Question 3: Under-served segments and settings where "what's in the house and how fast it's used" is high-value and done badly

### Takeaway
The segments with the clearest, sourced pain are those where inventory is tied to *multiple people and money* (roommates/shared houses; short-term-rental hosts restocking many units; small restaurants doing manual weekly counts; small food pantries on spreadsheets) and where consumption is *measurable but currently self-reported* (3D-printing filament, where Spoolman shows hobbyists will automate consumption logging when the printer can report it). Remote eldercare has a plausible need but only indirect products (Avanlee + Walmart). Sizing data for most segments was not found.

### Cited Findings

**Shared houses / roommates / dorms**
- Mainstream guidance pairs Splitwise (log each purchase, assign to people, compute who owes whom monthly) with a shared list app like OurGroceries; the "who used the last of the milk" problem is addressed by *avoiding* it ("you buy what you use" — separate oat milk vs almond milk, split or rotate staples). — [Mozo](https://www.mozo.com.au/bank-accounts/articles/five-online-tools-and-apps-every-aussie-living-in-a-sharehouse-needs); [Uniplaces](https://www.uniplaces.com/city-explorer/meal-planning-with-roommates-your-guide-to-shared-grocery-success/); [Gerald](https://joingerald.com/learn/money-basics/how-to-split-expenses-with-roommates)
- Split-Mate (GitHub hobby project) combines communal shared-supplies list with purchase splitting — evidence of unmet demand built by users themselves. — [GitHub: split-mate](https://github.com/HudsonGri/split-mate)
- No existing tool found that attributes *consumption* (as opposed to *purchase*) to a person; Splitwise splits the receipt, not the usage.

**Short-term-rental hosts / small landlords**
- Conduit (vendor) argues flat restock schedules fail because consumption varies with stay length and party size: "A six-person stay for a week and a solo two-nighter consume completely differently. A flat restock schedule overstocks half the portfolio and starves the other half." It projects draw-down from the booking calendar and folds restocks into the next cleaning turn. — [Conduit: STR supplies](https://conduit.ai/industry/short-term-rentals/supplies)
- Typical consumables: toiletries, cleaning supplies, coffee/tea/oil; management companies (Awning, RedAwning) sell restocking as a service with "regular inventory checks and bulk purchasing." — [RedAwning](https://pm.redawning.com/post/short-term-rental-inventory-management-automating-supplies-for-airbnb-and-vacation-homes); [Awning](https://awning.com/airbnb-management-services/airbnb-supplies-restocking)
- Current state is calendar-based estimation or paid humans; a cleaner's 30-second video of the supply closet at each turnover is a natural capture moment that no source describes any product using.

**Small restaurants / bars (back of house)**
- Vendor claims (unverified, no named survey): managers spend 15–20 hours/week on manual inventory tasks; the physical count alone takes 4–6 hours. — [SynergySuite](https://www.synergysuite.com/?p=13266)
- Zebra (RFID vendor): manual data entry up to 80 minutes/week; RFID cuts a count from 2.7 hours to 15–30 minutes. — [Zebra infographic PDF](https://www.zebra.com/content/dam/zebra_dam/en/infographic/hospitality-infographic-qsr-rfid-en-us.pdf)
- CrunchTime: one operator moved from a 4-hour monthly count to 1 hour weekly; weekly counts reduce errors. — [CrunchTime](https://www.crunchtime.com/blog/6-inventory-management-tips-from-leading-restaurant-brands)
- Dineopen: most restaurants do a full count weekly on the same day; many still on spreadsheets. — [Dineopen](https://www.dineopen.com/blog/restaurant-inventory-sheet)

**Church / community food pantries**
- PantrySoft targets pantries "frustrated by outdated spreadsheets and manual processes"; case study is a New Jersey church pantry. — [PantrySoft](https://pantrysoft.com/)
- FoodCopia (Canada) used by Saskatoon Food Bank, Wood Buffalo Food Bank, soon Food Banks Alberta, to track donated goods by category. — [CJWW Radio](https://www.cjwwradio.com/?p=213903)
- Guides for small pantries still recommend a shared Google Sheet with same-day donation logging and a weekly shelf check. — [Simular guide](https://www.simular.ai/workflow/how-to-build-a-pantry-inventory-in-sheets-excel-guide)

**Hobbyist consumables (3D printing as the proof case)**
- Spoolman (open source, Donkie on GitHub): central filament inventory (color, manufacturer, material, remaining weight, location); integrates with OctoPrint, Moonraker, Mainsail, Fluidd, KlipperScreen, Home Assistant so "total filament used is reported to Spoolman automatically." Bambu Lab announced a commercial competitor, Filametrics. — [OctoEverywhere setup guide](https://blog.octoeverywhere.com/spoolman-3d-printer-filament-inventory-management-setup-guide/); [Fabbaloo](https://www.fabbaloo.com/?p=229306)
- Lesson: hobbyists adopt inventory tracking when consumption is logged *by the machine*, not by them. For art supplies, chalk, tackle, LEGO parts there is no machine to report usage — these were not researched further (see Gaps).

**Remote caregiving for an elderly parent**
- Avanlee Care + Walmart (announced June 2022): adult children place Walmart grocery deliveries to a parent's home from the same app that tracks medication adherence and mood; delivery tracking "gives caregivers confidence that their relative has the food they need." — [Drug Store News](https://drugstorenews.com/walmart-avanlee-care-help-families-coordinate-grocery-needs-aging-loved-ones); [PLMA](https://plma.com/article/walmart-partners-senior-care-app-delivery)
- Silver Mother (older product) used motion sensors on pill bottles and refrigerators for remote check-ins. — [The Glass Room](https://www.theglassroom.org/object/tactical_tech_la_loma_silver_mother_nl/)
- Caregiving guides recommend scheduled recurring deliveries so a parent "never runs out," i.e., replenishment without inventory visibility. — [Care Options for Kids](https://careoptionsforkids.com/blog/how-online-grocery-shopping-can-improve-distance-caregiving/)

**Disaster recovery / insurance**
- Covered in Key Question 2 (Bevel founded after Palisades Fire; Encircle, Yembo, ClaimProof). The pain is acute, episodic, and already served by B2B2C tools.

### Inferences
- The "feels new, not smart-fridge-again" test is: does the setting have (a) more than one person or unit, (b) money attached to consumption, and (c) a natural existing moment to point a phone at a shelf? Segments passing all three: STR hosts (cleaner at turnover; cost per unit; many units), shared houses (roommates; split costs; weekly shop), small restaurants/bars (weekly count already happens; COGS), food pantries (volunteers; donated stock; weekly check). Segments failing (c): remote eldercare (the parent must do the scan or accept a camera) and most hobbies (no recurring capture moment).
- Roommate attribution is the most novel angle because nothing exists; but a video cannot see *who* consumed. Attribution would have to come from a different signal (who scanned, who paid, self-report) — be honest that video gives shared burn rate, and the ledger splits it by rule, not by observation.
- Restaurant and STR vendor numbers are all from companies selling alternatives; use as directional only.

### Gaps
- No market-size source found for any segment (number of US shared households, STR units with hosts self-restocking, home daycares, co-ops).
- Home daycares, students moving in/out, new parents (diapers/formula), pet owners, minimalists: not researched due to call budget; no sources.
- No independent (non-vendor) survey of restaurant inventory hours.
- Link2Feed (food pantry software) did not appear in results.
- No data on how many STR hosts self-manage restocking vs. outsource.

## Key Question 4: Does any merchant pay for consumption signals today? Fetch/Ibotta economics and what receipt or inventory data is worth

### Takeaway
Yes, at scale: CPG brands pay Fetch and Ibotta for receipt-verified purchase behavior and for promotions targeted on it. Fetch reports a $500M revenue run rate (Q4 2024) on ~13M receipts/day and $152B of transactions scanned annually; Ibotta earns ~$0.79–0.83 of revenue per third-party-publisher redemption. No source found puts a price on *inventory* or *consumption-rate* data specifically; what is sold today is purchase (receipt) data and redemption-based promotion. A consumption signal that precedes the purchase (e.g., "household X is 3 days from running out of Y") would be upstream of what Fetch sells and has no established price.

### Cited Findings
- Fetch's partners (CPG brands, retailers, restaurants) pay affiliate commissions/referral fees for featuring products, driving sales, and access to anonymized purchasing data; Fetch also earns interchange from Fetch Pay. — [FourWeekMBA](https://fourweekmba.com/how-does-fetch-rewards-make-money/); [ProductMint](https://productmint.com/fetch-rewards-business-model-how-does-fetch-rewards-make-money/)
- Fetch: $500M annual revenue run rate in Q4 2024, up 65% YoY; profitable since Q4 2023; $50M from MSPC after profitability. — [Eaton Vance / MSPC press release](https://www.eatonvance.com/insights/press-release/fetch-secures-50m-from-mspc-after-achieving-profitability-signaling-strong-growth.html); [Cap Times](https://captimes.com/news/business/fetch-rewards-app-turns-first-profit-and-prepares-for-hypergrowth/article_0b7f96ee-e6eb-11ee-ab03-3b5325b56fc4.html)
- Fetch scale: $152B+ of transactions annually; ~18M MAU, 6M DAU; >13M receipts/day (2026 profile). — [FourWeekMBA](https://fourweekmba.com/how-does-fetch-rewards-make-money/); [Unanswered.io](https://unanswered.io/guide/fetch-rewards-company-overview-revenue-valuation-ownership)
- Fetch valuation $2.5B (2022). A claimed $700M gross revenue run rate (July 2026) appears in one source only, uncorroborated. — [Dealroom](https://app.dealroom.co/companies/fetch); [yespress.io](https://yespress.io/fetch.md)
- Brand example: General Mills added 2M customers to its Good Rewards loyalty program via Fetch in six months. — [Digital Commerce 360](https://www.digitalcommerce360.com/2023/10/04/infographic-general-mills-incentivizes-customers-through-mobile-app-fetch/)
- Fetch privacy reviews characterize the model as selling consumer data to brands ("zero-party data"). — [terms.law](https://terms.law/Privacy-Watchdog/cashback-apps/fetch/)
- Ibotta S-1: "a significant portion of … redemption revenue arises from offer redemptions on third-party publishers"; CPG brands also buy display, video, and email ad products; stated goal is a larger share of CPG marketing spend. — [SEC: Ibotta S-1](https://www.sec.gov/Archives/edgar/data/1538379/000162828024012708/ibottas-1.htm)
- Ibotta third-party-publisher revenue per redemption: $0.79 (Q1 2025, vs $0.80), $0.79 (Q3 2025, vs $0.78), $0.83 (Q2 2026, flat YoY); Q2 2026 third-party publisher redemptions 74.4M (+27%), third-party publisher revenue $61.5M, total revenue $88.9M (+3%); DoorDash launched as a publisher in Q2 2025. — [Silicon UK Q1 2025](https://www.silicon.co.uk/press-release/ibotta-reports-first-quarter-2025-financial-results); [BusinessWire Q3 2025](https://www.businesswire.com/news/home/20251112661377/en/Ibotta-Reports-Third-Quarter-2025-Financial-Results); [StreetInsider Q2 2026](https://www.streetinsider.com/Press+Releases/Ibotta+Reports+Second+Quarter+2026+Financial+Results/26857891.html)
- Historical precedent: Out of Milk (grocery list app) was acquired by InfoScout (receipt panel) in 2014, later owned by InMarket (location/purchase data). — [Crunchbase: Capigami](https://crunchbase.com/organization/capigami)

### Inferences
- The going rate for a *verified purchase event* delivered to a CPG brand is roughly $0.80 (Ibotta's third-party publisher revenue per redemption), plus whatever the brand funds as the consumer reward. That is the benchmark a hackathon pitch can cite for "what a commerce-impact signal is worth."
- A household inventory that infers "running low on X" is a *pre-purchase intent* signal, which is rarer than post-purchase receipt data and could be sold as a targeted offer slot (brand pays to be the replenishment default) rather than as raw data. Ibotta's publisher model (DoorDash, Walmart, Instacart surfaces run Ibotta offers) suggests the app could be a *publisher* of CPG offers at the moment of predicted stock-out without building a brand sales force.
- Receipt scanning already exists as a trusted consumer habit (13M receipts/day at Fetch); a video walkthrough is a heavier ask with no reward loop. Pairing shelf video with receipt capture gives both inflow (receipt) and stock (shelf), which is the minimum needed to compute burn rate.

### Gaps
- No source quantifies what brands pay for NielsenIQ or Numerator panel data per household or per receipt; no source prices "inventory" or "consumption" data as distinct from purchase data.
- Fetch does not disclose revenue mix (data vs. promotions vs. interchange); figures above are run-rates and company claims.
- CB Insights lists an implausible "$135B" 2025 revenue for Fetch; treat as a data error.

## Key Question 5: UI inspiration — what Mobbin offers and which real apps have best-in-class patterns for inventory, ledger, marketplace/bid-ask, and scanning

### Takeaway
Mobbin is a paid library of ~621,500 real screens organized into Screens, Flows, UI patterns, and website sections, filterable by app, platform, industry, and category; it has a Finance+ add-on (60+ fintech apps). Confirmed relevant Mobbin flows: Copilot Money (dashboard, onboarding, recurring, bank-linking), StockX (add item to portfolio). Splitwise and Vivino appear only as single screens. No inventory, scanning, or marketplace category was visible on public pages. The best pattern sources from primary docs are StockX's bid/ask + lowest-ask + Current/Pending/History grouping and Splitwise's three-tab you-owe / you-are-owed / total ledger with red/green coloring.

### Cited Findings
- Mobbin: 621,500 screens, added weekly; organized into Screens, Flows (onboarding, checkout, account setup, subscription), UI patterns/elements (dialogs, navigation, forms, tables, empty states, paywalls), and website sections; search across apps, web apps, screen text, patterns; filters by product, platform, industry, category. Tiers: Free (limited), Pro (full library + MCP), Team (collab + REST API), Enterprise. Finance+ add-on (Team/Enterprise): 60+ investment, banking, crypto apps including flows behind KYC walls. No shopping/marketplace/scanning/inventory categories named on the homepage. — [Mobbin](https://mobbin.com)
- Mobbin flows found: Copilot Money iOS Dashboard (13 screens), Onboarding (27 screens), Linking a bank account (10 screens), Investments, Investment account detail, Bank account detail, Recurring Dashboard screen; StockX Android "Adding an item to portfolio" (8 screens). — [Mobbin: Copilot Dashboard](https://mobbin.com/explore/flows/56546256-d565-4196-9949-469f50d925e8); [Mobbin: Copilot Onboarding](https://mobbin.com/explore/flows/bec90a3f-1c1b-490a-b27d-8445cc6e62a7); [Mobbin: Copilot Recurring](https://mobbin.com/explore/screens/bec12df5-c54e-4c3f-8de0-903c0586b3e8); [Mobbin: Copilot bank linking](https://mobbin.com/explore/flows/69754f25-77e5-4e57-8236-69cc0283b997); [Mobbin: StockX portfolio](https://mobbin.com/explore/flows/25377f38-584b-4449-8601-267e1570c968)
- Splitwise appears on Mobbin only as an iOS login screen in the login-examples list; Vivino only in login and "My Account & Profile" (4,388 screens category). — [Mobbin: login screens](https://mobbin.com/explore/mobile/screens/login)
- StockX pattern (primary): sellers place Asks, buyers place Bids, sale executes when they meet; product page shows lowest Ask and "buy now" at it; Selling tab groups listings into Current / Pending / History; green = your Ask is lowest, red = a lower Ask exists; real-time highest bid, lowest ask, sales history, price trend. — [StockX: A Sneaker Stock Market (2016)](https://stockx.com/news/a-sneaker-stock-market/); [StockX help: Sell Now vs Ask](https://stockx.com/help/articles/what-is-the-difference-between-sell-now-and-an-ask); [Sharetribe](https://www.sharetribe.com/create/how-to-build-website-like-stockx/)
- Splitwise pattern: simple ledger; home has three tabs (you owe, you are owed, total balance); green = owed to you, red = you owe; "Plus 2 other balances" label for multi-currency criticized as conflicting with mental models; critiques flag missing friend search and unlabeled filter icon; split logic supports equal, exact, percentage. — [Pratt IXD critique 2017](https://ixd.prattsi.org/2017/09/design-critique-splitwise-ios-app/); [Pratt IXD critique 2026](https://ixd.prattsi.org/2026/02/design-critique-splitwise-mobile-app/); [Pratt IXD critique 2020](https://ixd.prattsi.org/2020/02/design-critique-splitwise-android-app/); [TechInterview LLD](https://techinterview.org/lld-splitwise-expense-sharing/)
- Mobius Materials (B2B excess-components marketplace) bid mechanics worth borrowing for a consumables marketplace: bids are binding and cannot be withdrawn or lowered; seller counters are binding; bids are per-unit USD; a listing can be simultaneously "Open for Bids," "In Auction" (timer + reserve), and fixed-price "eCommerce." — [Mobius docs: binding bid](https://docs.mobiusmaterials.com/en/articles/16775476-what-is-a-binding-bid); [Mobius bids platform](https://www.mobiusmaterials.com/post/introducing-the-mobius-bids-platform-a-better-way-to-sell-excess-electronic-components)
- Sortly (inventory UI reference, small business): folder/photo-first item cards, QR/barcode label generation, low-stock alerts, purchase orders at higher tiers. — [Capterra: Sortly](https://capterra.com/p/169199/Sortly-Pro/pricing/)
- Encircle/Yembo (scan-walkthrough UI reference): room-by-room narrated video capture; Yembo outputs inventory + 3D model + floor plan from a 10-minute walkthrough. — [Built This Week podcast](https://podcastaddict.com/built-this-week/episode/227523482); [Encircle platform](https://getencircle.com/encircle-platform)

### Inferences
- For a hackathon, Mobbin Pro is needed to see Flows (search, flows, animations are paywalled); the free tier shows screens only. The Finance+ add-on is overkill unless KYC-walled payment flows are needed.
- Pattern mapping for a household-inventory-from-video app:
  - **Inventory/stock view**: Sortly's photo-card folders + Copilot Money's "Recurring" dashboard (recurring items with next-due date is structurally identical to "next run-out date").
  - **Ledger/attribution**: Splitwise's three-tab balance with red/green, but replace "expenses" with "consumption shares"; avoid the "Plus N other balances" collapse the critics flagged.
  - **Marketplace/bid-ask for replenishment**: StockX's lowest-Ask "buy now" + Current/Pending/History list, where merchants post Asks against a household's predicted stock-out and the household's standing Bid (max price) auto-executes — this directly answers the Dash price-trust failure because the price ceiling is user-set.
  - **Scan**: Encircle/Yembo narrated-walkthrough capture (room-by-room progress indicator), and Vivino-style instant label recognition for single items.
- Robinhood-style tickers for "price of your household basket" is a plausible borrow but no source was gathered; treat as unsourced idea.

### Gaps
- Mobbin's public pages do not expose inventory, scanning, or marketplace categories; could not confirm whether Sortly, Grailed, Vivino scan, Monarch, or Splitwise flows exist behind the paywall.
- No design-blog deep-dive on bid/ask UI beyond StockX's own material and a Sharetribe how-to; no Grailed or Robinhood pattern analysis gathered.
- No Monarch Money or Vivino scan-flow sources collected.
