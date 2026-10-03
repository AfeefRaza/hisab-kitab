-- Orders paid in Shopify (e.g. bank transfer) are booked with the courier at COD 0.
-- A settled COD of 0 on a PAID order is correct, not a mismatch.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.refresh_alerts()'::regprocedure);
  d := replace(d,
    'where f.is_cod and f.settlement_count > 0',
    'where f.is_cod and f.settlement_count > 0 and not (f.settled_cod = 0 and f.financial_status = ''PAID'')');
  execute d;
end $$;
