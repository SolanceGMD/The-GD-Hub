begin;

alter table public.profiles
  add column if not exists avatar_url text,
  add column if not exists banner_url text,
  add column if not exists bio text not null default '',
  add column if not exists theme text not null default 'dark'
    check (theme in ('dark','light','system'));

drop policy if exists "profiles users can update own profile" on public.profiles;
create policy "profiles users can update own profile"
  on public.profiles for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);
grant update (gd_username, avatar_url, banner_url, bio, theme) on public.profiles to authenticated;

alter table public.unverified_levels
  add column if not exists admin_hidden boolean not null default false;

drop policy if exists "unverified levels are publicly readable" on public.unverified_levels;
drop policy if exists "public can read unverified levels" on public.unverified_levels;
create policy "public can read visible unverified levels"
  on public.unverified_levels for select to anon, authenticated
  using (not admin_hidden);
create policy "admins can read all unverified levels"
  on public.unverified_levels for select to authenticated
  using ((select wcl_private.has_permission('levels.manage')));
create policy "admins can update unverified levels"
  on public.unverified_levels for update to authenticated
  using ((select wcl_private.has_permission('levels.manage')))
  with check ((select wcl_private.has_permission('levels.manage')));
create policy "admins can delete unverified levels"
  on public.unverified_levels for delete to authenticated
  using ((select wcl_private.has_permission('levels.manage')));

grant select on public.unverified_levels to anon, authenticated;
grant update (admin_hidden) on public.unverified_levels to authenticated;
grant delete on public.unverified_levels to authenticated;
commit;