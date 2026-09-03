# Nama Nameng — Supabase Setup Guide

**Project:** Nama Nameng Ordering, Payment & Queue Management System
**Module:** ITC327W — Work-Integrated Learning
**Companion file:** `supabase_schema.sql` (run this alongside following the steps below)

This guide walks through setting up the shared Supabase backend that both the Flutter mobile app and ASP.NET web dashboard connect to, as specified in SRS sections 11.3, 14.4 and 15.

---

## Why Supabase, and what it's actually doing

Before the steps — the mental model matters for your defence, because you'll be asked "what does Supabase actually do here?"

Supabase is three services bundled together, all built on a single PostgreSQL database:

1. **Database (Postgres)** — stores your menu, orders, and user profiles as ordinary relational tables.
2. **Auth** — handles signup/login and issues a JSON Web Token (JWT) per user. That JWT is what proves identity to the database.
3. **Realtime** — a WebSocket layer that pushes database changes to connected clients instantly, instead of apps having to poll ("has anything changed yet?") every few seconds.

The reason this fits your integration requirement (SRS §15 — "single source of truth") is that Flutter and ASP.NET never talk to each other directly. Both talk *only* to Supabase, and Supabase enforces who can see and change what via **Row Level Security (RLS)** — rules written once, in the database, that apply no matter which app or which request is asking.

---

## Step 1 — Create the Supabase project

