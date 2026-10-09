# Midas – Changelog

## 1.2.11 – 2026-10-09
- **Midas Discord.** Questions, bug reports and feature ideas now have a home at https://discord.gg/CfZgeyxAn5 - linked in the window footer, the Help tab, the get-started tour and "/midas discord" (click to copy).

## 1.2.10 – 2026-10-08
- **Settings checkboxes stick again.** Fixed a bug where turning a checkbox back ON (offer book, alert lines, sell helper, starter watchlist, Alt/Shift shortcuts) silently kept the feature off and the box unticked itself a moment later.
- **"/midas keys" switches the shortcuts back on.** Rebinding a click shortcut now also re-enables the master toggle, so a fresh key never sits dead behind an off switch.

## 1.2.9 – 2026-10-08
- **Configurable click shortcuts.** The alt-click (post the price card to chat) and shift-click (AH search / open the chart) shortcuts now have an on/off checkbox in Settings, and "/midas keys" rebinds each one to ALT, CTRL or SHIFT.
- **Charts: outlier trades no longer crush the scale.** Fixed a bug where a single buy or sale far outside the current price range squashed the whole price line flat and piled the edge labels into each other - such a trade now stays off the scale and skips its dot, while the day's hover read-out keeps the numbers.
- **Sell helper: updates after each scan, item tooltip on hover.** The bar re-ranks your bags the moment a scan is stored, and hovering an icon now shows the item's in-game tooltip with the Midas lines (it used to show nothing).

## 1.2.8 – 2026-10-06
- **Watchlist groups.** Create named sections with the "+ group" button and drag rows in - onto a header, one of its items, or the group chips above the table (they take drops even from a search). Chips filter the list on a click, "collapse all" folds every section, headers fold on click, right-click renames, shift-click deletes - and the column sort survives reloads and keeps working inside each group.
- **Browse the whole archive.** The Watchlist tab's new all-items view lists every item with scan data - sortable, searchable, right-click to watch - and the MARKET TODAY card on the start page opens it directly.
- **Sell helper at the AH.** The sell tab docks a bar of your bag items, best sale first (% over fair): click one and it lands in the sell slot - with a replacing AH addon (aux, Auctionator, TSM) it lands on your cursor instead, ready to drop on their post slot - and the next candidates slide up as you list.
- **Offer book upgrades.** Your own buyouts thin the ladder live instead of waiting for the next scan, the docked book fills its whole height (up to 20 price rows), both AH docks carry a close button (the Settings checkboxes still turn them off for good), and a YOUR-ASK bar posted after the scan now extends the ladder and its scale instead of growing into the other sellers' supply.
- **Realm renames: your history can follow.** "/midas realms" lists every stored market and "/midas realmmerge <old name>" moves its price archive, trades, net worth and alerts under the current realm - a login note points there, and the merge works even after new scans.
- **Trades and chart: average sale is per unit.** Fixed a bug where the avg-sell figure divided by sold auctions instead of units, so stack items showed stack prices next to the per-unit buy, Current and Fair figures.
- **Charts: name store healed.** Fixed two bugs in the names remembered from scans: items scanned before the client knew their name showed as blank, unsearchable rows, and weapon or armor names kept their random suffix, doubling it on chart titles - both heal at login.
- **Forever: failed scans retry immediately.** The 15-minute scan cooldown now starts only when the server actually delivers a snapshot, and an empty or unreadable snapshot says so in chat instead of failing silently.

