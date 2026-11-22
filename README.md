# PadelBros App

Internal app for PadelBros (teams, replacement pool, tasks, events, shift schedule, chat, push notifications).
Live at **https://app.padel-bros.de**.

## How it is built

| Part | Where | What |
|---|---|---|
| Frontend | `app/` | Static PWA, no build step. Almost everything is in `app/index.html` (HTML + CSS + JS). Hosted on **Netlify**. |
| Config | `app/config.js` | Supabase URL + **anon** key (public by design, protected by Row Level Security). |
| Offline / install | `app/sw.js`, `app/pwa.js`, `app/manifest.webmanifest` | Service worker (caches the app shell only), install banner, push display. |
| Database | Supabase project `nweoqhozcbrkihktqyqc` | Tables, RLS policies, RPC functions, triggers, `pg_cron` jobs. |
| DB changes | `supabase/migrations/` | SQL files, one per change, applied in filename order. |
| Push sender | `supabase/functions/send-push/index.ts` | Supabase Edge Function (Deno) that sends Web Push for new rows in `notifications`. |

## Daily workflow

1. Change files.
2. Test locally: `cd app && python3 -m http.server 8000` → open http://localhost:8000
   (the app also has a built-in demo mode that works without Supabase).
3. **If you changed anything in `app/`, bump the cache name in `app/sw.js`**
   (`pb-app-v23` → `pb-app-v24`), otherwise installed apps keep the old version.
4. Commit: `git add -A && git commit -m "Short description of the change"`
5. Deploy (see below).

## Database changes

Never edit the database "by hand" without also saving the SQL here.

1. Create a new file in `supabase/migrations/` named `YYYYMMDDHHMMSS_short_name.sql`.
2. Write the SQL so it can run more than once (`if not exists`, `create or replace`).
3. Apply it (Supabase SQL editor, or `supabase db push` once the CLI is set up).
4. Commit the file together with the app change that needs it.

> ⚠️ Updates 1–25 were run directly in the Supabase SQL editor and are not in this repo yet.
> The next step is to export the current database schema as a baseline (see "Open TODOs").

## Edge Function

Deploy after changing `supabase/functions/send-push/index.ts`:
`supabase functions deploy send-push` (or paste into the Supabase dashboard as before).
Secrets (`SUPABASE_SERVICE_ROLE_KEY`, VAPID keys in table `push_keys`) live in Supabase, **never in this repo**.

## Open TODOs

- [ ] Export current DB schema as baseline migration (`supabase db pull`)
- [ ] Push repo to GitHub (private)
- [ ] Connect Netlify to GitHub for automatic deploys
