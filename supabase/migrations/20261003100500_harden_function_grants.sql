-- Functions are executable by PUBLIC by default (anon inherits it).
-- Revoke everything, then grant back exactly what the app needs.
revoke execute on all functions in schema public from public, anon;
alter default privileges in schema public revoke execute on functions from public;

-- Trigger functions: nobody calls these directly (triggers don't need EXECUTE)
revoke execute on function public.audit_trigger() from authenticated;
revoke execute on function public.guard_profile_role() from authenticated;
revoke execute on function public.handle_new_user() from authenticated;
revoke execute on function public.touch_updated_at() from authenticated;

-- Helpers used inside RLS policies / security-invoker views
grant execute on function public.current_app_role() to authenticated, service_role;
grant execute on function public.has_role(public.app_role) to authenticated, service_role;
grant execute on function public.setting_num(text, text, numeric) to authenticated, service_role;
grant execute on function public.normalize_tracking(text) to authenticated, service_role;
grant execute on function public.assert_role(public.app_role) to authenticated, service_role;

-- App RPCs (each checks the caller's role itself)
grant execute on function public.expenses_in_period(date, date) to authenticated;
grant execute on function public.finance_summary(date, date) to authenticated;
grant execute on function public.finance_daily(date, date) to authenticated;
grant execute on function public.profit_breakdown(date, date, text) to authenticated;
grant execute on function public.order_timeline(bigint) to authenticated;
grant execute on function public.global_search(text, int) to authenticated;
grant execute on function public.preview_settlement(jsonb) to authenticated;
grant execute on function public.import_settlement(text, text, text, text, date, jsonb, text) to authenticated, service_role;
grant execute on function public.void_settlement_batch(bigint, text) to authenticated, service_role;
grant execute on function public.import_bank_statement(bigint, text, text, jsonb) to authenticated, service_role;
grant execute on function public.auto_match_settlements() to authenticated, service_role;
grant execute on function public.set_shipment_status(bigint, public.shipment_status, text) to authenticated, service_role;
grant execute on function public.refresh_alerts() to authenticated, service_role;

-- service_role only (secrets / cron)
grant execute on function public.integration_get_secret(text) to service_role;
grant execute on function public.integration_save(text, jsonb, jsonb, jsonb, uuid, text, text) to service_role;
grant execute on function public.integration_disconnect(text, uuid) to service_role;
grant execute on function public.cron_secret_matches(text) to service_role;