## 1.2.7 – 2026-10-05
- **Get-started guide.** A six-step tour of the Midas workflow - scan, watchlist, fair price, offer book, alerts, your trades - sits behind a Settings button, and fresh installs open with it.
- **Starter watchlist.** New installs begin with a curated set of ~80 items that trade well on most realms; the Settings checkbox adds or removes the set at any time without touching your own picks.
- **Price alerts.** Any item can carry a below and/or above limit (Charts tab): when a scanned or synced price reaches it, Midas rings the raid-warning bell and posts a chat line; "/midas alerts" lists them.
- **Charts: alert lines.** An item's below/above price alerts draw as dashed limit lines in its big chart - below in green, above in gold; a Settings checkbox turns the lines off.
- **Trades: holdings change in the summary.** The 60-day band now shows HOLDINGS (the value change of everything you still hold) and TOTAL (realized + holdings) next to NET P/L.
- **Trades: own consumption shown.** A small consumed line under BOUGHT prices the bought units that were neither resold nor are still in stock (equips put on, mats used up).
- **Offer book: asks posted after the scan show their size.** Fixed a bug where a YOUR-ASK price missing from the newest scan drew only a hairline without its quantity bar.
- **Charts: longer history list.** The recently-viewed list keeps 30 items; the mouse wheel scrolls entries beyond the visible rows.
- **Charts: search covers the whole archive.** Item names are remembered from your scans, so the search finds every scanned item - not only those the game client has cached - and a bare item id jumps straight to it.
- **Net-worth hover: readable quantity change.** Fixed a bug where the top-gainers/losers tooltip showed a box glyph instead of the arrow between the held-unit counts.
- **Movers and trades band: junk reference prices contained.** Fixed a bug where an item with a junk price history could blow the market/quantity split up by thousands of gold.

## 1.2.6 – 2026-09-30
- **Intraday in the 1W charts.** On the 1W range the net-worth chart and the item price charts show each scan of the last 8 days as its own point, with the time of day on hover.
- **Price chart in the item tooltip.** Hovering an item docks a mini price-history chart to the tooltip; Settings picks its timeframe (1W / 1M / 3M / All) or turns it Off.
- **Offer book at the auction house.** Picking a browse result or dropping an item into the sell slot docks that item's supply ladder to the AH window; a Settings checkbox turns it off.
- **What's-new notes stack into one window.** Several unseen notes now show as pages of a single window ("2 / 3") instead of popping up one after another.
- **Chart header is a live item link.** Hovering the icon or name shows the in-game item tooltip, shift-click runs the AH search and alt-click posts the stats to chat.
- **Split view follows the item switch.** Fixed a bug where picking another item from the chart list kept the offer-book column on the previous item.
- **Split view: no more overlapping labels.** Fixed a bug where the narrow offer-book column packed rows so tight that marker texts, the YOUR-ASK label and the quantile tags ran into each other.
- **Offer book: your asks marked in place.** A price row containing your units splits its supply bar into the others' share and yours, with the YOUR ASK line and count in the same row instead of a separate marker row.
- **Open views refresh on new data.** The active tab and any open drill-down (offer book, why-view, Net Worth views) update right after a scan finishes or the auction, mail or bank cache changes.
- **Fair maths in the tooltip.** The market-numbers hover in the Charts tab now spells out the Fair formula (trimmed base, odds curve, lift caps).

## 1.2.5 – 2026-09-27
- **Forever Hot Fix: two-part character names no longer fork.** Fixed a bug where duplicates created by the recent beta client change are merged back on login.

## 1.2.4 – 2026-09-25
- **Alt-click price card trimmed.** The chat line now posts current price, fair (± vs fair), 7-day floor and the all-time low.
- **Split view: chart + offer book.** The chart header's new "offer book | split" control shows the price chart on the left and a reduced offer book (the supply ladder) on the right.
- **Item icon in the Charts header.** The chart title and the offer-book title now show the item's icon.
- **Young charts stay compact.** With only a few scan days a chart now starts at the left edge with sensibly sized, sensibly spaced bars instead of stretching them across the full width.
- **Home sparkline contained.** On a very short history its background columns no longer spill outside the net-worth card.

## 1.2.3 – 2026-09-24
- **Offer book.** The Charts tab's new "offer book" link lists every price an item is listed at in your newest scan, with units, auctions and cumulative supply; the item tooltip shows how much is listed within 10 % of the cheapest price.
- **API:** `MidasAPI.GetDepth` and `GetDepthSnapshot` return the offer book to other addons.
- **Preview timeframe (Settings).** The small preview charts - the hover cards on Home, Opportunities, Watchlist and Trades, and the start page's net-worth sparkline - now have their own 1W / 1M / 3M / All switch, independent of the big charts.

