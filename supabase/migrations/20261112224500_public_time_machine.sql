create or replace function public.wcl_public_time_machine(p_as_of timestamptz)
returns table(
  id uuid, rank integer, name text, level_id text, creator text, verifier text,
  points integer, length text, difficulty text, thumbnail_url text,
  minimum_record_percent integer, youtube_url text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with latest as (
    select distinct on (a.target_id)
      a.target_id,
      a.details -> 'after' as snapshot
    from public.audit_logs a
    where a.target_type = 'levels'
      and a.action in ('insert','update')
      and a.created_at <= p_as_of
      and a.target_id is not null
      and a.details ? 'after'
    order by a.target_id, a.created_at desc, a.id desc
  )
  select
    (snapshot ->> 'id')::uuid,
    coalesce(nullif(snapshot ->> 'sort_order','')::integer, 0),
    snapshot ->> 'name',
    coalesce(snapshot ->> 'gd_level_id','—'),
    snapshot ->> 'creator',
    snapshot ->> 'verifier',
    coalesce(nullif(snapshot ->> 'points','')::integer,0),
    coalesce(snapshot ->> 'length','Unrated'),
    coalesce(snapshot ->> 'difficulty','Unrated'),
    snapshot ->> 'thumbnail_url',
    coalesce(nullif(snapshot ->> 'minimum_record_percent','')::integer,100),
    snapshot ->> 'youtube_url'
  from latest
  where snapshot ->> 'status' = 'published'
    and coalesce((snapshot ->> 'admin_hidden')::boolean,false) = false
  order by coalesce(nullif(snapshot ->> 'sort_order','')::integer,0), snapshot ->> 'name'
  limit 300;
$$;

revoke all on function public.wcl_public_time_machine(timestamptz) from public;
grant execute on function public.wcl_public_time_machine(timestamptz) to anon, authenticated;
