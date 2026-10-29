create table if not exists public.point_adjustments (
  id bigint generated always as identity primary key,
  player_id uuid not null references public.profiles(id) on delete cascade,
  admin_id uuid not null references auth.users(id) on delete restrict,
  delta integer not null check (delta <> 0),
  previous_points integer not null,
  new_points integer not null check (new_points >= 0),
  reason text not null check (char_length(reason) between 1 and 500),
  created_at timestamptz not null default now()
);

alter table public.point_adjustments enable row level security;
revoke all on public.point_adjustments from anon, authenticated;
grant select on public.point_adjustments to authenticated;

drop policy if exists "Admins can view point adjustment history" on public.point_adjustments;
create policy "Admins can view point adjustment history"
on public.point_adjustments for select to authenticated
using (
  exists (
    select 1 from public.user_roles ur
    where ur.user_id = (select auth.uid())
      and ur.banned_at is null
      and (ur.role = 'admin' or ur.permissions ->> 'points.adjust' = 'true')
  )
);

create or replace function public.wcl_admin_adjust_player_points(
  p_user_id uuid,
  p_delta integer,
  p_reason text
)
returns table(previous_points integer, new_points integer)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin_id uuid := auth.uid();
  v_previous integer;
  v_new integer;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if v_admin_id is null then
    raise exception 'You must be signed in.';
  end if;
  if not exists (
    select 1 from public.user_roles ur
    where ur.user_id = v_admin_id
      and ur.banned_at is null
      and (ur.role = 'admin' or ur.permissions ->> 'points.adjust' = 'true')
  ) then
    raise exception 'You do not have permission to adjust player points.';
  end if;
  if p_user_id is null or p_delta is null or p_delta = 0 then
    raise exception 'Choose a player and a non-zero point adjustment.';
  end if;
  if abs(p_delta::bigint) > 1000000 then
    raise exception 'Point adjustment cannot exceed 1,000,000 points.';
  end if;
  if char_length(v_reason) < 1 or char_length(v_reason) > 500 then
    raise exception 'Reason must be between 1 and 500 characters.';
  end if;

  select p.points into v_previous
  from public.profiles p
  where p.id = p_user_id
  for update;

  if not found then
    raise exception 'Player profile not found.';
  end if;

  v_new := greatest(0, v_previous + p_delta);
  if v_new = v_previous then
    raise exception 'Points are already at 0; no points were removed.';
  end if;

  update public.profiles set points = v_new where id = p_user_id;

  insert into public.point_adjustments(player_id, admin_id, delta, previous_points, new_points, reason)
  values (p_user_id, v_admin_id, v_new - v_previous, v_previous, v_new, v_reason);

  return query select v_previous, v_new;
end;
$$;

revoke all on function public.wcl_admin_adjust_player_points(uuid, integer, text) from public, anon;
grant execute on function public.wcl_admin_adjust_player_points(uuid, integer, text) to authenticated;