## 1.2.2 – 2026-09-23
- **Net worth: large commodity auctions valued correctly (Forever).** Bulk auctions now count at their full value.
- **Trades: multi-stack purchases counted in full.** Buys and returns delivered as several stacks in one mail now log the whole quantity.

## 1.2.1 – 2026-09-20
- **Net worth counts one auction house at a time.** On a realm where you play both
  factions, every character on the account used to be added up and valued with the
  faction you happened to be logged in on. Now each character counts only in its own
  realm + faction, and the daily net-worth history is kept per realm + faction as well
  (your existing history stays with the faction that recorded it). Characters from
  older versions are assigned the first time they log in.
- **Forever popup:** now also points to the community workaround ForeverSVFix for the
  beta's saved-data bug (shown once more to everyone who already saw the popup).

## 1.2.0 – 2026-09-18
- **WoW Forever support (beta):** one Midas for both game versions - Classic Era 1.15.9 and
  the WoW Forever beta 1.60.1 (modern client). Midas detects the client's auction house by
  itself: on Forever the full scan uses the modern snapshot scan (commodities included, the
  server allows one every ~15 minutes), your own auctions, mails, vendor prices, bank tabs,
  shift-click search and the Scan button all work on the new AH. Era is unchanged. On Forever
  the cross-guild (nearby) sync is not available - the client blocks say/yell addon messages -
  so sync runs over guild and group; Midas switches the nearby layer off on its own.
  Known beta issue: the Forever beta sometimes fails to load saved addon data at login
  (a Blizzard bug that affects every addon) - a one-time popup on Forever explains it, and it
  comes back whenever that happens.
- **Trades: deposits no longer count as sales.** A sale mail also refunds the listing deposit;
  Midas used to book that refund as proceeds, which inflated sale prices and net profit by the
  deposits. Newly collected mails now record the real sale price.