1. Go to supabase.com → **New Project**.
2. Choose a region close to your users (South Africa isn't listed directly — pick the nearest, e.g. an EU or AP region — check the current latency figures for your final feasibility notes).
3. Set a strong database password and **save it** — you'll need it if you ever connect a raw Postgres client.

**Why this matters:** once created, you get three credentials from Project Settings → API:
- **Project URL** — the address both apps will call.
- **anon public key** — safe to embed in the Flutter app and ASP.NET client-side code; it identifies "an app calling on behalf of some user," and RLS is what actually restricts what that key can do.
- **service_role key** — bypasses RLS entirely. Never put this in the mobile app or in client-side web code. Only use it in trusted server-side admin scripts, if at all, for this project.

Create a `.env` file locally for these and add `.env` to `.gitignore` **before your first commit** — your assessment brief explicitly prohibits uploading credentials to GitHub.

---

## Step 2 — Understand the schema before you run it

Open `supabase_schema.sql`. Six tables, each mapped to a specific requirement:

| Table | Maps to | Why it exists |
|---|---|---|
| `profiles` | FR-01, FR-05 | Extends Supabase's built-in `auth.users` with a `role` column. Supabase won't let you add columns directly to `auth.users`, so this is the standard workaround. |
| `menu_categories` / `menu_items` | FR-02, FR-06 | The digital menu, editable by staff, readable by everyone. |
| `orders` | FR-03, FR-04, FR-07, FR-08 | One row per order, with a `status` that both apps watch. |
| `order_items` | FR-03 | Line items — which menu items, what quantity, at what price *at the time of order* (so later menu price changes don't rewrite history). |
| `order_status_history` | FR-08, FR-09 | An audit trail of every status change — useful evidence for your risk register ("can we prove what happened to an order?"). |

**Why a trigger creates the `profiles` row automatically:** if you relied on the Flutter or ASP.NET app to insert a profile row after signup, a crashed app or lost connection could leave a user with an `auth.users` row but no `profiles` row — logged in, but broken. A database trigger runs inside the same transaction as the signup, so it can't be skipped.

---

## Step 3 — Run the schema

Dashboard → **SQL Editor** → paste the full contents of `supabase_schema.sql` → Run.

Check afterwards: Dashboard → **Table Editor** should show all six tables. Dashboard → **Database → Functions** should show `handle_new_user`, `touch_updated_at`, and `is_staff`.

---

## Step 4 — Configure Auth settings

Dashboard → **Authentication → Providers** → confirm **Email** is enabled (default).

Dashboard → **Authentication → URL Configuration**: for a prototype, you can disable "Confirm email" under **Authentication → Providers → Email** so test signups work immediately without checking an inbox. **Explain this choice in your SRS assumptions section** — for a real deployment you'd re-enable email confirmation.

---

## Step 5 — Signup with role choice (customer vs staff)

This is the piece we designed together: one signup form, one role picker, no separate accounts to manage.

**What happens mechanically:**
1. User fills in the signup form and picks "Customer" or "Staff."
2. The app calls `supabase.auth.signUp()` and passes the choice inside `data: { requested_role: ... }` — this is arbitrary metadata attached to the new `auth.users` row.
3. The `handle_new_user()` trigger fires automatically, reads `requested_role` from that metadata, and inserts the matching row into `profiles`.
4. From that point on, `profiles.role` is the single source of truth — both apps query it, and RLS policies reference it via the `is_staff()` helper function.

**Why store it in the database instead of just remembering it in the app:** if you only stored the role locally (e.g. in app storage), it wouldn't survive a reinstall, wouldn't sync between the customer's phone and a staff member logging into the web dashboard, and — critically — wouldn't be enforceable. A malicious user could edit local storage to claim they're staff. The database copy, checked by RLS on every request, is what actually protects the data.

Promote your one real `owner` account manually after they've signed up as staff:
```sql
update public.profiles set role = 'owner' where id = 'their-uuid-here';
```

---

## Step 6 — Row Level Security, explained

RLS is Postgres checking, on every single query, "is this specific row visible/writable to the user making this request?" — before any data leaves the database. This is why it matters more than hiding buttons in the UI: even if someone bypassed your Flutter or ASP.NET app entirely and called the API directly with cURL, RLS still applies.

Key policies already in the schema, and *why* each one is shaped the way it is:

- **`orders_select_own_or_staff`** — a customer can only see rows where `customer_id = auth.uid()`. This is the direct implementation of NFR-03 ("customers shall only be able to access their own order data").
- **`orders_update_staff_only`** — customers can *insert* orders (place them) but cannot *update* them. Only staff can change `status`. This stops a customer from marking their own order "ready" to jump the queue.
- **`menu_items_read_all`** using `true` — deliberately open, because customers need to browse the menu before logging in (FR-02, "browse menu before arriving").

**Test this before moving on** — RLS bugs are invisible until you specifically try to break them:
1. Create two customer test accounts. Confirm Customer A cannot see Customer B's orders (query as A, check B's order_id returns nothing).
2. Confirm a customer account gets rejected (or silently no-ops) when trying to `update` an order's status directly via the REST API.
3. Confirm a staff account *can* see all orders.

---

## Step 7 — Storage bucket for menu images

Dashboard → **Storage** → New bucket → name it `menu-images` → mark **Public** (customers need to view images without being logged in).

Run the two storage policies from the schema notes (public read, staff-only write). **Why separate policies for storage vs. tables:** Supabase Storage objects live in their own `storage.objects` table under the hood, so they need their own RLS rules — they aren't automatically covered by the policies you wrote for `menu_items`.

---

## Step 8 — Enable Realtime

Already included at the bottom of the schema file:
```sql
alter publication supabase_realtime add table public.orders;
alter publication supabase_realtime add table public.order_status_history;
```

**Why only these two tables:** Realtime has a per-message cost and each subscribed table adds overhead to every connected client. `orders` and `order_status_history` are the only tables where "the other app needs to know *immediately*" (FR-12, NFR-02). Menu changes aren't time-critical enough to justify a live subscription — a normal refresh-on-screen-load is fine there.

Verify: Dashboard → **Database → Replication** should show `orders` and `order_status_history` under `supabase_realtime`.

---

## Step 9 — Connect the two apps

Both apps authenticate the same way (email/password → JWT) and read the same tables — this is what "single source of truth" means in practice.

- **Flutter:** `supabase_flutter` package, initialised once in `main.dart`. Use `.stream()` on `orders` for realtime updates.
- **ASP.NET:** either the `supabase-csharp` client or direct calls to the PostgREST REST API with `HttpClient`. For a student project defence, being able to explain raw REST calls tends to serve you better under questioning than a wrapped SDK you can't fully account for.

(Full code samples for both were covered earlier in this conversation — happy to expand either into its own file if useful.)

---

## Step 10 — Final verification checklist

- [ ] Signing up as "Customer" creates a `profiles` row with `role = 'customer'`
- [ ] Signing up as "Staff" creates a `profiles` row with `role = 'staff'`
- [ ] A customer cannot read another customer's `orders` rows
- [ ] A customer cannot update `orders.status`
- [ ] A staff account can see and update all orders
- [ ] Placing an order in Flutter appears on the ASP.NET dashboard within a few seconds, with no manual refresh
- [ ] Updating status on the dashboard reflects in the Flutter app without a manual refresh
- [ ] Menu images load without requiring login
- [ ] `.env` / API keys are not present anywhere in the GitHub repo

---

## Mapping this work back to your SRS

- **§11.3 Supabase Backend** — this guide *is* the evidence that section was implemented, not just planned.
- **§14.4 Server/Backend Requirements** — note the free-tier limits (500MB DB, project pausing after a week of inactivity) as a documented technical-feasibility constraint.
- **§15 Integration Requirements** — RLS + Realtime together are the mechanism behind "single source of truth" and "real-time subscriptions" — cite the specific policy/table names above when you write this up.
- **Risk register** — worth entries for: open self-service staff role picker (prototype-scope decision), Supabase free-tier pausing, and reliance on a third-party BaaS for core system availability.
