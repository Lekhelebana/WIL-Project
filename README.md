# Nama Nameng - ASP.NET web app on Supabase (Visual Studio 2022, .NET 8)

Customer ordering site and staff/manager portal for the Nama Nameng chisa nyama (ITC327W WIL project).
Data lives in **Supabase Postgres** and logins in **Supabase Auth**, so the Flutter app can use the same users and orders.

## How it fits together

| Part | Web app (ASP.NET) | Flutter app (later) |
|------|-------------------|---------------------|
| Login | Supabase Auth over HTTPS (anon key) | `supabase_flutter` `signInWithPassword` |
| Data | Direct Postgres connection (EF Core, Npgsql) as the database owner | Supabase API with the user's login, protected by Row Level Security |
| Placing an order | EF Core inserts the order | `supabase.rpc('place_order', ...)` (server calculates prices) |
| Changing order status | EF Core | `supabase.rpc('set_order_status', ...)` (staff only) |

Never put the database password or the `service_role` key in the Flutter app or in Git.

## Setup (do these in order)

### 1. Create the database (once)
Supabase Dashboard > **SQL Editor** > New query. Paste and Run, one file at a time:
1. `supabase/01_schema.sql` (tables, security rules, trigger, functions)
2. `supabase/02_seed_menu.sql` (starter menu)
2b. `supabase/05_guest_orders.sql` (lets guests order and track orders in the Flutter app without an account)

### 2. Authentication settings
Dashboard > **Authentication** > Sign In / Providers > Email:
- For development, turn **Confirm email OFF** (the built-in email sender only allows a few emails per hour). If you leave it ON, the site tells customers to confirm their email before logging in.
- Under Providers, leave **Allow anonymous sign-ins** ON if the Flutter app will let guests order.
- **Forgot password (customers)**: Authentication > Emails > **Reset Password** template must show the 6-digit code. Put `{{ .Token }}` in the body (for example "Your Nama Nameng code is {{ .Token }}"). The website (`/Account/ForgotPassword`) and the Flutter app both use this code. Staff and manager passwords are reset by the owner in Authentication > Users.

### 3. Create the staff and manager logins
Dashboard > **Authentication** > Users > Add user > Create new user, tick **Auto Confirm User**:
`manager@namanameng.co.za` and `staff@namanameng.co.za` (choose strong passwords).
Then run `supabase/03_make_staff.sql` in the SQL Editor. It must print both users with roles Manager and Staff.
Customers register themselves on the site and are always created as `Customer`.

### 4. Give the web app its Supabase keys (User Secrets, not Git)
Collect three things from the dashboard:
- **Anon key**: Project Settings > API Keys > `anon` (legacy) or the `publishable` key.
- **Pooler host and user**: click **Connect** (top bar) > **Session pooler**. It shows a host like `aws-0-<region>.pooler.supabase.com`, port `5432`, and user `postgres.qmcwfnupigrpkmtommcd`. Use the Session pooler: the direct `db.<ref>.supabase.co` host is IPv6 only and fails on most home networks. Do not use port 6543.
- **Database password**: the one you set when creating the project (Project Settings > Database > Reset database password if lost).

In Visual Studio: right-click the **NamaNameng.Web** project > **Manage User Secrets** and paste:

```json
{
  "Supabase": {
    "Url": "https://qmcwfnupigrpkmtommcd.supabase.co",
    "AnonKey": "PASTE-ANON-KEY",
    "Db": {
      "Host": "PASTE-POOLER-HOST",
      "Port": 5432,
      "User": "postgres.qmcwfnupigrpkmtommcd",
      "Password": "PASTE-DATABASE-PASSWORD"
    }
  }
}
```

(Command line equivalent: `dotnet user-secrets set "Supabase:Db:Password" "..."` inside `NamaNameng.Web`.)
On a hosting service, set the same values as environment variables, for example `Supabase__Db__Password`.

### 5. Run
Open `NamaNameng.sln`, press **F5**. The first lines of the console log must say
`Connected to Supabase Postgres. Menu categories: 3.` If you see a critical error instead, re-check step 4 and that step 1 ran without errors.

## What each role can do

- **Guest / customer**: browse the menu (search and categories), add to cart, check out with a name and optional note, see "Order received", track live status. Registered customers also get a profile (edit name and phone), order history and "Order again".
- **Staff**: home (live alerts, shift timer, today's numbers), incoming orders (start / cancel), order details, kitchen queue (ready / collected), read-only menu, profile (take a break, end shift).
- **Manager**: everything staff can do, plus menu management (add, edit, sold out, remove, add categories), top sellers on the home page and the sales overview.

Customers and staff sign in on the same login page: the **Customer** and **Staff** tabs (`/Account/Login` and `/Portal/Login`).

## Screen map (web = Flutter app)

| Flutter app | Web app |
|-------------|---------|
| Welcome (Explore Menu, Log in, Register) | `/` |
| Customer / Staff login tabs | `/Account/Login`, `/Portal/Login` |
| Home (search, categories) | `/Shop/Home` |
| Menu | `/Shop/Menu` (category chips + search) |
| Cart | `/Shop/Cart` |
| Checkout (name + note, guests allowed) | `/Shop/Checkout` |
| Order Received | `/Shop/OrderReceived/{id}` |
| Track Order (5 second refresh) | `/Shop/Track/{id}` |
| Profile (edit details, history, order again, log out) | `/Account/Profile` |
| Staff Home | `/Staff/Dashboard` |
| Incoming orders | `/Staff/Incoming` |
| Order detail | `/Staff/Details/{id}` |
| Kitchen queue | `/Staff/Kitchen` |
| Menu (managers edit) | `/Manager/Menu` |
| Staff profile (break, end shift) | `/Staff/Profile` |

"Take a break" pauses order actions for the current browser session (buttons are disabled and the server refuses status changes). "End shift" signs out. The shift timer starts when staff log in.

The **Sales overview** page (`/Manager/Sales`) is extra to the Flutter app's manager home.

## Notes for the Flutter app

- Use the project URL and the **anon/publishable key** only.
- Customers: `signUp(email, password, data: {'full_name': ..., 'phone': ...})`. The database trigger creates the profile. Role can never be set from the app.
- Guests: `signInAnonymously()`, then call `place_order`.
- Items: `place_order(p_customer_name, p_notes, p_items)` where `p_items` is `[{"menu_item_id": 1, "quantity": 2}]`. It returns `{id, order_number, total}`.
- Live status: subscribe to Realtime changes on `orders` (already enabled; customers only receive their own rows).
- Times are stored in UTC (`timestamptz`). Convert to local time in the app.
- Order status values: `Received`, `Preparing`, `Ready`, `Collected`, `Cancelled`. Roles: `Customer`, `Staff`, `Manager`.

## Project layout

- `supabase/` SQL for the database (run in the SQL Editor)
- `Program.cs` startup, Supabase config, cookie login, sessions
- `Services/` Supabase settings and the Supabase Auth client
- `Models/`, `Data/AppDbContext.cs` entities and table mapping
- `Controllers/` Home, Account (customers), Portal (staff login), Shop, Staff, Manager
- `Views/`, `wwwroot/` Razor pages, CSS and the refresh script

Orders refresh every 4 to 5 seconds on the web pages. Payment is cash or card at the counter (no online payment), as agreed in the SRS.
