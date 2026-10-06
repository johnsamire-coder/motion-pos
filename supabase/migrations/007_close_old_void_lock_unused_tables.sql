-- 007_close_old_void_lock_unused_tables.sql
-- Phase 1 / Step 1.5 (d):
-- 1) The old void_order_item (no manager PIN, returned stock that was never deducted)
--    is closed to the public key. Both sites now use void_order_item_secure.
-- 2) Tables that no screen and no function touches at all are locked (RLS, no policies).
--    Checked before this file with a scan of the screens and of every function in public.
--    Tables used by screens or by functions are locked in phase 2, when their work moves
--    to server functions that need a shift ticket.

begin;

revoke execute on function public.void_order_item(uuid, uuid, uuid, uuid) from public, anon, authenticated;

alter table public.adjustment_reasons enable row level security;
alter table public.cash_bank_accounts enable row level security;
alter table public.companies enable row level security;
alter table public.cost_centers enable row level security;
alter table public.opening_balances enable row level security;
alter table public.order_split_items enable row level security;
alter table public.order_splits enable row level security;
alter table public.supplier_prices enable row level security;
alter table public.units enable row level security;
alter table public.variance_investigations enable row level security;

commit;
