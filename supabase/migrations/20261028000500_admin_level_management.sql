-- Add safe visibility control for published levels; keep historical completion rows intact.
begin;
alter table public.levels add column if not exists admin_hidden boolean not null default false;

create or replace function public.wcl_admin_set_level_visibility(p_level_id uuid, p_visible boolean)
returns void language plpgsql security definer set search_path = ''
as $function$
begin
  if auth.uid() is null or not wcl_private.has_permission('levels.manage') then
    raise exception 'Missing permission: levels.manage' using errcode = '42501';
  end if;
  update public.levels set admin_hidden = not p_visible
  where id = p_level_id and status = 'published';
  if not found then raise exception 'Published level not found'; end if;
end;
$function$;
revoke all on function public.wcl_admin_set_level_visibility(uuid,boolean) from public, anon;
grant execute on function public.wcl_admin_set_level_visibility(uuid,boolean) to authenticated;
commit;
