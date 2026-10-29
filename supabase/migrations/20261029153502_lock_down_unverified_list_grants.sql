begin;
revoke all on table public.unverified_levels from anon, authenticated;
grant select on table public.unverified_levels to anon, authenticated;
grant insert on table public.unverified_levels to authenticated;
commit;