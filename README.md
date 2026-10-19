# Midas – AH Market Analysis (WoW Classic Era & WoW Forever addon)

In-game market tool: a Start dashboard, a personal watchlist, net-worth tracking and full-history price charts –
from its **own full auction-house scan** and a **permanent price history**
(no 21-day limit, **no Auctionator required**).

## Community
Questions, bug reports and feature ideas: **[Midas Discord](https://discord.gg/CfZgeyxAn5)**
(in game: Help tab or `/midas discord`).

## Supported game versions
- **Classic Era 1.15.9** (incl. Hardcore) – classic auction house, "GetAll" full scan.
- **WoW Forever beta 1.60.1** (modern client) – modern auction house, snapshot full scan
  (commodities included). Everything else works the same. The nearby (say/yell) sync layer is
  not available there – the client blocks it – so sync runs over guild and group.
  Known beta issue: the Forever beta sometimes fails to load saved addon data at login
  (Blizzard bug, affects all addons); Midas explains this in a one-time popup on Forever.
  Community workaround: [ForeverSVFix](https://github.com/nobewayo/ForeverSVFix) (third-party;
  re-run it after every Midas update).

Midas detects the client by its auction-house API, so the same download runs on both.

## Installation
Already located under `Interface\AddOns\Midas`. Enable it on the character screen
(tick "Load out of date AddOns" if needed) and `/reload` or log in again.

## How scanning works
Midas scans the whole auction house itself (Classic Era: "GetAll" full scan; WoW Forever: the modern
snapshot scan, commodities included):
- **Open the auction house** – a **Midas Scan** button appears at the top-right of the AH window.
  Click it to run a full scan; a **progress bar** shows while it runs.
- You can also scan with `/midas scan`, the window's "Scan AH" button, or a right-click on the minimap coin.
- Automatic scanning on AH open is **off by default** – turn it on in the **Settings** tab or with `/midas auto`.
- Every scan is stored permanently, so your history keeps growing.
- **Already scanning with Auctionator or aux?** Midas imports their price history
  automatically at login (up to 21 days from Auctionator) – a fresh install starts with
  populated tabs, and their scans keep flowing in. Your own scans always stay authoritative;
  `/midas import` forces a re-check.

The full scan is server-throttled to roughly once every ~15 minutes – that's a game limit, not the addon.

## Usage
- **Minimap button** (gold coin) – mouseover shows the best sells from your holdings;
  left-click opens the window, right-click runs a scan, dragging moves the button
  (hide it in the **Settings** tab if you prefer a clean minimap).
- **Alt-click any item** – a link someone posted in chat, an item in your bags, or any row
  inside Midas – **posts its price card into chat**: current price, fair (± vs fair),
  7-day floor and the all-time low, sent to your last-used chat channel (a whisper
  answers the same person). The one-click answer to a guildmate's "price check?".
- `/midas` – open/close the window (ESC closes too)
- `/midas help` – print this command list in-game (any unknown command shows it too)
- `/midas scan` – run a full AH scan now (must be at the auction house)
- `/midas auto` – toggle automatic scan on AH open (off by default; the Midas Scan button is the normal way)
- `/midas sells` – print sell tips from your holdings to chat
- `/midas trades` – print your trading summary (net P/L, sell-through) to chat
- `/midas share` – community sync on/off (on by default); `share on` / `share off` set it explicitly
- `/midas trust` – accept shared data from everyone (default, with sanity guards) or guild only
- `/midas vicinity` – cross-guild sharing with nearby players at the AH: `say` / `yell` / `off` (default `yell`)
- `/midas sync` – broadcast your data manifest now (kicks off a sync round)
- `/midas syncstatus` – show sync state: share/trust, cross-guild mode, rows in/out, peers, scope + throttle count
- `/midas commprobe` – transport test: pings guild + nearby players, prints pongs
- `/midas status` – archive status (items, daily values, last scan)
- `/midas import` – re-check other addons' price databases (Auctionator, aux) now
- `/midas vendor` – how many vendor-sold items Midas knows (excluded from picks)
- `/midas prune` – remove daily values beyond the horizon
- `/midas discord` – invite link to the Midas Discord (help, bugs, ideas) in a copy box

## Tabs
1. **Start** – the dashboard that greets you, in three rows: your **net worth** (change since
   yesterday / 7 days ago plus a sparkline) next to **MARKET TODAY** – the best BUY signals
   (today's picks trading clearly under Fair, merged with the highest-scoring opportunities of your
   whole archive) and the best SELL signals (liquid items clearly above Fair; vendor goods excluded);
   your **watchlist across the full width** split into **BUY LOW / SELL HIGH** vs Fair (it grows with
   the window – the focus of the page); and the **biggest character movers** since the last snapshot
   next to your **trading highlights** (best sale ever, best bargain of the last 60 days, latest
   trades). Cards jump to their tabs; item rows work like everywhere else – hover for the tooltip,
   left-click for the full chart, and **right-click any item to put it on your watchlist**.
2. **Watchlist** – the heart of Midas: your **account-wide** watchlist as a full ranked table (shared
   across all your characters). **Type in the search box to find & add items**, **right-click a row to
   remove** it, click column headers to sort; **hover a row** for the mini price chart + stats on the
   right, **left-click** for the full chart. Watched items feed the BUY LOW / SELL HIGH shortlists on
   the Start page.
3. **Net Worth** – your **account-wide** assets across all characters: **gold + item value + active auctions**,
   broken down by asset class (Money, Crafting, Consumables, Gear, Recipes, **Auctions**, Other) and per
   character. **Hover any value** (the big total, an asset-class bar or a character row) for a breakdown into
   the actual characters and items behind it. Active auctions are counted at a discount based on how likely
   they are to sell (high-volume mats keep most of their value, expensive BoE gear is discounted hard).
   A snapshot is stored once a day, so the net-worth line chart grows over time.
   **The whole tab reads ONE timeframe** (the 1W / 1M / 3M / All switch): the hero line decomposes the
   change into **market** (prices moving under what you hold), **quantity** (what you gained/consumed),
   **gold** and an honest rest; **TOP GAINERS / TOP LOSERS** name the items behind it right in the header;
   the class and character lists show their change over the same window; and **"what moved?"** opens the
   full account-wide item breakdown – every item's quantity and market effect plus its realized trading,
   sorted by impact, each row one click from its holding history. The drill-downs carry the same window:
   a character's items show their market change, a class's top items their change column, a clicked
   chart day offers **"What moved since?"** attributed against exactly that day, and every change
   column on the tab names its reference date. Fallen (HC)
   characters can be **moved to the graveyard** from their drill-down: they stop counting toward
   the total and rest in a separate graveyard sum - nothing is deleted, and logging in on the
   character (or one click) brings it back.
4. **Trades** – your realized trading history and a **sellability** rating per item, built from the AH mail
   you collect, your vendor buys and the player trade window. A segmented toggle switches between **History**
   (a chronological log of sells, returns and buys with the net amount, character and trade partner) and
   **By Item** (per-item aggregate over the last 60 days: sold/returned auctions, sell-through %, a rating chip,
   avg sell/buy, the realized **margin** of the units you sold and the net cash flow, plus a price chart on
   hover; **click a row to expand** it into the individual transactions, each judged against that day's Fair).
   A summary strip on top shows net P/L, holdings change, gross sells, AH fees, gold spent buying,
   sold/returned counts and overall sell-through over one shared window.
5. **Charts** – the item's full price history on a real time axis, drawn as a smooth
   anti-aliased curve (missing scan days show as dashed gaps), with Floor MA, the Fair line and
   your own buys/sells as dots – all toggleable from the top-right of the window. A **timeframe
   switch** (1W / 1M / 3M / All) on the plot zooms every big chart, including Net Worth.
   The **offer book** button shows every price the item is listed at in your newest full scan
   (cheapest 20) as a ladder, cheapest on top: each price is a row whose bar continues a cumulative
   "tree" (grey = everything cheaper, green = this price under Fair, gold = above). Fair, quick-sell,
   the 7-day floor, your own buy/sell price and the average ask of your own active auctions sit in between as slim colored rows, their line
   ending at the supply you would have bought through by then. A summary card shows the floor, the
   cost of everything under Fair and what it takes to buy up to each marker (buyout only, no seller
   names; the AH has no buy orders). A **split** button next to the offer book shows the price
   chart on the left and the supply ladder on the right, and the chart / offer-book headers carry
   the item's icon.
   Bigger new features introduce themselves once after an update with a short what's-new note
   (`/midas news` shows it again).

6. **Settings** – everything configurable in one place. **General:** the item-tooltip style
   (**Full / Reduced / Off**, with a live preview of exactly what each produces), the minimap
   button on/off, auto-scan on AH open, the default chart timeframe and a separate
   timeframe for the small preview cards. **Community sync:**
   on/off, whose data to accept (everyone / guild only), the **cross-guild (nearby)** channel
   (Off / Say / Yell), a compact status (peers, rows in/out, throttle counter) and a **live log**
   of each scan, beacon and backfill. (`/midas share on|off`, `/midas vicinity` and
   `/midas syncstatus` still work from chat.)

7. **Help** – how the numbers are made, for humans: Fair and the sell odds explained with a
   worked example and two illustrative charts, plus a one-line glossary of every figure in the UI.

Also: **item tooltips** show current price, the **Fair price** (with its sell odds), sell speed, a
quick-sell price, your estimated **sell odds at the current price**, what **you paid on average** for the
item (from your logged buys), plus current and average quantity in the AH and how much is listed within 10 % of the cheapest price – with a colored marker
(green = below Fair, red = above, the same rule as every table). Pick the style in **Settings** (Full / a two-line Reduced /
Off). Inside the Midas window the tooltip stays vanilla – the table row and detail card already
show those numbers.

## How prices are calculated (trimmed market value + real sell odds)
**Fair is the short-term market value with the no-demand asks removed, checked against your real
outcomes.**
- The **base** is a recency-weighted average of the **cheapest daily prices over the last 14 days** –
  but days when only overpriced stock was listed are **ignored** (an ask that sits in the AH without
  demand says nothing about value; it must not inflate Fair).
- Midas also logs every real outcome of your auctions – **sales AND expiries** (an expired auction's
  listed price is remembered too) – and compares each ask to the item's floor, split by market
  **liquidity**. When that measured sell-chance curve proves that **buyers pay more**, Fair is **lifted
  up to 10%** above the base (aiming for **~50% odds** that one 48-hour auction sells) – but **never
  beyond the prices your sales actually cleared at**, so the curve can't extrapolate a fantasy
  premium. It self-tunes to your own history as it grows.
- **Sell odds** are shown next to Fair and for the current price, so you always see *why* a price is
  what it is – and how likely the market is to take it.
- Fair is **never pushed below the market level**: if the odds stay low even at Fair, the item is
  oversupplied (or the market too thin) and **posting less beats pricing lower**.
- **vs Fair** is green when the current price is below Fair (cheap), red when above (pricey), grey within
  ±10%. The BUY/SELL "Today" call uses the same basis (±15%).
- **Sell speed / liquidity** (Fast / Steady / Slow / Illiquid, plus ~N sold per day for items you trade)
  is shown as well, because the main reason things don't sell is **over-supply, not price** – so don't
  post more than the market absorbs per day.
- **Quick-sell** is a fast, at-the-floor price (~2% under floor/Fair) for when you want speed over margin.

Hover the **"?"** on any item's detail card, or a table column header, to see the method in-game.

## Community sync (share scan data with other Midas users)
Midas users share scan data automatically, so your archive grows even on days you don't scan –
because someone else did. It works in two layers:
- **Guild** (always on): after each scan Midas sends the rows that scan changed to your **guild**
  (and your party/raid if grouped); on login and at the AH it also shares a small **manifest** (per-day
  row counts) so guildmates can pull anything they're missing.
- **Cross-guild / nearby** (on by default, `yell`; Classic Era only – WoW Forever blocks say/yell addon messages): at the auction house Midas also beacons that tiny
  manifest to **nearby players in other guilds** and answers their backfill requests – that's how data
  crosses guild boundaries, since Midas users meet at the AH. Pick the channel or turn it off in the
  **Sync** tab or with `/midas vicinity say|yell|off`.

- **Completely invisible:** everything travels over WoW's hidden addon-message channel (`CHAT_MSG_ADDON`),
  which the chat UI never shows – players with or without the addon see **nothing**, and nothing appears in
  say/yell/guild chat or `/chatlog`. The say/yell setting only sets the delivery *range* of those invisible
  messages, never any visible text. (Questie, NovaWorldBuffs etc. work the same way.)
- **Never trips the chat throttle:** the send pump checks each message's result and, if the client would
  throttle it, keeps the message and backs off instead of forcing it through; a conservative message + byte
  budget keeps the sustained rate well under the limit. So the *"Number of messages that can be sent is
  limited"* error can't appear. Only the light pull traffic (manifest + request) ever uses the public range –
  full scan data always stays on the guild channel.
- **Why it stays consistent:** daily values merge with fixed rules – `low = MIN`, `qty = MAX`,
  current price = **latest scan wins** (by scan timestamp). These merges are order-independent and
  idempotent, so every client converges to the same archive no matter who sent what, or over how many hops.
- **Safety:** rows are bounds-checked, and an absurd undercut (below 5% of the known price) from outside
  your guild is dropped. `/midas trust` restricts to guild-only data; `/midas vicinity off` drops the
  cross-guild layer; `/midas share` turns the whole feature off. Traffic is rate-limited and pauses during scans.
- Backfill covers the last 60 days; the full history can still be shipped as `MidasImport.lua`.

## Net worth tracking
Net worth is kept per **realm + faction**: only characters that trade on the same auction house are
added up, and each scope keeps its own daily history.
Each character stores its own bags + money (bank/mail/**active auctions** while the respective window is open).
The **Net Worth** tab sums these across all your characters, values items at their market **Fair price** (or vendor
price), adds the value tied up in active auctions, and writes one daily snapshot to `MidasDB` – so the history
grows by itself. Accuracy improves the more you log into each character (and visit your AH **Auctions** tab so
the active lots get cached).

**Soulbound items are ignored:** a BoE only has market value while it is still unbound, so once it has been
equipped (now soulbound) – or for any looted BoP item – it no longer counts toward net worth.

**Auction discount:** an active auction is not realized gold yet, so it is counted at `ask × sell-chance`.
The sell-chance is high for liquid mats (Crafting ~0.90, Consumables ~0.86) and low for slow movers (Recipes
~0.62, Gear/BoE ~0.45), with an extra haircut the more expensive the listing is (e.g. a 100g+ BoE is cut hard).
This keeps net worth realistic instead of valuing an overpriced BoE at its full asking price.

## Trading history & sellability
The **Trades** tab needs no setup beyond **collecting your auction-house mail**. Whenever your mailbox is open,
Midas reads the AH mails and records each event into `MidasDB.trade` (account-wide):
- **sold** – your auction sold (net proceeds = the gold actually in the mail; the AH cut is read from the invoice),
- **returned** – an auction expired and came back unsold,
- **bought** – you won an auction (counts against your profit),
- **outbid** – your bid was refunded (logged, but never counted as profit).

Mail subjects are matched via WoW's own localized strings, so this works in every client language, and each
physical mail is de-duplicated so re-opening the mailbox never double-counts. Trades are dated by the day
their mail arrived.

Two more sources join the ledger:
- **vendor buys** – booked once the gold has left; buys of items you never sell (arrows, drinks) count as
  own use, not as trading cost,
- **the player trade window** – items one way and gold the other book as *Trade sell* / *Trade buy* (the gold
  split over several items by Fair); swaps and gifts are listed without a price, trades with your own
  characters are transfers and stay out. Trade-window sales count toward your gold, not toward the
  auction sell-through.

**Sellability** is the sell-through rate over the last 60 days: `sold / (sold + returned)`.
- **Underpriced** (~all sold) → you probably could have asked for more,
- **Well priced** (some sold, some returned) → the price was about right,
- **Overpriced** (~all returned) → it was listed too high.

Items need at least 3 finished auctions in the window before they get a rating. Thresholds live in `Core.lua`
(`SELL_WINDOW`, `SELL_MIN_N`, `SELL_HOT`, `SELL_COLD`).

**Minimap sell tips:** mouseover the minimap button lists 3–4 items from your **own holdings**
(bags, bank, mail) whose current price is above **Fair** – sorted by sell score
(distance above Fair × liquidity × confidence). Bags are read live; bank and mail are remembered
once you open the respective window.

## Public API (for other addons / TSM)
Midas exposes its numbers on the global table **`MidasAPI`** (available as soon as the addon
loads; no embedding needed). Prices are **copper**, odds are fractions (0–1), and every getter
returns `nil` while Midas has no data for the item. `item` accepts an itemID (number or string),
a full **item link**, or a raw archive key (`gr:...` for suffixed gear).

- `MidasAPI.GetFairPrice(item)` / `GetCurrentPrice(item)` / `GetQuickSellPrice(item)` – the three
  headline prices. **TradeSkillMaster** can consume them directly as external price sources
  (e.g. `MidasMarket`, `MidasCurrent`, `MidasQuickSell`) – TSM passes item links, which work as-is.
- `MidasAPI.GetSellOdds(item, ask)` – estimated chance that ONE 48h auction at `ask` sells
  (omit `ask` for the current price).
- `MidasAPI.GetMarketInfo(item)` – one table with fair/current/quick, odds, opportunity score,
  median/min/max, 7-day floor, liquidity class, avg daily quantity and data depth.
- `MidasAPI.GetHistory(item, days)` – the daily price series `{day, time, low, qty}`, oldest first.
- `MidasAPI.GetDepth(item)` – the offer book (sell-side depth) of the newest scan `{ts, units, auctions, levels}`;
  `GetDepthSnapshot()` returns it for every item plus the market (client, region, realm, faction, ruleset).
- `MidasAPI.GetTradeStats(item)` – your own record: sold/expired, sell-through, avg buy,
  median sell, sales per day, sellability rating.
- `MidasAPI.GetNetWorth()` – account totals (money/items/auctions, graveyard, per character).
- `MidasAPI.GetItemKeys()`, `GetLastScanDay()`, `GetLastScanTime()`, `GetVersion()`, `IsReady()`.
- `MidasAPI.RegisterCallback(event, fn)` for `"SCAN_COMPLETE"`, `"ANALYSIS_COMPLETE"` and
  `"IMPORT_COMPLETE"` (plus `UnregisterCallback`).
- `MidasAPI.RegisterImportSource(def)` – feed your addon's price history **into** Midas
  (same contract as the built-in Auctionator/aux sources, see `Import.lua`).

`/midas api` prints the API status in-game; full signatures are documented at the top of `API.lua`.

## Notes
- **Modern flat UI in the Midas gold theme** – warm dark backgrounds, gold edges, and every
  price/value line drawn in gold ("what Midas touches turns to gold"); cool blue marks secondary
  statistics (Floor MA, trimmed days), green/red/purple keep their buy/sell/Fair meaning.
  Ships with a bundled **Inter** font (folder `Midas\Fonts\`) – keep that folder when copying the
  addon; if it is missing, Midas automatically falls back to a built-in font.
- Self-contained: **Auctionator is not required** (any previously imported data stays in the archive).
- Accuracy grows with regular scanning incl. weekends.
- Data source = only what you scan yourself at the AH.
- Vendor items are learned automatically whenever you open a merchant (unlimited, gold-only items),
  and seeded once from Auctionator's vendor cache if that addon is still installed – so they drop out
  of the picks over time. Check the count with `/midas vendor`.

## Parameters
All thresholds live in `Core.lua` under `M.C` and mirror the Excel logic
(`opportunities.py` / `build_full.py`).
