# Cabal Coffers Store: Design Notes

## Contents

1. Version log
2. Overview
3. Database
4. Visitor counter
5. Admin setup
6. Card import (from Card Binder)
7. Open items

## 1. Version log

| Version | Date (Pacific) | Change |
|---|---|---|
| v0.0.1 | 2026-10-12 16:45 | Database setup: posts, admins, image storage, visitor counter. No page yet. |

## 2. Overview

Single-file `index.html` hosted on GitHub Pages at `https://ianmcgo.github.io/cabalcoffers/`. Supabase project `nbvurlukgysarlpibafy` holds posts, the admin login and the visitor counter. Look and feel follow `https://ianmcgo.github.io/website/` (green phosphor CRT theme, VT323 and Share Tech Mono), without the spaceship demo.

Links:

| Tile | URL |
|---|---|
| TCGplayer | `https://shop.tcgplayer.com/sellerfeedback/7693ee8d` (the only public view of the listings) |
| eBay | `https://www.ebay.com/str/cabalcoffers` |
| Deckbox | `https://deckbox.org/users/cabalcoffers` |
| Patreon | `https://www.patreon.com/cw/ianmcg` |
| Personal site (Cabal Coffers Gaming logo) | `https://ianmcgo.github.io/website/` |
| YouTube | channel URL still needed |

## 3. Database

Setup file: `supabase/migrations/0001_init.sql`. It can be run more than once safely.

### posts

| Column | Notes |
|---|---|
| `type` | `tcgplayer`, `deckbox`, `ebay`, `youtube` or `note` |
| `title`, `body` | Up to 300 and 20,000 characters |
| `url`, `image_url` | Must start with `https://` |
| `price` | eBay listing price |
| `cards` | JSON array of resolved cards for TCGplayer and Deckbox posts, so visitors never wait on card APIs |
| `card_count`, `est_value` | Summary numbers shown on the post header |
| `pinned` | Pinned posts sort first |
| `published` | `false` is a draft, visible only to the admin |

The `posts_feed_idx` index serves the main feed query (published, pinned first, newest first). `posts_type_feed_idx` serves the filter chips.

### Security model

The publishable key is public by design. All protection comes from row level security:

- `admins` lists the user ids allowed to post. `is_admin()` checks the logged-in user against it.
- Anyone can read published posts. Admins also see drafts.
- Only admins can insert, update or delete posts.
- Storage bucket `post-images` is public to read, admin-only to write, 5 MB per file, images only.
- The visitor tables cannot be read or written directly; only through the counter functions below.

Tested locally on Postgres 16 with stand-ins for Supabase's `auth` and `storage` schemas. Anonymous and non-admin users were blocked from inserting, updating and deleting posts; non-admin users could not see drafts.

## 4. Visitor counter

Separate from the personal site, starting at 0. Function names and return shapes match what the personal site's Visitor Log code expects, so that code carries over unchanged.

| Function | Returns |
|---|---|
| `bump_site_views()` | New total; also logs today's country and the current hour |
| `get_site_views()` | Current total, used after the visitor has been counted today |
| `bump_site_view_device(p_device)` | Logs `mobile` or `desktop` for today; anything else counts as desktop |
| `my_country()` | Two-letter country code from Supabase's `cf-ipcountry` request header, `ZZ` when unknown |
| `get_country_views()` | `country, views, last_seen` |
| `get_country_firsts()` | `country, first_seen` |
| `get_daily_views(n)` | `day, views` for the last n days |
| `get_country_daily(n)` | `day, country, views` for the last n days |
| `get_hour_views()` | `hour, views`, hours in UTC |
| `get_device_views(n)` | `day, device, views` for the last n days |

Day ranges are capped at 3,650 days. The page counts each browser once per day (localStorage), as on the personal site.

## 5. Admin setup

1. Supabase dashboard, SQL Editor: run `supabase/migrations/0001_init.sql`.
2. Authentication, Users, Add user: create the admin login with email and password.
3. Authentication, Sign In / Providers: turn off "Allow new users to sign up".
4. SQL Editor: run `supabase/setup_admin.sql`. The last query should list the admin email.
5. Authentication, URL Configuration: set Site URL to `https://ianmcgo.github.io/cabalcoffers/`.

## 6. Card import (from Card Binder)

The TCGplayer and Deckbox composer reuses `card-binder.html`:

- Text export lines like `1 Transit Mage [DFT] 70`, `1x`, `(SET)`, foil markers `*F*`, `(Foil)`, trailing `Foil`.
- CSV exports matched by header name through the `ALIAS` table; Product ID gives TCGplayer CDN images for any game.
- Lookup order: TCGplayer Product ID, Scryfall batch (75 per request, 110 ms apart), then per-card fallbacks for Scryfall by name, Pokémon TCG API, YGOPRODeck, Lorcast, then a placeholder.
- Each resolved card is stored as `{ img, back, name, setName, setCode, num, rarity, type, price, link, source, game }` plus the row's `qty`, `printing` and `condition`.

Lookups run once in the admin's browser before publishing. Risks carried over: the TCGplayer CDN pattern is undocumented, the Pokémon TCG API host may move, and YGOPRODeck prefers cached images for public sites.

## 7. Open items

- YouTube channel URL for the link tile.
- Supabase connector cannot reach project `nbvurlukgysarlpibafy`; SQL is run by hand until the owning account is connected.
