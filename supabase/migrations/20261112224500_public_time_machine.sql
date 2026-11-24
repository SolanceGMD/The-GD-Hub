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
      a.action,
      coalesce(a.details -> 'after', a.details -> 'before') as snapshot
    from public.audit_logs a
    where a.target_type = 'levels'
      and a.action in ('insert','update','delete')
      and a.created_at <= p_as_of
      and a.target_id is not null
    order by a.target_id, a.created_at desc, a.id desc
  ),
  visible as (
    select snapshot
    from latest
    where latest.action <> 'delete'
      and snapshot ->> 'status' = 'published'
      and coalesce((snapshot ->> 'admin_hidden')::boolean,false) = false
  ),
  ranked as (
    select
      (snapshot ->> 'id')::uuid as id,
      row_number() over (order by coalesce(nullif(snapshot ->> 'sort_order','')::integer,0), snapshot ->> 'name')::integer as rank,
      snapshot
    from visible
  )
  select
    id,
    rank,
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
  from ranked
  order by rank
  limit 300;
$$;

revoke all on function public.wcl_public_time_machine(timestamptz) from public;
grant execute on function public.wcl_public_time_machine(timestamptz) to anon, authenticated;
