# Nama Nameng — RLS rules per role

Companion reference to `RLS.sql`. Summarizes what each role can see and do on every table.

Roles: **guest** (anon key, no session), **customer** (authenticated, `profiles.role = 'customer'`), **staff** and **owner** (authenticated, `profiles.role = 'staff'` or `'owner'`).

---

## profiles

| Action | Guest | Customer | Staff / owner |
|---|---|---|---|
| Select | No | Own row only | All rows |
| Insert | No | Own row only (on sign-up) | — |
| Update | No | Own row only | Any row (e.g. promote a user) |
| Delete | No | No | No (blocked by default) |

## menu_categories

| Action | Guest | Customer | Staff / owner |
|---|---|---|---|
| Select | Yes, all | Yes, all | Yes, all |
| Insert | No | No | Yes |
| Update | No | No | Yes |
| Delete | No | No | Yes |

## menu_items

| Action | Guest | Customer | Staff / owner |
|---|---|---|---|
| Select | Available items only | Available items only | All items, including unavailable |
| Insert | No | No | Yes |
| Update | No | No | Yes |
| Delete | No | No | Yes |

## orders

| Action | Guest | Customer | Staff / owner |
|---|---|---|---|
| Select | No | Own orders only | All orders |
| Insert | No | Own orders only (`customer_id = auth.uid()`) | — |
| Update | No | Own order, only while `status = 'pending'` (e.g. cancel) | Any order, any status change |
| Delete | No | No | No (blocked by default) |

## order_items

| Action | Guest | Customer | Staff / owner |
|---|---|---|---|
| Select | No | Items belonging to own orders only | All order items |
| Insert | No | Own order only, while `status = 'pending'` | No direct insert (managed via orders flow) |
| Update | No | No | Yes |
| Delete | No | Own order's items, while `status = 'pending'` | No direct delete |

## order_status_history

| Action | Guest | Customer | Staff / owner |
|---|---|---|---|
| Select | No | History for own orders only (order tracking) | All history |
| Insert | No | No | Yes, and only with `changed_by = auth.uid()` |
| Update | No | No | No (append-only) |
| Delete | No | No | No (append-only) |

---

## Notes

- Staff/owner access is resolved through a `security definer` helper, `is_staff_or_owner()`, so the policy on `profiles` doesn't recurse into itself.
- Guests only ever touch `menu_categories` and `menu_items`, and only with `select` — everything else requires an authenticated session.
- Menu item images live in Supabase Storage, not in these tables — that bucket needs its own policy (public read, staff/owner write), not covered here.
- Role names and the `'pending'` order status assume `profiles.role` and `orders.status` use those exact enum values; adjust the table above (and `RLS.sql`) if your enums differ.
