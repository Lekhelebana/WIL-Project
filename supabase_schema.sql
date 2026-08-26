-- ============================================================
-- Nama Nameng — Supabase schema
-- ITC327W Phase 1
-- Run this in Supabase Dashboard > SQL Editor
-- ============================================================

-- ---------- 1. PROFILES (extends auth.users) ----------
create type user_role as enum ('customer', 'staff', 'owner');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  phone text,
  role user_role not null default 'customer',
  created_at timestamptz not null default now()
);

-- Auto-create a profile row whenever someone signs up via Supabase Auth.
-- Role is chosen ONCE at signup, passed in as user metadata:
--   { "full_name": "...", "requested_role": "staff" }  or "customer"
-- Whatever the client sends is trusted as-is for now (prototype scope —
-- open self-service role picker). NOTE FOR RISK REGISTER: this means any
-- signing-up user can currently choose "staff" and get staff-level access
-- to the dashboard. Acceptable for a controlled prototype/demo with a known
-- small user base; before any real-world handover to Nama Nameng, this needs
-- gating (invite code, owner approval, or manual promotion only).
create function public.handle_new_user()
returns trigger as $$
declare
  requested text := new.raw_user_meta_data->>'requested_role';
  granted_role user_role := 'customer';
begin
  if requested = 'staff' then
    granted_role := 'staff';
  end if;

  insert into public.profiles (id, full_name, role)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', 'New User'), granted_role);
  return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- Note: 'owner' is never chosen at signup — promote the one real owner
-- account manually in the SQL editor after they sign up as staff:
--   update public.profiles set role = 'owner' where id = 'their-uuid';

-- ---------- 2. MENU ----------
create table public.menu_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  sort_order int default 0
);

create table public.menu_items (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references public.menu_categories(id) on delete set null,
  name text not null,
  description text,
  price numeric(10,2) not null check (price >= 0),
  image_url text,
  is_available boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------- 3. ORDERS ----------
create type order_status as enum ('received', 'preparing', 'ready', 'collected', 'cancelled');

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.profiles(id),
  status order_status not null default 'received',
  total numeric(10,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  menu_item_id uuid not null references public.menu_items(id),
  quantity int not null check (quantity > 0),
  price_at_order numeric(10,2) not null
);

create table public.order_status_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  status order_status not null,
  changed_by uuid references public.profiles(id),
  changed_at timestamptz not null default now()
);

-- Keep orders.updated_at fresh
create function public.touch_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger orders_touch_updated_at
  before update on public.orders
  for each row execute procedure public.touch_updated_at();

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
alter table public.profiles enable row level security;
alter table public.menu_categories enable row level security;
alter table public.menu_items enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.order_status_history enable row level security;

-- Helper: is the current user staff or owner?
create function public.is_staff()
returns boolean as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('staff', 'owner')
  );
$$ language sql stable security definer;

-- PROFILES: everyone can read their own; staff can read all
create policy "profiles_select_own_or_staff" on public.profiles
  for select using (id = auth.uid() or public.is_staff());
create policy "profiles_update_own" on public.profiles
  for update using (id = auth.uid());

-- MENU: public read for everyone (even logged-out customers browsing);
-- only staff can write
create policy "menu_categories_read_all" on public.menu_categories
  for select using (true);
create policy "menu_categories_write_staff" on public.menu_categories
  for all using (public.is_staff()) with check (public.is_staff());

create policy "menu_items_read_all" on public.menu_items
  for select using (true);
create policy "menu_items_write_staff" on public.menu_items
  for all using (public.is_staff()) with check (public.is_staff());

-- ORDERS: customers see only their own; staff see all
create policy "orders_select_own_or_staff" on public.orders
  for select using (customer_id = auth.uid() or public.is_staff());
create policy "orders_insert_own" on public.orders
  for insert with check (customer_id = auth.uid());
create policy "orders_update_staff_only" on public.orders
  for update using (public.is_staff());
-- (customers cannot flip their own order to "ready" — only staff can)

-- ORDER ITEMS: visible if you can see the parent order
create policy "order_items_select" on public.order_items
  for select using (
    exists (select 1 from public.orders o
            where o.id = order_id
            and (o.customer_id = auth.uid() or public.is_staff()))
  );
create policy "order_items_insert_own" on public.order_items
  for insert with check (
    exists (select 1 from public.orders o
            where o.id = order_id and o.customer_id = auth.uid())
  );

-- ORDER STATUS HISTORY: same visibility as orders; only staff can write
create policy "status_history_select" on public.order_status_history
  for select using (
    exists (select 1 from public.orders o
            where o.id = order_id
            and (o.customer_id = auth.uid() or public.is_staff()))
  );
create policy "status_history_insert_staff" on public.order_status_history
  for insert with check (public.is_staff());

-- ============================================================
-- REALTIME
-- ============================================================
-- Enable realtime replication on the tables both apps need to sync
alter publication supabase_realtime add table public.orders;
alter publication supabase_realtime add table public.order_status_history;