- **Net-Worth polish - one consistent tab:** the hero header no longer overlaps (headline and
  decomposition are two compact lines next to TOP GAINERS / TOP LOSERS, whose headers now name
  their reference day, and the third mover row is clickable again); **every change column on
  the tab reads the same reference day** - class list, character list, the hover tooltips and
  all drill-downs, with the date right in the headers. The drill-downs pull their weight now:
  the **character view** gets a "MKT Δ" column (how the market moved under that character's
  holdings) plus its own change-since line, the **class view's** top items get a change column
  (and up to 24 rows on tall windows), the **day view** gets hover tooltips, an elastic
  character list and a **"What moved since?"** button that opens the item breakdown attributed
  against exactly that day, the **holding view** shows the item's market/trades effect over
  the window and labels what its quantity means, and the **movers rows** show the full
  quantity/market/trades split on hover. One delta format everywhere - tiny changes show a
  dash instead of "+0.0g" - the chart legend no longer collides with the total line, and the
  holding chart's Fair line stays inside its price zone and the selected timeframe (it used
  to draw out of the canvas on trimmed windows). The holding view's quantity now always
  counts account-wide INCLUDING your own auctions (matching the chart's snapshots - entering
  via a class list used to show only that class's share), with the character's own share
  named when you came from a character.
- **Alt-click price card:** answer a "price check?" with one click. **Alt-click any item** -
  a link someone posted in chat, an item in your bags, or any row inside Midas - and its
  price card goes straight into chat: current price, fair (± vs fair), median, 7-day floor,
  all-time high and sell speed, ending in "- by Midas Addon". The line is sent to your
  last-used chat channel (a whisper answers the same person) and always fits the chat
  limit. Shift keeps all its meanings; an item without data prints a local hint instead of
  posting an empty card.

## 1.1.0 – 2026-09-14
A design-review release: *"perfection is achieved when there is nothing left to take away."*

- **New Settings tab** (the Sync tab, rededicated – still 7 tabs): every option in one place.
  **General:** the item tooltip is finally configurable – **Full / Reduced / Off**, with a live
  preview showing exactly what each style produces; the **minimap button** can be hidden;
  **auto-scan on AH open** got its checkbox; plus the default chart timeframe. **Community
  sync** keeps its controls, a compact status and the live log – and the cross-guild (nearby)
  switch finally explains what it does.
- **Chart timeframe:** a **1W / 1M / 3M / All** switch on the Charts tab and the Net Worth
  chart zooms every big chart (drill-downs follow); the small preview cards keep showing the
  full history.
- **Net-worth attribution - "what moved it":** the Net Worth tab now answers WHY the number
  changed, all over the same timeframe switch. The hero line decomposes the change into
  **market** (prices moving under what you hold), **quantity** (what you gained or consumed),
  **gold** and an honest rest; **TOP GAINERS / TOP LOSERS** sit right in the header, one click
  from each item's holding history; the asset-class and character lists show their change over
  the same window; and a new account-wide **"what moved?"** drill-down lists every item's
  quantity and market effect plus its realized trading (sold - bought) with a +/- impact bar -
  down to an "everything else" line that ties the sum back to the actual total. Built purely
  from the daily snapshots, the price archive and your trade mail - nothing new is recorded.
- **The Start page now truly focuses the watchlist:** Today's Picks and Top Opportunities are
  merged into one compact **MARKET TODAY** card (best buys under Fair from both signals,
  deduplicated; best sells above), and the **watchlist gets a full-width row of its own** with
  Current / Fair / vs-Fair columns that grows with the window.
- **Safer slash commands:** `/midas help` lists everything, and a typo now prints the list
  instead of silently toggling the window. The destructive `/midas trim`, the log-polluting
  `/midas tradetest` and the debug `/midas commtest` + "Probe transport" button are **gone**.
- **Privacy, said out loud:** a one-time login note explains that sync shares scan data with
  guildmates & nearby Midas users (invisible to other players) and where to turn it off.
- **Consistency polish:** the item tooltip stays vanilla *inside* the Midas window (no more
  triple display on hover); the chart toggles only show where a chart can react (gone on
  Trades → History); every tab opens in its base view after a tab switch; the History columns
  got the explaining hover tooltips the other tables already had; "VS MED" is now "VS FAIR";
  the Help tab scrolls at the minimum window size; the Biggest-Movers rows no longer pretend
  to be clickable; the Fair/score method texts come from one shared source; and the net-worth
  drill-down notes now name **your** real first recording day instead of a hardcoded date.
  On the Net Worth tab itself: the chart toggles appear only where a chart reads them (the
  holding drill-down), the character column shows one thing (the change - share moved into
  the hover tooltip), sold-out items still open their holding history, big windows now grow
  the character list instead of inflating the chart to 600px, and the separator line no
  longer cuts through the hero and chart.

## 1.0.12 – 2026-09-01
- **The Midas gold theme:** the whole UI now carries the theme the addon is named for –
  everything Midas touches turns to gold. Warm, dark treasury backgrounds, gold hairlines and
  window edges, a gold wordmark, and above all: **every price and value line in the charts is now
  drawn in gold** (as the net-worth chart already was). Secondary statistics moved to a cool blue
  as the counterweight (Floor MA, trimmed no-demand days), so gold always means "the market /
  your gold" – while buy-green, sell-red and Fair-purple keep their meaning untouched.

- **New Start dashboard, leaner tab bar:** Midas now greets you with a **Start page** – your net
  worth with daily/7-day change and a sparkline of the daily snapshots, your **watchlist front and
  center** (BUY LOW / SELL HIGH vs Fair), today's picks, the top opportunities of your whole
  archive, the biggest character movers since the last snapshot and your trading highlights
  (best sale ever, best bargain of the last 60 days, latest trades). Every card jumps to its tab
  and any item can be watched with a right-click. The **Top Picks and Opportunities tabs are
  gone** – their content lives on the Start page in condensed form, and the full ranked table
  survives as the **Watchlist**, which is where the focus belongs.

- **Public API for other addons:** the new global **`MidasAPI`** lets any addon read Midas'
  numbers – `GetFairPrice`, `GetCurrentPrice` and `GetQuickSellPrice` plug straight into
  **TSM** as external price sources (item links accepted), plus sell odds at any asking price,
  the opportunity score, full daily price history, your own trade stats, net worth totals and
  scan/analysis/import callbacks. Other addons can also feed their price history INTO Midas
  via `MidasAPI.RegisterImportSource`. `/midas api` shows the status; docs at the top of
  `API.lua` and in the README.

## 1.0.11 – 2026-08-14
- **Graveyard instead of delete (HC deaths):** "Delete character" is gone - a fallen
  character is now **moved to the graveyard**: it stops counting toward the account total and
  rests in its own **graveyard sum** under the character list (click it to flip the list to the
  fallen). Nothing is deleted - items stay browsable, restoring is one click, and logging in on
  the character revives it automatically. A simple yes/no replaces the typed-DELETE confirm.

- **Charts tab header shows the item's story at a glance:** a big colored **BUY / SELL /
  NEUTRAL signal** (distance to Fair + sell odds) leads the eye, followed by one calm market
  line (Current, Fair with odds, Quick-sell, sell speed) and a dimmed personal line with your
  realized record (sold/returned, sell-through rating, avg sell, **avg buy**, net) that only
  appears when the item has trade history.

- **New Help tab & header tooltips:** a plain-language page explains how **Fair** and the
  **sell odds** are computed - with a worked example and two illustrative charts - plus a
  one-line glossary of every figure. The Charts header explains itself on hover (tooltips
  follow the cursor), and a **"why these numbers?"** view rebuilds both explanations from the
  item's OWN data: its real scan days with the trimmed ones marked, and its own odds curve
  with Fair and the current price on it.

## 1.0.10 – 2026-08-09
- **Import from other AH addons:** at login Midas now merges price history from **Auctionator**
  (up to 21 days) and **aux** into its archive — a fresh install starts with populated Top
  Picks/Opportunities instead of an empty window, and if you scan with those addons instead of
  Midas you stay current automatically. Runs in the background (no freezes), never overwrites
  your own scans; the Sync tab shows the last import and `/midas import` forces a re-check.

- **Buy/sell dots no longer vanish from charts:** the trade log now keeps a full 75 days —
  it was capped at 3,000 entries, so a busy trader's buys rolled out after ~2 weeks (also
  starving Avg Buy and sell-through of history). "Auction won" mails whose price invoice
  hadn't loaded yet are re-checked shortly after instead of being lost when looted quickly.

