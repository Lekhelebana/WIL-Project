-- =====================================================================
-- Nama Nameng — Row Level Security (RLS) policies
-- Tables: profiles, menu_categories, menu_items, orders, order_items,
--         order_status_history
--
-- Roles in play:
--   guest      -> anon key, no auth.uid(), read-only on menu tables
--   customer   -> authenticated, role = 'customer' in profiles
--   staff      -> authenticated, role = 'staff' in profiles
--   owner      -> authenticated, role = 'owner' in profiles
--
-- Run this after your tables exist. Safe to re-run (uses DROP POLICY
-- IF EXISTS before each CREATE POLICY).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Helper: check the caller's role without recursive RLS on `profiles`
-- SECURITY DEFINER bypasses RLS inside the function body only.
-- ---------------------------------------------------------------------
create or replace function public.current_user_role()
returns text
language sql
security definer
set search_path = public
stable
as $$
  select role::text
  from public.profiles
  where id = auth.uid()
$$;

create or replace function public.is_staff_or_owner()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(
    (select role::text in ('staff', 'owner')
     from public.profiles
     where id = auth.uid()),
    false
  )
$$;

-- =====================================================================
-- profiles
-- =====================================================================
alter table public.profiles enable row level security;

drop policy if exists "profiles_select_own_or_staff" on public.profiles;
create policy "profiles_select_own_or_staff"
on public.profiles for select
to authenticated
using (
  id = auth.uid()
  or public.is_staff_or_owner()
);

drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own"
on public.profiles for insert
to authenticated
with check (id = auth.uid());

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
on public.profiles for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());

-- Staff/owner can update any profile (e.g. promote a user to staff)
drop policy if exists "profiles_update_staff" on public.profiles;
create policy "profiles_update_staff"
on public.profiles for update
to authenticated
using (public.is_staff_or_owner())
with check (public.is_staff_or_owner());

-- No delete policy -> deletes are blocked by default under RLS.

-- =====================================================================
-- menu_categories
-- Public browsing (guest + customer + staff/owner). Only staff/owner
-- can manage categories.
-- =====================================================================
alter table public.menu_categories enable row level security;

drop policy if exists "menu_categories_select_all" on public.menu_categories;
create policy "menu_categories_select_all"
on public.menu_categories for select
to anon, authenticated
using (true);

drop policy if exists "menu_categories_write_staff" on public.menu_categories;
create policy "menu_categories_write_staff"
on public.menu_categories for insert
to authenticated
with check (public.is_staff_or_owner());

drop policy if exists "menu_categories_update_staff" on public.menu_categories;
create policy "menu_categories_update_staff"
on public.menu_categories for update
to authenticated
using (public.is_staff_or_owner())
with check (public.is_staff_or_owner());

drop policy if exists "menu_categories_delete_staff" on public.menu_categories;
create policy "menu_categories_delete_staff"
on public.menu_categories for delete
to authenticated
using (public.is_staff_or_owner());

-- =====================================================================
-- menu_items
-- Guests and customers only see available items; staff/owner see and
-- manage everything (including items toggled unavailable).
-- =====================================================================
alter table public.menu_items enable row level security;

drop policy if exists "menu_items_select_public" on public.menu_items;
create policy "menu_items_select_public"
on public.menu_items for select
to anon, authenticated
using (
  is_available = true
  or public.is_staff_or_owner()
);

drop policy if exists "menu_items_insert_staff" on public.menu_items;
create policy "menu_items_insert_staff"
on public.menu_items for insert
to authenticated
with check (public.is_staff_or_owner());

drop policy if exists "menu_items_update_staff" on public.menu_items;
create policy "menu_items_update_staff"
on public.menu_items for update
to authenticated
using (public.is_staff_or_owner())
with check (public.is_staff_or_owner());

drop policy if exists "menu_items_delete_staff" on public.menu_items;
create policy "menu_items_delete_staff"
on public.menu_items for delete
to authenticated
using (public.is_staff_or_owner());

