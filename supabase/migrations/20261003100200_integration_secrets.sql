-- =====================================================================
-- Integration secrets in Supabase Vault (encrypted at rest).
-- Only service_role (edge functions) can execute these functions; the
-- browser/Flutter client can never read a secret back. The client only
-- sees integrations.secret_hint (masked values).
-- =====================================================================

create or replace function public.integration_get_secret(p_provider text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  sid uuid;
  val text;
begin
  select vault_secret_id into sid from public.integrations where provider = p_provider;
  if sid is null then
    return null;
  end if;
  select decrypted_secret into val from vault.decrypted_secrets where id = sid;
  return case when val is null then null else val::jsonb end;
end;
$$;

create or replace function public.integration_save(
  p_provider text,
  p_secret jsonb,          -- null = keep existing secret, only update config
  p_secret_hint jsonb,
  p_config jsonb,
  p_actor uuid,
  p_status text,
  p_message text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  sid uuid;
begin
  select vault_secret_id into sid from public.integrations where provider = p_provider for update;
  if not found then
    raise exception 'Unknown provider %', p_provider;
  end if;

  if p_secret is not null then
    if sid is null then
      sid := vault.create_secret(p_secret::text, 'integration:' || p_provider, 'Hisab Kitab ' || p_provider || ' credentials');
    else
      perform vault.update_secret(sid, p_secret::text);
    end if;
  end if;

  update public.integrations set
    vault_secret_id = sid,
    secret_hint = coalesce(p_secret_hint, secret_hint),
    config = coalesce(p_config, config),
    enabled = true,
    status = p_status,
    last_tested_at = now(),
    last_test_message = p_message,
    updated_by = p_actor
  where provider = p_provider;
end;
$$;

create or replace function public.integration_disconnect(p_provider text, p_actor uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  sid uuid;
begin
  select vault_secret_id into sid from public.integrations where provider = p_provider for update;
  if sid is not null then
    delete from vault.secrets where id = sid;
  end if;
  update public.integrations set
    vault_secret_id = null,
    secret_hint = '{}'::jsonb,
    enabled = false,
    status = 'not_configured',
    last_test_message = 'Disconnected',
    updated_by = p_actor
  where provider = p_provider;
end;
$$;

-- Shared secret used by pg_cron to call sync edge functions.
create or replace function public.cron_secret_matches(p_secret text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from vault.decrypted_secrets
    where name = 'hk_cron_secret' and decrypted_secret = p_secret and length(p_secret) >= 32
  );
$$;

do $$
begin
  if not exists (select 1 from vault.secrets where name = 'hk_cron_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'hk_cron_secret', 'Auth for pg_cron -> edge function calls');
  end if;
end $$;

revoke all on function public.integration_get_secret(text) from public, anon, authenticated;
revoke all on function public.integration_save(text, jsonb, jsonb, jsonb, uuid, text, text) from public, anon, authenticated;
revoke all on function public.integration_disconnect(text, uuid) from public, anon, authenticated;
revoke all on function public.cron_secret_matches(text) from public, anon, authenticated;
grant execute on function public.integration_get_secret(text) to service_role;
grant execute on function public.integration_save(text, jsonb, jsonb, jsonb, uuid, text, text) to service_role;
grant execute on function public.integration_disconnect(text, uuid) to service_role;
grant execute on function public.cron_secret_matches(text) to service_role;
