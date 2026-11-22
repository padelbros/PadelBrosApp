# PadelBros App – History & Context

**Read this before you start working on the app.** It explains what the app is, how it was built
before this repository existed, what changed when it moved to GitHub, and the rules for working on it now.
For setup commands see [README.md](README.md).

---

## 1. What the app is

The internal app of **PadelBros** (padel academy / club), live at **https://app.padel-bros.de**.
It is used by players, coaches, staff and admins on their phones, installed as a PWA
(“Add to Home Screen”). The interface is **German**, with a built-in **English** mode
(translation layer inside `index.html`, user's choice stored in the `language` column of `players`).

Main features:

- **Teams & training sessions:** fixed teams in time slots, a training calendar
- **Absences & replacement pool:** a player reports an absence, others apply as a replacement,
  the absent player confirms; €25 is paid directly between the players (payment info in-app)
- **Private chat** between the absent player and their replacement
- **Team watching:** get notified when a spot opens in a team you follow
- **Tasks & boards** (Notion-style): tasks, checklists, comments, history, recurring/daily tasks
- **Events** with their own task board, staff assignment and comments
- **Shift schedule (Dienstplan)** for staff: weekly/monthly planning, confirming shifts,
  sick reports, open-shift alerts, reminders 7 days / 24 h / 2 h before a shift, calendar export (.ics)
- **Notifications** in the app and as **push messages** on the phone
- **Suggestions** (improvement ideas) that can be turned into tasks
- **Coach dashboard** and admin views (who is logged in, player management, profile pictures)

User roles (flags on `players`): `is_admin`, `is_super_admin`, `is_manager`, `is_staff`,
`is_coach`, `is_shift_planner`, `is_guest`.

The app can also be embedded in the Shopify website (`PB_CONFIG.embedded`). Its CSS is scoped
to `.pb` so it doesn't affect the shop theme.

---

## 2. Architecture

```
Phone / browser (PWA)                       Supabase project nweoqhozcbrkihktqyqc
┌─────────────────────────┐                 ┌───────────────────────────────────────┐
│ app/index.html          │  supabase-js    │ Auth (login by email code)            │
│  (HTML + CSS + JS, one  │ ──────────────► │ Postgres: ~34 tables, RLS policies,   │
│   file, ~3,200 lines)   │  anon key       │   ~75 functions (RPC), triggers       │
│ app/config.js           │                 │ pg_cron: shift reminders every 15 min │
│ app/sw.js  (cache/push) │ ◄── push ────── │ Edge Function send-push (Deno)        │
└─────────────────────────┘                 │   ← called by DB trigger via pg_net   │
   hosted on Netlify                        └───────────────────────────────────────┘
```

- **No build step, no framework, no npm.** Plain HTML/CSS/JavaScript. The Supabase JS library
  is loaded from a CDN at runtime.
- **Security lives in the database:** Row Level Security policies and `security definer`
  functions decide who may see or change what. The `anon` key in `config.js` is public by design.
- **Notifications flow:** app action → DB function inserts a row into `notifications` →
  trigger calls the `send-push` Edge Function → Web Push to every device of that person.
  Push texts deliberately contain **no names, free text or health data** (GDPR); details are
  only visible inside the app.
- **Service worker** (`sw.js`) caches only the app shell, never data. Its cache name
  (`pb-app-vNN`) must be raised on every app release, or installed apps keep the old version.

---

## 3. How it was built before (until November 2026)

There was **no version control, no repository and no test environment**. Development worked like this:

- Changes were delivered as **complete files**: a zip of the whole `app/` folder, numbered
  **SQL update scripts** (“Update 1” … “Update 26”) and the Edge Function code as a text file.
- The zip was **uploaded to Netlify by hand** (drag & drop).
- Each SQL update was **pasted into the Supabase SQL editor** and run on the live database.
- The Edge Function was **pasted into the Supabase dashboard**.
- There was no record of what had been applied, no history, and no way to roll back.

What was handed over (22 Nov 2026), now in this repo:

| Original file | Now |
|---|---|
| `PadelBros_App_NetlifyJunn.zip` (app as of 20 Nov 2026, service worker `pb-app-v23`) | `app/` |
| `send-push_CodeJunn.txt` | `supabase/functions/send-push/index.ts` |
| `Update_Schicht_ErinnerungenJunn.sql` (Update 26: shift reminders) | `supabase/migrations/20261122000026_shift_reminders.sql` |

Updates 1–25 were never saved as files. They exist only in the live database, which is why
the schema was exported (see below).

---

## 4. What changed: the move to GitHub (22 Nov 2026)

1. **Git repository** created and pushed to **github.com/padelbros/PadelBrosApp** (public).
2. **Folder structure:** `app/` (website), `supabase/migrations/` (SQL), `supabase/functions/`
   (Edge Functions), `.github/workflows/` (automation).
3. **Netlify connected to GitHub:** every merge into `main` is published automatically to
   app.padel-bros.de. Branches and pull requests get **preview links**. `netlify.toml` publishes
   `app/` and turns off browser caching for `index.html`, `sw.js` and `config.js`.
4. **Database baseline:** a GitHub Action exported the live database structure (no data) into
   `supabase/migrations/20261101000000_baseline.sql`. It contains Updates 1–25 and is marked
   as already applied, together with Update 26, so neither is ever run again.
   *Not* in the export: the `storage` schema (avatar bucket + policies) and the `pg_cron` job
   entries (they are created by the Update 26 file).
5. **Automatic Supabase deploys** (`.github/workflows/supabase-deploy.yml`), on every push to `main`
   that touches `supabase/`:
   - runs every **new** SQL file in `supabase/migrations/` on the **live** database
   - deploys the `send-push` function **only if its code changed**
   - secrets (`SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`, `SUPABASE_PROJECT_ID`) are stored
     in GitHub → Settings → Secrets, never in the code
6. **`main` is protected:** changes go through branches and pull requests.

---

## 5. How to work on it now

### Golden rules
1. **`main` = live.** Never push directly to `main`. Work on a branch and open a pull request.
2. **Nothing is edited by hand anymore**: not in the Supabase SQL editor, not in the Supabase
   Edge Function editor, and no zip uploads to Netlify. The next deploy from GitHub would
   overwrite or contradict manual changes.
3. **There is no test database yet.** Local testing, preview links and the live app **all use
   the live database with real data**. Anything you click (delete, send, assign) really happens.
   Test carefully, ideally with your own account.
4. **Demo mode is currently not available.** The app only runs in demo mode if `config.js` has
   no Supabase details **and** a file `app/demo-daten.js` exists. That file was not part of the
   handed-over zip.

### Workflow
```
git checkout main && git pull
git checkout -b feature/short-name
# change files, test locally:  cd app && python3 -m http.server 8000  → http://localhost:8000
git add -A && git commit -m "What was changed"
git push -u origin feature/short-name
# GitHub: "Compare & pull request" → check the Netlify preview link → Merge
```
After the merge, everything is automatic: Netlify publishes `app/`, and GitHub Actions runs
new SQL and deploys `send-push` if it changed.

### Changing the app (`app/`)
- Raise the cache name in `app/sw.js` (`pb-app-v23` → `pb-app-v24` …) in every pull request
  that changes `app/`. If two branches raise it at the same time, use the next free number.
- Keep German as the source language. Add an English translation for every new visible text
  (the `I18N_EN` table in `index.html`) and, for push texts, in `send-push/index.ts` (`EN`).
- `index.html` is large and has clearly marked sections (`/* ===== … ===== */`). Search for
  the section title before adding code.

### Changing the database (`supabase/migrations/`)
- One new file per change: `YYYYMMDDHHMMSS_short_name.sql` (the timestamp must be later than
  all existing files).
- **Never edit an existing migration file.** It has already run on the live database.
- **Only add:** new tables, columns and functions are fine. Don't drop or rename anything the
  current app uses, because old app versions stay open on phones for a while.
- Make scripts safe to run twice (`if not exists`, `create or replace`).
- For a security check, keep RLS enabled on new tables and add policies.

### Changing push notifications (`supabase/functions/send-push/`)
- Don't put names, free text or health data into push titles or bodies (see the comments in the file).
- `verify_jwt = true` in `supabase/config.toml` must stay as it is. The database calls the
  function with the anon key.

---

## 6. Open points

- [ ] **Test environment:** a second (free) Supabase project for branches and previews, so new
      SQL and features can be tried without touching live data
- [ ] Recreate demo data (`app/demo-daten.js`) or remove demo mode
- [ ] Check the Supabase GitHub integration (“Supabase Preview” check) and keep
      “Deploy to production” switched off there, because GitHub Actions does this job
- [ ] Add the `storage` setup (avatar bucket + policies) as a migration file
- [ ] Longer term: split `index.html` into separate files

---

## 7. Change log

Add a line here for every notable change (newest first).

| Date | Change |
|---|---|
| 2026-11-22 | Moved to GitHub; Netlify and Supabase deploys automated; database baseline exported; this file added |
| 2026-11-20 | Last hand-delivered version (zip, service worker `pb-app-v23`) and Update 26 (shift reminders) |
