# City Limit Auto — Website Starter

Plain HTML/CSS/JS, no build tools required. Open `index.html` directly in a
browser to preview, or use a local server (e.g. `npx serve .`) for the best
experience with relative links.

## Structure

- `index.html` — Home
- `inventory.html` — Full inventory grid with search/filter
- `financing.html` — Financing info + inquiry form (placeholder)
- `about.html` — Company story
- `contact.html` — Contact info + form (placeholder)
- `assets/styles.css` — Shared design system (colors, type, all components).
  Edit here to change the look of every page at once.
- `assets/site.js` — Inventory rendering/filtering, the photo lightbox,
  and the Formspree submit handler shared by both forms.
- `assets/inventory.json` — Published inventory data, regenerated
  automatically by `sync/sync-inventory.ps1`. Don't hand-edit; it gets
  overwritten on the next sync run.
- `sync/` — The office-server sync script that pulls inventory + photos
  from the sales system and publishes them here. See `sync/README.md`.

## Design system

Industrial dealer aesthetic — black/steel palette with a brand-blue
accent, matched to the company logo. Headline font: Oswald. Body: Inter.
Data/unit numbers: IBM Plex Mono. Color tokens are CSS variables at the
top of `styles.css` — change
those to retheme the whole site.

## Status

- **Inventory data**: live, synced automatically from the sales system —
  see `sync/README.md`.
- **Forms**: Financing and Contact both submit to Formspree.
- **Trailer photos**: cards show a real photo when the sync finds one
  (matched by VIN against the shared OneDrive photo folder), otherwise a
  plain "Photo Coming Soon" placeholder. Click a photo to open the full
  gallery for that unit.
- **Contact info**: real phone/email/address/hours, matched to the live
  Wix site.

## Still to do before going fully live

- Deploy the site somewhere public (Netlify recommended) and point the
  sync script's git push at that repo — right now it only updates the
  local `assets/inventory.json`.
- Move the sync script to run on the office server instead of this
  machine, so it doesn't depend on WiFiman — see the bottom of
  `sync/README.md`.
5. **Dealer advertising compliance**: California dealers are subject to
   CVC §11713.1 bait-and-switch advertising rules — have pricing/inventory
   claims reviewed before launch.

## Deployment

This is a static site — any static host works (Netlify, Vercel, GitHub
Pages, Cloudflare Pages). Point your domain's DNS at the new host once
you're ready to go live; no need to touch your current Wix site until
the new one is ready.