-- =====================================================================
-- orders
-- Guests cannot place orders (must be authenticated). Customers can
-- create and view only their own orders. Staff/owner can view and
-- update (change status on) every order.
-- =====================================================================
alter table public.orders enable row level security;

drop policy if exists "orders_select_own_or_staff" on public.orders;
create policy "orders_select_own_or_staff"
on public.orders for select
to authenticated
using (
  customer_id = auth.uid()
  or public.is_staff_or_owner()
);

drop policy if exists "orders_insert_own" on public.orders;
create policy "orders_insert_own"
on public.orders for insert
to authenticated
with check (customer_id = auth.uid());

-- Customers may cancel their own order while still pending; staff/owner
-- can update any order's status (accept, prepare, ready, etc).
drop policy if exists "orders_update_own_pending" on public.orders;
create policy "orders_update_own_pending"
on public.orders for update
to authenticated
using (customer_id = auth.uid() and status = 'pending')
with check (customer_id = auth.uid());

drop policy if exists "orders_update_staff" on public.orders;
create policy "orders_update_staff"
on public.orders for update
to authenticated
using (public.is_staff_or_owner())
with check (public.is_staff_or_owner());

-- =====================================================================
-- order_items
-- Visible/insertable only through the parent order's ownership.
-- =====================================================================
alter table public.order_items enable row level security;

drop policy if exists "order_items_select_own_or_staff" on public.order_items;
create policy "order_items_select_own_or_staff"
on public.order_items for select
to authenticated
using (
  public.is_staff_or_owner()
  or exists (
    select 1 from public.orders o
    where o.id = order_items.order_id
      and o.customer_id = auth.uid()
  )
);

drop policy if exists "order_items_insert_own" on public.order_items;
create policy "order_items_insert_own"
on public.order_items for insert
to authenticated
with check (
  exists (
    select 1 from public.orders o
    where o.id = order_items.order_id
      and o.customer_id = auth.uid()
      and o.status = 'pending'
  )
);

drop policy if exists "order_items_update_staff" on public.order_items;
create policy "order_items_update_staff"
on public.order_items for update
to authenticated
using (public.is_staff_or_owner())
with check (public.is_staff_or_owner());

drop policy if exists "order_items_delete_own_pending" on public.order_items;
create policy "order_items_delete_own_pending"
on public.order_items for delete
to authenticated
using (
  exists (
    select 1 from public.orders o
    where o.id = order_items.order_id
      and o.customer_id = auth.uid()
      and o.status = 'pending'
  )
);

-- =====================================================================
-- order_status_history
-- Customers can read the history of their own orders (for order
-- tracking). Only staff/owner can write new history rows.
-- =====================================================================
alter table public.order_status_history enable row level security;

drop policy if exists "order_status_history_select_own_or_staff" on public.order_status_history;
create policy "order_status_history_select_own_or_staff"
on public.order_status_history for select
to authenticated
using (
  public.is_staff_or_owner()
  or exists (
    select 1 from public.orders o
    where o.id = order_status_history.order_id
      and o.customer_id = auth.uid()
  )
);

drop policy if exists "order_status_history_insert_staff" on public.order_status_history;
create policy "order_status_history_insert_staff"
on public.order_status_history for insert
to authenticated
with check (
  public.is_staff_or_owner()
  and changed_by = auth.uid()
);

-- No update/delete policies -> history rows are append-only.

-- =====================================================================
-- Notes
-- =====================================================================
-- 1. Storage (menu item images) is not covered here — set up a separate
--    bucket policy in Supabase Storage: public read, staff/owner write.
-- 2. If your `role` column is an enum (e.g. user_role), the ::text casts
--    above keep the comparisons simple; adjust if your enum values
--    differ from 'customer' / 'staff' / 'owner'.
-- 3. Guests (anon key) only ever touch menu_categories and menu_items
--    via SELECT — every other table requires an authenticated session,
--    matching the "Guest access: no login, limited by RLS" note on the
--    architecture diagram.