- **Weekday chart mode removed:** the Monday-Sunday overlay never earned its place next to
  the full time axis. Charts always show the complete history now; the All Time/Weekday
  switch is gone and the toggle row moved up accordingly.

## 1.0.9 – 2026-08-04
- **Net Worth day drill-down:** click a day in the history chart for that day's full snapshot —
  asset-class and per-character split, each with its change to now.
- **Class drill-down:** click an asset class for its value history chart, its per-character
  split and its top items.
- **One consistent drill-down chain:** every row is clickable — character > asset allocation
  (filter chips) > items > one item's holding history. "< back" retraces your exact path;
  Shift-click always opens the market chart.
- **Item holding view:** one dual-scale chart — market price (left scale) and your holding's
  value (right scale), with per-day quantity bars and your buy/sell dots. The Floor MA / Fair /
  My trades toggles work here too.
- **Net-Worth sub-charts fixed:** account/character/class history now draws on a real time
  axis — no more fragmented lines; missing days show as dashed gaps.
- **Resizable window:** drag the grip in the bottom-right corner — width and height move
  independently; the size is remembered.
- **Adaptive layout:** a bigger window shows more — every list gains visible rows, charts and
  detail cards grow into the extra room.
- **Chart polish:** trade dots always sit at their realized price (the scale stretches to
  include them), trades on unscanned days get hover read-outs, dots scale with the traded
  amount, the toggle bar hides where it does nothing, and every button has an explanatory
  tooltip.

