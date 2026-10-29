begin;
drop policy if exists "Anyone can view unverified list" on public.unverified_levels;
commit;