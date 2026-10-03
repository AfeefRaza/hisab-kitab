-- =====================================================================
-- Tracking write-back (service_role only) + scheduled jobs
-- =====================================================================

create or replace function public.apply_tracking_updates(p_updates jsonb, p_events jsonb)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
begin
  update public.shipments s set
    status = coalesce(u.status, s.status),
    status_raw = coalesce(u.status_raw, s.status_raw),
    -- when the courier gives no event date, the first time we see a new status is its date
    status_at = case
      when u.status is null then s.status_at
      when u.status_at is not null then u.status_at
      when u.status <> s.status or s.status_at is null then now()
      else s.status_at end,
    delivered_at = case when u.status = 'delivered' then coalesce(s.delivered_at, u.status_at, now()) else s.delivered_at end,
    returned_at = case when u.status = 'returned' then coalesce(s.returned_at, u.status_at, now()) else s.returned_at end,
    is_final = case when u.status is null then s.is_final
                    else u.status in ('delivered', 'returned', 'cancelled', 'lost') end,
    check_error = u.error,
    last_checked_at = now(),
    next_check_at = now() + make_interval(mins => greatest(coalesce(u.next_minutes, 240), 0))
  from jsonb_to_recordset(p_updates) as u(
    id bigint, status public.shipment_status, status_raw text, status_at timestamptz, error text, next_minutes int)
  where s.id = u.id;
  get diagnostics v_count = row_count;

  insert into public.shipment_events (shipment_id, status, status_raw, event_at, source)
  select e.shipment_id, e.status, e.status_raw, e.event_at, 'courier'
  from jsonb_to_recordset(coalesce(p_events, '[]'::jsonb)) as e(
    shipment_id bigint, status public.shipment_status, status_raw text, event_at timestamptz)
  on conflict do nothing;

  return v_count;
end;
$$;
revoke execute on function public.apply_tracking_updates(jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.apply_tracking_updates(jsonb, jsonb) to service_role;

-- ---------------------------------------------------------------------
-- pg_cron → edge functions (authenticated with the Vault cron secret).
-- Requires a Vault secret named 'hk_project_url' = https://<ref>.supabase.co
-- (created by the setup step in docs/DEPLOYMENT.md).
-- ---------------------------------------------------------------------
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

create or replace function public.cron_call(p_function text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_secret text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'hk_project_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'hk_cron_secret';
  if v_url is null or v_secret is null then
    raise warning 'cron_call: hk_project_url / hk_cron_secret not set in Vault';
    return null;
  end if;
  return net.http_post(
    url := rtrim(v_url, '/') || '/functions/v1/' || p_function,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', v_secret),
    body := '{}'::jsonb,
    timeout_milliseconds := 150000
  );
end;
$$;
revoke execute on function public.cron_call(text) from public, anon, authenticated;

select cron.schedule('hk-sync-orders', '*/30 * * * *', $$select public.cron_call('sync-orders')$$);
select cron.schedule('hk-sync-tracking', '10 * * * *', $$select public.cron_call('sync-tracking')$$);
select cron.schedule('hk-reconcile', '40 */2 * * *', $$select public.auto_match_settlements(); select public.refresh_alerts();$$);
select cron.schedule('hk-prune-sync-runs', '0 3 * * *', $$delete from public.sync_runs where started_at < now() - interval '60 days'$$);
