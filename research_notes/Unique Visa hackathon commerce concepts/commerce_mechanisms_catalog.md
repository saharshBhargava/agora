# Pre-AI Commerce and Market Mechanisms Transplantable into a Household-Purchasing App

Research date: 2026-10-17. Scope: real-world, pre-AI market mechanisms (auctions, aggregation, savings circles, surplus markets, replenishment contracts, resale, price protection, loyalty, local commerce, price-locks, household bookkeeping, commitment devices) that could be the *core idea* of a household-purchasing mobile app that already knows what a household owns and consumes (video walkthrough + consumption tracking) and can pay via Visa. Status labels used below: **THRIVING**, **NICHE**, **MECHANISM ABANDONED**, **DEAD**.

Note on method: roughly 35 searches/fetches were run. Several topics on the brief (milkman model, bodega tabs/credit, mutual-aid pantries, kakeibo, Instacart "reorder", Samsung Family Hub, CamelCamelCamel, Esusu's current product) returned no reliable sources and are listed under Gaps rather than asserted.

## Catalog: 22 concrete mechanisms (how it works, where used, why it works, named example with numbers, household-app sketch)

### Takeaway
The mechanisms with the strongest evidence of changing buyer behavior or merchant economics are (a) membership-funded wholesale (Costco), (b) merchant-funded card-linked offers (Cardlytics/Honey), (c) social group-buying (Pinduoduo), (d) surplus/near-expiry markets (Too Good To Go, Flashfood), (e) B2B vendor-managed inventory, and (f) pre-commitment defaults (Save More Tomorrow). The documented failures cluster around consumer-side replenishment hardware (Dash buttons, Juicero), tipping-point group deals (Groupon), name-your-own-price (Priceline), card-issuer price protection (Citi, Discover, Capital One/Paribus) and a gift-economy app (Buy Nothing).

### Cited Findings

#### 1. Reverse auction / Name-Your-Own-Price (NYOP) — DEAD at Priceline
- How it works: consumer submits a binding bid for an opaque product; Priceline "worked by buying the ticket at the airline's bid price, reselling it to the consumer at his or her bid price, and pocketing the difference." — [Columbia CaseWorks](https://caseworks.business.columbia.edu/caseworks/pricelinecom)
- Priceline discontinued NYOP for flights on September 1, 2016, citing "a dramatic evolution in both technology and customer behaviour when it comes to booking travel," replacing it with Express Deals (no bidding). — [Skift](https://skift.com/?p=196057); [Trefis](https://www.trefis.com/stock/pcln/articles/375685/why-did-priceline-discontinue-its-name-your-own-price-option-for-flight-bookings/2016-09-06)
- Hotel bidding ended ~2019–2020 (sources conflict on exact date); a Harvard case blog says NYOP's share of revenue declined over time, citing hotel supply concerns, without numbers. — [RSM Digital Strategy](https://digitalstrategy.rsm.nl/2016/10/02/name-your-own-price-for-flight-is-now-history/); [Harvard RCTOM](https://d3.harvard.edu/platform-rctom/submission/priceline-outperforming-the-online-travel-agency-business-globally/index.html)
- Household sketch: a household posts a sealed "intent" (e.g., "I will buy 12 rolls of paper towel this month at ≤ $X"); merchants fill it or not. Lesson from Priceline: opacity and effort killed it once price transparency became free — only works where the buyer is indifferent to brand (true for many consumables).

#### 2. Social group buying with price ladder (Pinduoduo "team purchase") — THRIVING
- Mechanism: shopper picks a solo price or a lower team price; invites contacts via WeChat/QQ; price falls as more join; group must fill within 24 hours or the buy is cancelled; no paid advertising, relying on word-of-mouth. — [TechCrunch 2018](https://techcrunch.com/2018/07/26/the-incredible-rise-of-pinduoduo); [DAO Insights](https://daoinsights.com/works/pinduoduos-social-group-buying-model-wins-over-tier-3-4-consumers/)
- Scale: twelve-month GMV $163.4B as of March 31 (2020), over 628 million annual active buyers, 5.1 million merchants; 55% of its netizens in Tier 3/4 cities; 2019 Tier 4 penetration 35.34% vs Taobao's 31.50%. — [DAO Insights (Aug 28, 2020)](https://daoinsights.com/works/pinduoduos-social-group-buying-model-wins-over-tier-3-4-consumers/)
- ~788 million annual active buyers in 2020; company stopped disclosing GMV, last figure ~RMB 1.67 trillion. — [Garnet Marketplace profile](https://garnetmarketplace.com/marketplaces/pinduoduo.html)
- Why it works economically: the buyer does the merchant's customer acquisition; merchants trade margin for guaranteed volume; agricultural program had 680,000+ merchants, 2.33 billion orders, RMB 65.3 billion revenue. — [DAO Insights](https://daoinsights.com/works/pinduoduos-social-group-buying-model-wins-over-tier-3-4-consumers/)
- Household sketch: the app knows 40 nearby households all run low on the same detergent in the same week → auto-forms a "team" without anyone sharing links; the social-sharing step that drove Pinduoduo is replaced by inventory-derived demand clustering.

#### 3. Tipping-point daily deals (Groupon) — MECHANISM ABANDONED
- A study of a major Korean daily-deal site found the tipping point did not boost voucher sales and likely deterred new customers from buying immediately; "both Groupon and the Korean daily deal site abandoned the use of the tipping point and modified redemption rules." — [Journal of Interactive Marketing / SAGE](https://journals.sagepub.com/doi/full/10.1016/j.intmar.2015.12.001)
- Hu & Winer found tipping-point information increased purchase probability and speed but did not encourage referrals; "recent changes made by Groupon are inconsistent with our empirical results." — [IJRM via IDEAS](https://ideas.repec.org/a/eee/ijrema/v34y2017i1p120-136.html)
- New customers redeemed vouchers quickly and overwhelmed small merchants; refund-handling and customer-service failures; LivingSocial held 20–25% of the market before Groupon absorbed it for a token price in 2016. — [SAGE](https://journals.sagepub.com/doi/full/10.1016/j.intmar.2015.12.001); [Robins School case](https://robins.richmond.edu/files/Robins-Case-Network/2025/Groupon.pdf)
- Loss-leader model worked only while local merchants lacked cheap customer-acquisition channels; Google/Yelp removed that scarcity. — [The Growth Playbook](https://thegrowthplaybook.substack.com/p/how-groupon-became-the-fastest-growing)
- Household sketch: lesson, do not expose a "deal is on if N people join" threshold to the buyer; use aggregated demand silently and show a firm price.

#### 4. Membership-funded wholesale (Costco) — THRIVING; bulk-online clone (Boxed) — DEAD
- Membership fees ≈ 2% of revenue ($4.8B on $250B net sales FY2024) but a majority of operating income: "over half" of $9.3B FY2024 operating income; an older analyst estimate was ~75%. — [Motley Fool](https://www.fool.com/investing/2024/12/01/costco-sales-250-billion-fiscal-2024-member-fee); [Marketplace 2016](https://www.marketplace.org/story/2016/09/29/costco-earnings); [Nasdaq](https://www.nasdaq.com/articles/global-indexes/costco-wholesale)
- FY2026 operating income $11.7B with membership fees 50.6% of it (third-party blog analysis). — [Beancount blog](https://beancount.io/blog/2026/09/26/costco-fy2026-earnings-analysis)
- The $1.50 hot-dog combo "unchanged since 1985" is cited as the visible symbol of Costco's pricing discipline. — [Beancount blog](https://beancount.io/blog/2026/09/26/costco-fy2026-earnings-analysis)
- Boxed (online bulk) filed Chapter 11 on April 2, 2023 with up to $102.6M assets and $190.4M liabilities; had rejected a $400M Kroger offer in 2018; most cash was at Silicon Valley Bank. — [Bloomberg via BNN](https://www.bnnbloomberg.ca/online-wholesale-retailer-boxed-files-for-chapter-11-bankruptcy-1.1903669); [Modern Retail](https://www.modernretail.co/operations/what-went-wrong-at-bulk-delivery-service-boxed/)
- Household sketch: a flat household membership fee funds near-cost pricing; the app's inventory data decides *which* SKUs to buy in bulk (and when) rather than making the user guess, which Boxed never had.

#### 5. ROSCAs / chit funds and fintech savings circles — THRIVING informally; NICHE as fintech
- ROSCA definition and list of formalized products (incl. Esusu founded in New York by ex-Goldman/PwC/LinkedIn employees). — [Wikipedia: ROSCA](https://en.wikipedia.com/wiki/ROSCA)
- India chit funds are regulated under the Chit Funds Act, 1982, with a registrar in every state; registered-industry estimates range from ~Rs 10,000 crore (2013) to >Rs 35,000 crore/yr; unregistered sector claimed to be ~100× larger (industry-association figure, unverified). — [Business Standard 2011](https://www.business-standard.com/article/finance/after-mfi-turmoil-chit-funds-the-next-big-draw-112040700026_1.html); [Deccan Herald](https://www.deccanherald.com/business/how-chit-funds-are-driving-financial-inclusion-in-india-760000.html); [Business Standard 2010](https://www.business-standard.com/amp/article/finance/unregistered-chit-funds-having-a-field-day-110072500020_1.html)
- StepLadder (UK, founded 2016) runs ROSCA-style circles for home deposits, using open banking and credit-bureau data to assign members to circles. — [FinTech Futures](https://www.fintechfutures.com/fintech/rosca-is-there-a-potential-for-entering-developed-markets-)
- MoneyFellows (Egypt) ~150,000 customers, raised $4M; Circlys (Saudi) digitizes ROSCAs to reduce failure risk. — [FinTech Futures](https://www.fintechfutures.com/fintech/rosca-is-there-a-potential-for-entering-developed-markets-); [Arab News](https://www.arabnews.com/node/1599996/)
- Household sketch: a "furniture circle" — 10 households each pay $100/month to a shared pot via Visa; one household receives the $1,000 sofa each month in rotation; the app's walkthrough identifies who actually needs the big-ticket item and can order the rotation by need.

#### 6. Layaway / save-to-buy → replaced by BNPL — layaway DEAD at Walmart, BNPL THRIVING
- Walmart's 2021 holiday season was the first without layaway; replaced with Affirm (3–24 month terms, APRs 10–30%, some 0% promos). Old layaway: no interest, $10 cancel fee, $10 or 10% down. Walmart cited declining usage. — [WSLS](https://www.wsls.com/features/2021/09/24/walmart-says-goodbye-to-layaway-offers-new-buy-now-pay-later-payment-option); [Clark.com](https://clark.com/personal-finance-credit/walmart-ditches-layaway-in-favor-of-affirm/); [NWA Online](https://www.nwaonline.com/news/2021/sep/28/layaway-has-gone-away-at-walmart/)
- Household sketch: "save-to-buy" for a desk the walkthrough flagged as missing: the app earmarks small recurring Visa transfers into a locked sub-balance and executes the purchase when funded — the old layaway promise (no interest, no debt) with the merchant's price locked at commitment time.

#### 7. Gift economy / hyperlocal free exchange (Buy Nothing, Freecycle, Olio) — groups THRIVING, Buy Nothing app FLOPPED
- Buy Nothing began as a Facebook group on Bainbridge Island, WA; founders' attempt to fundraise from the community was rejected ("meant to avoid money"), they then pitched "upwards of 100" VCs, could not raise enough for a robust app, producing "a poor-quality app and an angry community"; some local groups split and renamed. — [Marketplace, May 16 2023](http://www.marketplace.org/story/2023/05/16/what-happened-to-the-buy-nothing-project)
- The app had only ~91,000 regular users; most local groups stayed on Facebook. — [Boston Globe, Mar 2023](https://www.bostonglobe.com/2023/03/19/business/welcome-buy-nothing-revolution/)
- Buy Nothing's own current claims: 13M neighbors, 2.6M gifts/month, 245K communities, 14K volunteers. — [Buy Nothing Project docs](https://docs.buynothingproject.org/)
- In Nov 2025 a large SF Buy Nothing-named Facebook group was removed via an automated trademark takedown, part of a purge of groups not registered with the official project. — [SF Standard](https://sfstandard.com/2025/11/07/buy-nothing-group-facebook-taken-down-trademark-infringment/)
- Freecycle: >5,000 local groups. — [DC Reuse](https://reuse.dc.gov/node/1605916)
- Olio: raised $43M Series B (Sept 2021), ~5M users then (80% UK, half joined in pandemic), stated goal of 1B users by 2030; earns from partner stores and premium users; later self-reported 7M+. — [Sifted](https://sifted.eu/articles/olio-raises-43m); [The Grocer](https://thegrocer.co.uk/news/food-waste-app-olio-raises-43m-to-boost-global-growth/659542.article); [Great Campaign](https://greatcampaign.com/unicorn-kingdom/olio-app/)
- Household sketch: the walkthrough identifies unused/duplicate items; app lists them as free "gifts" to neighbors *before* it suggests any purchase — but keep money out of the gift lane (Buy Nothing lesson) and monetize only the purchase lane.

#### 8. Surplus / near-expiry marketplaces (Too Good To Go, Flashfood) — THRIVING
- Too Good To Go: ~157 million meals saved worldwide in 2025 (2025 Impact Report), 423,859 t CO2e avoided; Italy 7.8M meals (+13%); Portugal 1.69M (+7%); US 8.1M meals in first seven months of 2025 (+67% YoY). — [RetailDetail](https://www.retaildetail.eu/news/food/too-good-to-go-will-save-157-million-meals-by-2025/); [DoctorWine](https://www.doctorwine.wine/pot-pourri-en/wine-world-news/in-2025-too-good-to-go-saved-7-8-million-meals/?lang=en); [Grande Consumo](https://grandeconsumo.com/en/?p=242967); [TGTG press](https://www.toogoodtogo.com/en-us/press/too-good-to-go-accelerates-u-s-expansion)
- Flashfood + Loblaw 2025: >21 million lbs diverted, >$58 million saved by customers, +92,000 new shoppers; cumulative >105M lbs since 2019; discounts "up to 50 per cent"; first-year savings estimate $10M. — [Retail Insider, Mar 2026](https://retail-insider.com/retail-insider/2026/03/loblaw-and-flashfood-helped-canadians-save-58-million-on-groceries-in-2025/); [Supermarket News](https://www.supermarketnews.com/grocery-trends-data/loblaw-makes-strides-in-food-waste-reduction-with-flashfood); [CTV](https://toronto.ctvnews.ca/as-grocery-prices-rise-more-canadian-shoppers-turning-to-food-rescue-apps-1.6144674)
- Household sketch: the app knows the household eats yogurt 4x/week and is at 1 cup → it bids on near-expiry yogurt at the nearest store; consumption velocity tells it the household will finish the item before it expires, which solves the core buyer uncertainty of surplus markets.

#### 9. Dynamic markdown by expiry date (Wasteless) — NICHE
- Spanish retailer pilot: 32.75–32.8% reduction in food waste and 6.3% revenue increase; mechanism starts with ~2% markdown six days before expiry then steps down; launched Madrid 2017, expanded to ~40 more outlets; "up to 80%" claims are projections. — [FoodPrint](https://foodprint.org/blog/food-waste-management/); [Freethink](https://www.freethink.com/hard-tech/digital-price-tags-dynamic-pricing); [Jewish Star](https://thejewishstar.com/stories/cutting-food-waste-with-dynamic-market-pricing,20693)
- Household sketch: invert it — the *household's* own pantry items get a "use-by price curve," and the app pushes a recipe or a swap instead of a repurchase as items approach expiry.

#### 10. "Ugly produce" / imperfect-goods subscription (Misfits Market, Imperfect Foods) — NICHE, consolidating
- Misfits acquired Imperfect Foods (2022) then cut ~20% of staff; closed three distribution centers (Delanco NJ, Salt Lake City, Dallas) affecting 649 employees in early 2023; both brands kept separate websites; set a $1B sales/profitability goal for 2024 (outcome not found). — [Nosh](https://www.nosh.com/news/2022/misfits-market-imperfect-foods-layoff-20-of-company); [Grocery Dive](https://www.grocerydive.com/news/misfits-market-close-3-fulfillment-centers-imperfect-foods/643326/)
- Household sketch: cosmetic-grade tiering for non-food (scratch-and-dent furniture, open-box hobby gear) matched to what the walkthrough shows the household tolerates (e.g., already owns thrifted furniture).

#### 11. Vendor-Managed Inventory (VMI) — THRIVING B2B
- 1980s Walmart–P&G initiative: suppliers took responsibility for managing their products in Walmart's warehouses; "so successful in significantly improving order fulfilment" that other retailers and manufacturers adopted it. — [Haufe Akademie](https://www.haufe-akademie.de/blog/themen/logistik-supply-chain-und-aussenhandel/vendor-managed-inventory/); [TechTarget](https://www.techtarget.com/enterprise-software/definition/vendor-managed-inventory-VMI)
- Datalliance study across 156 location relationships (1–2 years on VMI): +25% inventory turns, +24% sales, −31% stock-outs. — [TrueCommerce/Datalliance](https://www.truecommerce.com/wp-content/uploads/2023/05/TCVMI-Datalliance-EB-BusinessResultsVMI-All-19-07-Online.pdf)
- Household sketch: "household VMI" — the household is the retailer, the walkthrough + consumption tracking is the point-of-sale feed, and a vendor (or the app acting as vendor) commits to a fill rate and gets paid on a Visa recurring mandate. This is the closest B2B analogue to what the app's data enables.

#### 12. Consumer auto-replenishment hardware/services (Amazon Dash buttons, Dash Replenishment Service, Walmart InHome, Subscribe & Save) — MIXED
- Dash buttons: sold at $5 refunded on first order; sales stopped Feb 2019; Amazon later shut functionality as usage "significantly slow[ed]," citing Alexa/voice and virtual Dash buttons; a German court had ruled them in violation of consumer-protection rules the month before. — [Tech.co](https://tech.co/news/amazon-kills-dash-button-2019-08); [TechSpot](https://www.techspot.com/news/78983-amazon-has-discontinued-dash-buttons.html); [The Grocer](https://thegrocer.co.uk/news/amazon-discontinues-sale-of-dash-ordering-buttons/590875.article)
- Dash Replenishment Service moved reordering into appliances (Whirlpool, Samsung, printers reordering ink). — [ETCentric](https://www.etcentric.org/?p=137726)
- Walmart InHome "AI-powered replenishment" announced at CES 2024 for Walmart+ InHome members ($19.95/month or $138/year); launch date not announced; VP said replenishment would not be subscription-based; distinct from existing interval-delivery option. — [Grocery Business](https://www.grocerybusiness.ca/walmart-unveils-game-changing-ai-powered-replenishment-for-in-home-delivery-at-ces-2024/); [Supermarket News](https://supermarketnews.com/online-retail/walmart-further-expanding-inhome-delivery)
- Amazon Subscribe & Save: no public subscriber count; 2024 Brand Metrics beta added "Sales by Deliveries" cohort view; third parties call it one of the lowest-churn e-commerce programs (not measured data). — [Intentwise](https://www.intentwise.com/blog/explained-amazons-new-subscribe-save-dashboard)
- Household sketch: replace the physical button/fixed interval with consumption-derived reorder points; the walkthrough supplies the "shelf count" that Dash never had.

#### 13. Over-engineered consumable lock-in (Juicero) — DEAD
- Packs cost $5–8; connectivity and pack scanner blocked competing suppliers; Bloomberg showed hands squeezed packs faster than the press; shut down September 2017. — [FourWeekMBA](https://fourweekmba.com/what-happened-to-juicero); [ProductMint](https://productmint.com/what-happened-to-juicero/); [Failory](https://www.failory.com/cemetery/juicero)
- Lesson: hardware to capture a consumable stream fails when the manual alternative is trivial; the app should not require any device beyond the phone.

#### 14. Consignment / peer resale (Mercari, Poshmark) — THRIVING
- Mercari Q2 FY2024: GMV +10% YoY to ¥280.9B (~$1.85B); eliminated 10% US seller fee in March 2024. — [Modern Retail](https://www.modernretail.co/operations/mercari-eliminates-selling-fees-heightening-competition-with-thredup-poshmark/); [Seeking Alpha transcript](https://seekingalpha.com/article/4670319-mercari-inc-mcary-q2-2024-earnings-call-transcript)
- Poshmark GMV $1.8B in 2021 (last full-year total found); fashion the largest category in 2024. — [FashionNetwork](https://id.fashionnetwork.com/news/Poshmark-posts-record-fourth-quarter-GMV-revenues,1390092.html); [Statista](https://statista.com/statistics/1427873/poshmark-marketplace-gmv-share-by-category)
- Household sketch: "trade-in at point of replacement" — when the app proposes a new coffee maker, it simultaneously lists the old one (identified in the walkthrough) and nets the expected resale into the price shown.

#### 15. Price-drop refunds / price protection (Paribus, card-issuer benefits) — DEAD or NICHE
- Capital One bought Paribus in 2016, rebranded "Capital One Price Protection," dropped the commission model; discontinued 2020 (Dealroom) or January 2023 (Wikipedia) — sources conflict. — [TechCrunch](https://techcrunch.com/2016/10/06/capital-one-acquires-online-price-tracker-paribus/); [Dealroom](https://app.dealroom.co/companies/paribus); [Wikipedia: Paribus](https://en.wikipedia.com/wiki/Paribus)
- Discover eliminated price protection; Citi Price Rewind ended September 2019; claims are typically not automatic. — [NerdWallet](https://www.nerdwallet.com/article/credit-cards/credit-card-price-protection)
- Capital One World/World Elite Mastercards added price protection: max $250/claim, 4 claims/12 months. — [Doctor of Credit](https://doctorofcredit.com/capital-one-adds-price-protection-to-their-world-mastercards)
- Visa's own price protection is a *cardholder* benefit (same make/model/year, lower price within 30 days, subject to caps), not a merchant API. — [Visa price protection](https://aw.visa.com/supporting-info/price-protection.html)
- Household sketch: since the app sees every purchase and knows the SKU, it can file price-protection-style claims automatically — the automation that card issuers lacked (and which made the benefit expensive once Paribus automated it).

#### 16. Coupon/price-tracking browser extension (Honey) — THRIVING
- PayPal paid ~$4B (announced Nov 2019, closed Q1 2020); Honey had ~17M monthly users, ~$100M 2018 revenue, 30,000 retailers, profitable in 2018; earns affiliate commissions; tracks prices and alerts on drops below a threshold. — [Retail TouchPoints](https://www.retailtouchpoints.com/news/paypal-acquires-deal-finding-platform-honey-for-4-billion/22437/); [PerformanceIN](https://performancein.com/news/2019/11/21/paypal-acquire-browser-extension-honey-4-billion/)
- Household sketch: affiliate-funded (not user-funded) model — the app earns when it routes a replenishment order, so the user pays nothing for the mechanism.

#### 17. Merchant-funded card-linked offers (Cardlytics) — THRIVING
- 100% of Cardlytics revenue comes from merchants ("merchant-funded rewards"); merchants pay per redemption, fee split with the client bank (split undisclosed); pay-for-performance; older profile: ~400 banks, $500M sales/quarter. — [The Financial Brand](https://thefinancialbrand.com/news/bank-marketing/cardlytics-merchant-funded-rewards-22774); [Digital Transactions](https://www.digitaltransactions.net/with-chase-rollout-completed-cardlytics-user-base-more-than-doubles/); [Finovate](https://finovate.com/?p=32429)
- Mastercard–Cardlytics partnership (2015) to bring card-linked loyalty to banks of all sizes. — [BusinessWire](https://www.businesswire.com/news/home/20151027005627/en/MasterCard-and-Cardlytics-Partner-to-Deliver-an-Integrated-Card-Linked-Loyalty-Program-for-Banks-of-All-Sizes)
- Household sketch: the Visa card is the redemption rail; the walkthrough tells merchants exactly which household is a *switchable* buyer (owns a competitor's brand), which is far more targetable than transaction history alone.

#### 18. Prepaid-share / CSA model — NICHE
- A CSA farmer delivers to subscribers who purchased shares in that season's products; gives producers cash at season start and a guaranteed market. — [USDA NAL](https://www.nal.usda.gov/afsic/csa/)
- 2012 Census: 12,617 farms sold via CSA; 2020 USDA survey: 7,244 farms; 2007 estimate of 12,549 was publicly challenged as inflated (4× the LocalHarvest directory). — [USDA Census highlights](https://agcensus.library.cornell.edu/wp-content/uploads/Highlights_Farmers_Marketing.pdf); [Hill Country Observer](https://www.hillcountryobserver.com/news061.htm); [UMD Extension](https://extension.umd.edu/sites/extension.umd.edu/files/2021-02/CRED-01_CSA.pdf)
- Household sketch: prepay a season of a *consumable bundle* (coffee, cleaning, pet food) at a fixed share price; the app sizes the share from measured consumption so the chronic CSA problem (members can't use what arrives) disappears.

#### 19. Price locks / price-match promises / fixed-price anchors — THRIVING as retail marketing
- Tesco locked >1,000 product prices (2023) "until 2024"; Aldi Price Match launched 2020, checks Aldi prices twice weekly, >600 staples matched by late 2023; no outcome data on market-share effect found. — [The Grocer](https://www.thegrocer.co.uk/tesco/tesco-locks-1000-prices-until-2024-in-latest-attempt-to-battle-aldi/683558.article); [Marketing Week](https://www.marketingweek.com/tesco-price-match-aldi/); [Retail Insight Network](https://www.retail-insight-network.com/news/tesco-freezes-prices-1000-everyday-products/)
- Costco's $1.50 hot dog unchanged since 1985 (see #4).
- Household sketch: a "household price lock" — the app offers to fix the price of the household's top-20 recurring SKUs for 6 months in exchange for a Visa recurring mandate; the merchant gets demand certainty, the household gets a hedge.

#### 20. Pre-commitment defaults (Save More Tomorrow) — THRIVING concept, contested effect size
- Employees pre-commit a share of future raises to savings, can opt out any time; 78% of those offered joined, 80% stayed through the fourth raise, average saving rates 3.5% → 13.6% over 40 months (first site: 3.5% → 11.6% in 28 months, 98% retention through two raises). — [Jason Collins behavioural econ notes](https://behaviouraleconomics.jasoncollins.blog/intertemporal-choice/intertemporal-choice-applications); [University of Rochester](https://www.rochester.edu/pr/Review/V66N2/feature5.html)
- DOL CLEAR rates causal evidence as low; at one site workforce-wide savings moved only 5.5% → 5.8% by the first raise. — [DOL CLEAR](https://clear.dol.gov/study/save-more-tomorrow%E2%84%A2-using-behavioral-economics-increase-employee-saving-thaler-benartzi-2004)
- Household sketch: "spend ceiling that ratchets down": household pre-commits that each time consumption data shows a cheaper equivalent SKU, the default switches and the difference is swept to a savings sub-account.

#### 21. Shared household ledger (Splitwise) — THRIVING, outcome evidence absent
- Friends enter shared bills, IOUs and payments; app tracks who owes whom; 2021 funding round; mission "to reduce the stress that money places on relationships." — [Craft.co](https://craft.co/splitwise); [Alexander Jarvis](https://www.alexanderjarvis.com/?p=17087)
- Anecdotal: groups "stop logging altogether" over time and budget-vs-spend is not intuitive (competitor's post). — [LinkedIn post](https://in.linkedin.com/in/maibee)
- Household sketch: roommate-split of consumables is auto-derived from the walkthrough (whose room, shared kitchen) and settled on Visa — removes the manual logging that kills Splitwise groups.

#### 22. Issuer-side control rails as a product mechanism (Visa Transaction Controls, Subscription Manager, Installments) — THRIVING infrastructure
- Visa Transaction Controls: spend limits, decline-all, cross-border, e-commerce, recurring, contactless controls and MCC-level merchant controls via the Customer Rules API; blocks/alerts available regardless of network routing. — [Visa Developer: VTC](https://developer.visa.com/capabilities/vctc/docs); [Visa corporate](https://corporate.visa.com/en/products/visa-transaction-controls.html)
- Visa Subscription Manager lets issuers show cardholders stored-credential merchants and stop card-on-file recurring payments from being authorized/cleared/settled through VisaNet; Enhanced Subscription Manager (March 2026, with Pinwheel) adds switching and cancellation in-app. — [Visa Developer: Subscription Manager](https://developer.visa.com/docs/visa-subscription-manager); [Financial IT](https://financialit.net/news/payments/visa-launches-enhanced-subscription-manager-giving-consumers-greater-control-over)
- Visa Installment Transaction Service: REST APIs/SFTP for issuer-defined installment plans; batch card-on-file eligibility check then Eligible Installment Plans API at point of sale. — [Visa Developer: Installments](https://developer.visa.com/docs/installment-transaction-service); [Fiserv docs](https://docs.fiserv.dev/public/docs/visa-installments-rest-api)
- Visa Token Service replaces card details with a digital identifier; Cybersource token management links tokens across providers. — [Visa partner directory](https://partner.visa.com/site/partner-directory/cybersource.html)
- Household sketch: the household's *budget envelopes* become literal VTC rules (MCC + amount), replenishment contracts become Subscription Manager-visible stored credentials, and furniture becomes an Installments plan — making the mechanism enforceable at the network, not just in the UI.

### Inferences
- The mechanisms that survived are those where the *merchant* funds the incentive (Cardlytics, Honey, Pinduoduo's margin-for-volume) or where a membership fee replaces margin (Costco). Mechanisms that asked the *consumer* to do extra work or buy hardware (Priceline bidding, Dash buttons, Juicero, Groupon thresholds) died once the friction exceeded the saving.
- Price protection failed for issuers precisely when it became automated (Paribus/Capital One), suggesting the economics only work if the merchant, not the issuer, funds the refund — i.e., as a merchant-side retention tool.
- Several mechanisms (VMI, CSA, Subscribe & Save, Flashfood) are bottlenecked by the same missing input — knowledge of actual on-hand stock and consumption rate — which is exactly what a walkthrough plus consumption tracking supplies.

### Gaps
- No reliable sources found for: milkman-model revival (Milk & More), bodega tabs/credit, mutual-aid pantries, kakeibo or envelope budgeting outcome data, Instacart "reorder" feature, Samsung Family Hub grocery-ordering results, CamelCamelCamel usage, Esusu's current savings-circle product (one source describes it as rent-reporting), Best Buy/Apple trade-in values, 1987 Walmart–P&G inventory-turn figures, Walmart InHome replenishment launch status after CES 2024, Misfits Market 2024–2025 status, Groupon's current GMV.
- Too Good To Go's merchant fee structure and Surprise Bag discount depth were not retrieved (press page returned HTTP 429).
- Pinduoduo per-deal discount percentages and group sizes were not stated in the sources fetched (TechCrunch says "up to half" without detail).

## Key question 1: Which mechanisms depend on knowing the household's inventory/consumption (the data a walkthrough + consumption tracking produces)?

### Takeaway
VMI, consumption-driven replenishment, surplus/near-expiry matching, prepaid consumable shares, household price-locks, trade-in-at-replacement, and inventory-aware group buying are all gated on knowing on-hand stock and burn rate; these are the strongest candidates because the incumbent versions all lack that input.

### Cited Findings
- VMI's defining feature is that "the supplier takes all inventory-related decisions and replenishes inventory levels for the retailer" — requires a stock feed. — [TechTarget](https://www.techtarget.com/enterprise-software/definition/vendor-managed-inventory-VMI)
- Walmart's planned InHome replenishment "will track consumer shopping and consumption habits to automatically restock items" — consumption data is the stated core. — [Grocery Business](https://www.grocerybusiness.ca/walmart-unveils-game-changing-ai-powered-replenishment-for-in-home-delivery-at-ces-2024/)
- Dash buttons died as usage "significantly slow[ed]" — a press-the-button model with no inventory knowledge. — [TechSpot](https://www.techspot.com/news/78983-amazon-has-discontinued-dash-buttons.html)
- Dynamic markdown (Wasteless) prices by *time to expiry*, achieving −32.8% waste / +6.3% revenue; the buyer-side analogue needs the household's own expiry timeline. — [FoodPrint](https://foodprint.org/blog/food-waste-management/)
- CSA shares give farmers up-front cash but presume the subscriber can consume the share. — [USDA NAL](https://www.nal.usda.gov/afsic/csa/)
- Pinduoduo team purchase requires demand to be clustered in time (24-hour window). — [TechCrunch](https://techcrunch.com/2018/07/26/the-incredible-rise-of-pinduoduo)
- Cardlytics targets offers from transaction data only; merchants pay per redemption. — [Digital Transactions](https://www.digitaltransactions.net/with-chase-rollout-completed-cardlytics-user-base-more-than-doubles/)

### Inferences
- Strongest candidates (inventory-dependent): #11 household VMI, #12 consumption-triggered replenishment, #8 surplus matching with consumption-velocity guarantee, #18 prepaid consumable shares sized by consumption, #19 household price lock on top recurring SKUs, #14 trade-in at replacement (requires knowing what is owned), #2 inventory-derived demand clustering for group buys, #7 surfacing surplus items for gifting.
- Weakly dependent (work on transactions alone): #16 coupons, #17 card-linked offers, #15 price protection, #20 commitment defaults, #21 ledgers.
- Not dependent: #1 NYOP, #3 tipping deals, #5 ROSCAs, #6 layaway.

### Gaps
- No source quantifies how much consumption-rate knowledge improves replenishment or surplus-market conversion for consumers; the VMI figures (+25% turns, −31% stock-outs) are B2B proxies.

## Key question 2: Which require two-sided merchant supply that a hackathon could mock, and which work single-sided?

### Takeaway
Single-sided mechanisms (commitment devices, price locks via the household's own budget, household ledgers, save-to-buy, gift-economy listing, issuer-side spend controls) can be demonstrated end-to-end with a Visa sandbox alone; group buying, VMI contracts, surplus markets and card-linked offers need a merchant side but can be convincingly mocked with 3–5 scripted merchants because the real-world versions are themselves merchant-funded and opaque to the user.

### Cited Findings
- Pinduoduo's price ladder and 24-hour window are fully visible to the buyer and merchant-funded; 5.1M merchants in reality. — [DAO Insights](https://daoinsights.com/works/pinduoduos-social-group-buying-model-wins-over-tier-3-4-consumers/)
- Cardlytics offers are merchant-funded with an undisclosed fee split — buyer never sees merchant economics. — [Digital Transactions](https://www.digitaltransactions.net/with-chase-rollout-completed-cardlytics-user-base-more-than-doubles/)
- Honey's threshold price alerts and automatic coupon entry are single-sided client features over existing retailers. — [PerformanceIN](https://performancein.com/news/2019/11/21/paypal-acquire-browser-extension-honey-4-billion/)
- Visa Transaction Controls, Subscription Manager and Installment APIs are available on the Visa Developer platform with sandbox docs. — [Visa Developer: VTC](https://developer.visa.com/capabilities/vctc/docs); [Visa Developer: Installments](https://developer.visa.com/capabilities/installment-transaction-service/docs-getting-started)
- Buy Nothing operates with zero merchants (13M neighbors, 2.6M gifts/month). — [Buy Nothing docs](https://docs.buynothingproject.org/)
- Save More Tomorrow is a pure defaults design with no counterparty. — [Rochester](https://www.rochester.edu/pr/Review/V66N2/feature5.html)

### Inferences
- Single-sided, demonstrable with household data + Visa alone: #20 commitment defaults/spend ceilings, #21 auto-split ledger, #6 save-to-buy, #7 gift listing of surplus, #22 VTC envelopes, #15 automated price-protection claims (needs only price feed), #16 price tracking.
- Two-sided but easy to mock (merchant logic is simple and merchant-funded in reality): #2 group buy, #8 surplus bags, #17 card-linked offers, #19 price lock.
- Two-sided and hard to mock credibly: #11 full VMI with fill-rate SLAs, #5 ROSCAs (needs many trusted peers), #14 resale (needs buyer liquidity).

### Gaps
- No source describes a consumer-facing demand-side RFQ marketplace (merchants bidding on household intents) that operated at scale; Priceline is the closest and it died.

## Key question 3: Which have obvious Visa payment hooks?

### Takeaway
Visa already ships the rails for spend caps (Transaction Controls), recurring mandates and their cancellation (Subscription Manager / Stop Payment), installments (Installment Transaction Service) and tokenized card-on-file (Visa Token Service); price protection exists only as a cardholder insurance benefit, not a merchant API, and no Visa Direct instant-refund or Visa Offers Platform documentation was retrieved.

### Cited Findings
- VTC supports spend limits, recurring-transaction controls and MCC-level merchant controls via the Customer Rules API; corporate page cites limits "by transaction amount, budget, merchant category or transaction type." — [Visa Developer: VTC](https://developer.visa.com/capabilities/vctc/docs); [Visa corporate](https://corporate.visa.com/en/products/visa-transaction-controls.html)
- Subscription Manager stops card-on-file recurring payments "from being authorized, cleared, or settled through VisaNet"; Visa Stop Payment Service underlies it; Enhanced version launched March 2026. — [Visa Developer](https://developer.visa.com/docs/visa-subscription-manager); [Glenbrook](https://glenbrook.com/?p=56995)
- Installment Transaction Service: issuer-defined plans, REST/SFTP, eligibility check then Eligible Installment Plans API; availability varies by region. — [Visa Developer](https://developer.visa.com/docs/installment-transaction-service)
- Visa price protection: cardholder benefit for same make/model/year found cheaper within 30 days, with caps. — [Visa](https://aw.visa.com/supporting-info/price-protection.html)
- Visa Token Service replaces card details with a unique digital identifier. — [Visa job listing describing VTS](https://powertofly.com/jobs/detail/2049468)
- Walmart replaced interest-free layaway with Affirm installments at 10–30% APR. — [WSLS](https://www.wsls.com/features/2021/09/24/walmart-says-goodbye-to-layaway-offers-new-buy-now-pay-later-payment-option)

### Inferences
- Mechanism → Visa hook map: spend ceilings/envelopes (#20) → VTC amount + MCC rules; household VMI / price lock (#11, #19) → tokenized card-on-file + recurring mandate visible in Subscription Manager; furniture ROSCA or save-to-buy (#5, #6) → Installments API or scheduled pulls; roommate split (#21) → multiple tokens on one household account; trade-in (#14) → net settlement; price protection (#15) → automated claim against the cardholder benefit.
- A hackathon can credibly show the *enforcement* of a budget mechanism at the network level (VTC), which differentiates it from UI-only budgeting apps.

### Gaps
- Visa Direct instant-refund and Visa Offers Platform documentation not retrieved; Visa's current price-protection benefit terms by card tier not verified.
- Whether VTC can be configured by a third-party app (vs. only by the issuer) was not confirmed from the docs fetched.

## Key question 4: Documented failures and the lesson each gives

### Takeaway
The failure record is consistent: mechanisms died when they required consumer effort or hardware (Dash, Juicero, Priceline bidding), when the incentive was funded by the wrong party (issuer-funded price protection), when a visible threshold deterred buyers (Groupon), or when a non-monetary community was pushed onto a monetized app (Buy Nothing).

### Cited Findings
- Dash buttons: $5 button refunded on first order; sales halted Feb 2019; usage "significantly slow[ed]"; German court ruled them in violation of consumer-protection rules. — [Tech.co](https://tech.co/news/amazon-kills-dash-button-2019-08); [The Grocer](https://thegrocer.co.uk/news/amazon-discontinues-sale-of-dash-ordering-buttons/590875.article)
- Juicero: $5–8 packs, DRM-style scanner, hand-squeezable packs, shutdown Sept 2017. — [ProductMint](https://productmint.com/what-happened-to-juicero/)
- Priceline NYOP: flights ended Sept 1 2016 for "a dramatic evolution in both technology and customer behaviour." — [Skift](https://skift.com/?p=196057)
- Groupon tipping point: did not boost sales, deterred new customers, overwhelmed merchants; abandoned by Groupon and Korean rival. — [SAGE](https://journals.sagepub.com/doi/full/10.1016/j.intmar.2015.12.001)
- Boxed: Chapter 11 April 2023, up to $190.4M liabilities, cash concentrated at SVB; had rejected $400M Kroger bid. — [BNN Bloomberg](https://www.bnnbloomberg.ca/online-wholesale-retailer-boxed-files-for-chapter-11-bankruptcy-1.1903669)
- Capital One/Paribus price protection discontinued (2020 or Jan 2023, conflicting); Citi Price Rewind ended Sept 2019; Discover eliminated it. — [Dealroom](https://app.dealroom.co/companies/paribus); [Wikipedia](https://en.wikipedia.com/wiki/Paribus); [NerdWallet](https://www.nerdwallet.com/article/credit-cards/credit-card-price-protection)
- Buy Nothing app: community rejected fundraising, VC pitches backfired, "poor-quality app and an angry community," ~91,000 regular users, groups split off. — [Marketplace](http://www.marketplace.org/story/2023/05/16/what-happened-to-the-buy-nothing-project); [Boston Globe](https://www.bostonglobe.com/2023/03/19/business/welcome-buy-nothing-revolution/)
- Misfits/Imperfect: 20% layoffs, 3 DC closures (649 jobs) within a year of merging. — [Grocery Dive](https://www.grocerydive.com/news/misfits-market-close-3-fulfillment-centers-imperfect-foods/643326/)
- Walmart layaway: dropped 2021 for declining usage, replaced by interest-bearing BNPL. — [NWA Online](https://www.nwaonline.com/news/2021/sep/28/layaway-has-gone-away-at-walmart/)
- Save More Tomorrow: headline gains concentrated among enrollees; workforce-wide effect small (5.5% → 5.8%); causal evidence rated low. — [DOL CLEAR](https://clear.dol.gov/study/save-more-tomorrow%E2%84%A2-using-behavioral-economics-increase-employee-saving-thaler-benartzi-2004)

### Inferences
- Lesson 1 (Dash, Juicero, smart appliances): no new hardware; the phone video walkthrough must be the only sensor.
- Lesson 2 (Groupon, Priceline): never show the buyer a contingent price or make them bid; aggregate silently and present a firm price.
- Lesson 3 (Paribus, Citi, Discover): price-drop refunds must be merchant-funded (retention) or affiliate-funded (Honey), not issuer-funded.
- Lesson 4 (Buy Nothing): keep the gift/swap lane strictly non-monetary and separate from the purchasing lane.
- Lesson 5 (Boxed, Misfits): bulk and surplus logistics are capital-intensive; a hackathon app should ride existing retailer fulfillment (Flashfood/TGTG model) rather than own inventory.
- Lesson 6 (SMarT): opt-out defaults drive enrollment, but measure the population effect, not just enrollees.

### Gaps
- Samsung Family Hub / smart-fridge grocery ordering outcomes: no sources found.
- No post-2024 data on whether Walmart's AI replenishment launched or on Instacart reorder adoption.
- Groupon post-2016 financials and current status not researched.