## 1.0.8 – 2026-08-04
- **Fix: Top Picks / Opportunities no longer refresh endlessly at the AH.** Community-sync merges
  arrive continuously there, and every batch used to throw the analysis away and abort the
  background rebuild — under steady traffic it never finished ("analyzing…" forever). The last
  finished result now **stays on screen** while a rebuild runs behind it, builds always run to
  completion, and rapid sync batches are caught up by a single deferred pass. Item-name refreshes
  are batched less aggressively too.
- **Vendor purchases are now logged as trades.** Buying at a merchant (e.g. Chronoboon Displacers
  for flipping) records a **"Vendor buy"** in the Trades history with its real cost — so Avg Buy and
  realized net no longer look rosier than they are. AH-won mails keep working as before.
- **Net Worth chart is now cumulative by asset class:** the total line stays, and under it each
  day's snapshot is stacked by class (same colors as the BY ASSET CLASS list, with a compact
  legend). Your existing history already contains the split, so it works retroactively.
- **The character view got the same chart** — that character's worth over time, with its own class
  stack (the per-character split records from this version on and fills in day by day).
- **Characters can be deleted from the stats** (HC deaths): in the character view, "Delete
  character…" asks you to literally type **DELETE** — like deleting a real WoW character. The cached
  bags/bank/mail/auctions are removed so it stops contributing; past daily snapshots are kept.
- **Your trades in the chart:** the big price chart can now show every one of **your own buys
  (green dots) and sells (red dots)** at their day and realized unit price — see at a glance where in
  the price range you actually traded. Toggle with the new **"My trades"** checkbox next to
  "Floor MA" (on by default; vendor buys included). A small **legend** (green = buys, red = sells)
  shows while dots are visible, and **hovering a day** adds a read-out per side with the
  **total quantity and volume-weighted average unit price** of that day's trades.
- **Chart hover read-outs reworked (no more overlaps):** every read-out box now sits at its own
  value's height, a two-pass relaxation enforces minimum spacing (overlap-free by construction,
  compressing when space is tight), and the whole stack moves to the side of the crosshair where
  it covers the curve the least — rising graph to the right, boxes go left, and vice versa. When
  the series sit too close together for that, the whole stack lifts **above the highest data
  point** instead, clear of every graph. As a final safeguard, every candidate layout is **scored
  by how much of the surrounding chart it would cover** (nearby points of all series inside a
  box count against it, spilling over the value labels is penalized) — the least-covering
  placement wins.
- **New "Fair" toggle** next to "My trades": show or hide the purple Fair line (including its
  hover read-outs and right-edge label); persisted, on by default.
- **TOC bumped to Interface 11509** (patch 1.15.9 is live).

## 1.0.7 – 2026-07-27
- **Hotfix: "script ran too long" when typing in the Watchlist search.** The find-&-add search
  computed the full price analysis for **every** archive item matching the query — thousands for a
  short query, in a single frame. It now collects matches cheaply, pre-ranks them by market supply
  and prices only the top few.
- **Per-item metrics are now memoized** (until the next scan/sync/mail changes the data), so the
  Trades tab, Net Worth and repeated searches no longer re-price the same items over and over —
  refreshes across the whole UI get snappier and stay far under the script-time budget.
- Trades rows now use the per-item odds refinement (same numbers as everywhere else).
- **Fair hugs the market tighter.** For items with a decent (but not stellar) sell record the odds
  lift used to pin Fair at the +20% ceiling — permanently ~1.2x the trimmed base and well above the
  moving average (visible e.g. on Large Brilliant Shard). The lift is now capped at **+10%**, and the
  headroom above your measured clearing prices **scales with how strong the sell record actually is**
  (a record at ~coin-flip odds pins Fair AT the level your sales cleared, not above it).
