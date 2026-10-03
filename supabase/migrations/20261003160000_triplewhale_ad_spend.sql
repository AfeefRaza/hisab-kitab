-- =====================================================================
-- Triple Whale integration: daily ad spend per channel → automatic expenses
-- Each (channel, day) becomes one expense row (source 'triplewhale') in the
-- matching marketing category, so P&L / ROAS / Expenses use it unchanged.
-- Re-syncing updates amounts (platforms revise spend); 0 removes the row.
-- =====================================================================

alter table public.integrations drop constraint if exists integrations_provider_check;
alter table public.integrations add constraint integrations_provider_check
  check (provider in ('shopify', 'postex', 'blueex', 'mnp', 'tranzo', 'xps', 'triplewhale'));
alter table public.integrations drop constraint if exists integrations_kind_check;
alter table public.integrations add constraint integrations_kind_check check (kind in ('store', 'courier', 'marketing'));
insert into public.integrations (provider, display_name, kind, config)
values ('triplewhale', 'Triple Whale', 'marketing', '{}')
on conflict (provider) do nothing;

alter table public.sync_runs drop constraint if exists sync_runs_kind_check;
alter table public.sync_runs add constraint sync_runs_kind_check
  check (kind in ('orders', 'tracking', 'alerts', 'bank_match', 'payments', 'adspend'));

alter table public.expenses add column if not exists source text not null default 'manual';
alter table public.expenses add column if not exists external_key text;
create unique index if not exists expenses_external_uniq on public.expenses (source, external_key) where external_key is not null;

insert into public.expense_categories (name, kind) values
  ('Snapchat Ads', 'marketing'), ('Pinterest Ads', 'marketing'), ('Amazon Ads', 'marketing'), ('Other Ad Spend', 'marketing')
on conflict (name) do nothing;

-- p_rows: [{day: 'YYYY-MM-DD', channel: 'facebookAds', amount: 1234.5}]
create or replace function public.apply_ad_spend(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_upserted int;
  v_deleted int;
begin
  create temporary table if not exists _ad (day date, channel text, amount numeric, category_id bigint, label text) on commit drop;
  truncate _ad;

  insert into _ad (day, channel, amount)
  select (x ->> 'day')::date, x ->> 'channel', round(coalesce((x ->> 'amount')::numeric, 0), 2)
  from jsonb_array_elements(p_rows) x;

  update _ad a set category_id = c.id, label = m.label
  from (values
    ('facebookAds', 'Facebook / Meta Ads', 'Meta'),
    ('googleAds', 'Google Ads', 'Google'),
    ('tiktokAds', 'TikTok Ads', 'TikTok'),
    ('snapchatAds', 'Snapchat Ads', 'Snapchat'),
    ('pinterestAds', 'Pinterest Ads', 'Pinterest'),
    ('amazonAds', 'Amazon Ads', 'Amazon'),
    ('otherAds', 'Other Ad Spend', 'Other')
  ) as m(channel, category, label)
  join public.expense_categories c on c.name = m.category
  where a.channel = m.channel;

  insert into public.expenses (expense_date, category_id, amount, vendor, description, payment_method,
                               period_start, period_end, source, external_key)
  select day, category_id, amount, 'Triple Whale', label || ' ad spend (auto)', 'card', day, day,
         'triplewhale', channel || ':' || day
  from _ad
  where category_id is not null and amount > 0
  on conflict (source, external_key) where external_key is not null
  do update set amount = excluded.amount, category_id = excluded.category_id, updated_at = now();
  get diagnostics v_upserted = row_count;

  delete from public.expenses e
  using _ad a
  where e.source = 'triplewhale' and e.external_key = a.channel || ':' || a.day and a.amount <= 0;
  get diagnostics v_deleted = row_count;

  return jsonb_build_object('upserted', v_upserted, 'removed', v_deleted);
end;
$$;
revoke execute on function public.apply_ad_spend(jsonb) from public, anon, authenticated;
grant execute on function public.apply_ad_spend(jsonb) to service_role;

-- Every 6 hours: refresh the last 3 days (spend is revised for a couple of days)
select cron.schedule('hk-sync-adspend', '50 */6 * * *', $$select public.cron_call('sync-adspend')$$);