- **The Fair line in charts is now computed per day** (each day's own trimmed base and floor) instead
  of projecting today's lift back over the whole history — it follows the market level historically
  and no longer paints a constant offset above it.
- **Trades: new "Avg Buy" column** (By Item) — the average unit price YOU paid, from your buy mails;
  sortable, with a header tooltip. Compare against Avg Sell / Fair for your real margin.
- **Trades: Shift-click opens the big chart** — on a By-Item row or any transaction row of an
  expanded item (plain click still expands/collapses).
- **"Moving avg" renamed to "Floor MA"** (toggle, chart label, hover read-outs): it averages the
  **daily cheapest buyouts** — a floor statistic. That's also why Fair may legitimately sit slightly
  above it when your own sales prove buyers pay more than the floor.
- **Net Worth: click a character** to open a full per-item view of everything it owns (bags, bank
  and mail merged; active auctions tagged **AH**), valued like Net Worth and sorted by value — with
  each item's share of that character's wealth. Click an item there for its chart; Back returns.
- **Net Worth: vendor-item fantasy prices no longer count.** Items anyone can buy from an NPC in
  unlimited supply (learned vendor list) are only valued at their AH price when **your own sales
  prove it** — otherwise at the vendor sell price. A stack of vendor throwing knives listed by
  trolls at 2g apiece no longer fakes hundreds of gold of net worth; genuinely flippable
  limited-stock vendor items keep their market value.

## 1.0.6 – 2026-07-23
- **Fair price reworked: trimmed market value + real sell odds.** The base of Fair is now a
  recency-weighted average of the **cheapest daily prices over the last 14 days** that **ignores
  up-outlier days** – days when only overpriced stock was listed. Such asks sit in the AH without
  meeting demand and used to inflate the old averaged Fair (it sat above the moving average for
  ~3 out of 4 items). On top of that base, Midas checks your **real outcomes** – sales **and** expired
  auctions, each compared to the item's floor and split by market liquidity – and **lifts Fair by up
  to 20%** when your sales prove buyers pay more (aiming for **~50% odds** that one 48-hour auction
  sells), but **never beyond just above the prices your sales actually cleared at** (reality brake –
  no extrapolated fantasy premiums). Fair is never pushed below the market level. Seeded from your
  logged history, self-tunes as data grows.
- **Sell odds everywhere:** item tooltips and detail cards show the estimated chance that a listing
  sells at the current price, and Fair carries its own odds – so you can see *why* a price is what it
  is. If the odds stay low even at Fair, Midas says so – the item is oversupplied (or the market too
  thin) and **posting less beats pricing lower**.
- **"You paid" in the item tooltip:** your personal average buy price per unit (from your auction-buy
  mails), next to the market numbers.
- Methodology tooltips ("?" on detail cards, column headers) rewritten in plain language.
- Net Worth values items at the new Fair – totals shift to the honest market level.
- The Fair line in charts follows the trailing trimmed market base (drifts with the market level).

## 1.0.5 – 2026-07-23
- **Hotfix: "script ran too long".** On a large price archive (thousands of items) opening Midas
  could trip WoW's script-time watchdog — Top Picks and Opportunities computed metrics for *every*
  item in a single frame. That analysis now runs in the **background, a few hundred items per
  frame**, and is cached: the window opens instantly and briefly shows "analyzing market data…"
  on first use while the first pass finishes. Same items, same numbers. The last-scan-day is cached
  and a cheap pre-filter skips items that can't qualify, cutting the work further. (Surfaced by the
  tighter script budget in the **1.15.9** client.)

## 1.0.4 – 2026-07-14
- **New price method — "Fair price" replaces the median.** The median of daily lows lags the market and
  sits below what actually clears; Fair is a recency-weighted (7-day half-life) average of the daily lowest
  buyouts, nudged toward the real clearing price, and — once you have ≥3 of your own sales of an item —
  anchored 50% onto your realized sale prices. Used everywhere (Top Picks, Opportunities, tooltips, and
  Net Worth valuation).
- **Liquidity / sell-speed signal.** Every item now shows Fast / Steady / Slow / Illiquid (and ~N sold per
  day for items you trade), because the main reason auctions expire is over-supply, not price.
- **Quick-sell price** for when you want speed over margin (at/just below the current floor).
- **Transparent methodology:** hover the new "?" on any detail card, or a column header, to see how each
  number is derived; item tooltips are relabeled to Fair / Sells / Quick-sell.
- Now **logs the listed price of expired auctions** (previously lost) to calibrate sell-probability later.
- **Charts:** reworked mouseover — the big chart shows the **price, moving average, quantity bar and Fair**
  each with its own marker, and all read-out boxes are anchored up-and-right of the column's **topmost point**
  (borderless, non-overlapping); small preview charts show a single compact read-out **floating just above the
  graph** so it never covers it (price + Qty/MA/Fair). The **Fair price is drawn as a line that moves over time**
  (recency-weighted, not a flat level), and the moving-average line is now **labelled** on the right like Fair.
- **Tooltips:** column-header help now opens **above** the header instead of below, so it no longer covers the
  table rows.
- **Net Worth:** the **By character** panel now always shows each character's **share** and its **change
  (% and gold)**; **scrub the net-worth history chart** to see every character's value **as of that day and how
  it changed to now**. (Per-character history builds up from this version onward.)
- **WoW 1.15.9 ready:** TOC interface updated (11508, 11509) and the item-click hook hardened.

## 1.0.3 – 2026-07-07
- **Cross-guild sync:** scan data now also spreads to nearby Midas users in **other guilds** at the
  auction house, not just your own guild. On by default; pick the range (Say / Yell) or turn it off in the
  **Sync** tab or with `/midas vicinity`. Only the tiny manifest/request messages use the public range –
  full scan data still goes over the guild channel, and everything stays invisible in chat.
- **Hardened send throttle:** Midas now checks each message's send result and backs off when the client
  would throttle it, with a conservative message/byte budget – so the *"Number of messages that can be sent
  is limited"* error can no longer appear. The **Sync** tab shows a throttle counter (it should stay 0).

## 1.0.2 – 2026-06-16
- **Charts:** added a search box; the side list now shows your **10 most recently
  viewed charts** instead of a fixed Top 10.
- **Shift-click links both ways:** shift-click an item in Midas to search it in the
  auction house; shift-click an item at the auction house — including inside
  **Auctionator's** tabs (Selling / Shopping / Cancelling) — to open its Midas chart.
- Bigger "Midas" wordmark; the Trades search box now sits in the same spot as on the
  other tabs for a consistent layout.

## 1.0.1 – 2026-06-16
- **Trades:** the History view now matches By Item — clean item names, plus Unit,
  Total and vs-Median columns. vs-Median is coloured by what's good for the trade
  (a sell above median is green, a buy below median is green; within the band grey).
- Each item is always one group in By Item (the stack-size suffix in mail subjects
  no longer splits it); sale unit prices are recovered from the subject.
- Added a search box to the Trades tab; fixed incomplete/duplicate trade entries.

## 1.0 – 2026-06-16
First public release. Midas is a self-contained auction-house market tool for WoW
Classic Era — it runs its own full AH scan and keeps a permanent price history
(no Auctionator required, no 21-day limit).

- **Top Picks & Opportunities** – items trading clearly below/above their median,
  plus an archive-wide flip ranking (margin × liquidity × confidence), sortable
  and searchable, with hover price charts.
- **Watchlist** – account-wide, curated by right-click.
- **Net Worth** – gold + item value + active auctions across all your characters,
  broken down by asset class with per-character and per-item breakdowns and a daily
  history (soulbound items excluded).
- **Trades** – realized history and a per-item sellability rating from your AH mail.
  Click an item in **By Item** to expand it and see each individual sale/buy/return
  with its price and per-unit price.
- **Charts** – smooth price history with a broker-style moving average, plus a
  weekday view (each week its own Monday→Sunday line).
- **Community sync** – Midas users on the same realm + faction share scan data
  automatically over WoW's invisible addon-message channel, so your archive stays
  fresh even on days you don't scan. Nothing shows in chat. A **Sync** tab shows it
  live and lets you turn it on/off.
