-- Backfill YouTube thumbnails and make public point breakdowns consistent with existing WCL points.
begin;

update public.levels
set thumbnail_url = 'https://img.youtube.com/vi/' ||
  (regexp_match(youtube_url, '(?:youtu\.be/|youtube\.com/(?:watch\?v=|embed/|shorts/|live/))([A-Za-z0-9_-]{6,})'))[1] ||
  '/hqdefault.jpg'
where thumbnail_url is null
  and youtube_url is not null
  and regexp_match(youtube_url, '(?:youtu\.be/|youtube\.com/(?:watch\?v=|embed/|shorts/|live/))([A-Za-z0-9_-]{6,})') is not null;

update public.level_submissions
set thumbnail_url = 'https://img.youtube.com/vi/' ||
  (regexp_match(youtube_url, '(?:youtu\.be/|youtube\.com/(?:watch\?v=|embed/|shorts/|live/))([A-Za-z0-9_-]{6,})'))[1] ||
  '/hqdefault.jpg'
where thumbnail_url is null
  and youtube_url is not null
  and regexp_match(youtube_url, '(?:youtu\.be/|youtube\.com/(?:watch\?v=|embed/|shorts/|live/))([A-Za-z0-9_-]{6,})') is not null;

create or replace function public.wcl_public_player_points()
returns table(
  player_id uuid,
  gd_username text,
  points integer,
  completion_points bigint,
  verification_points bigint,
  completions bigint,
  verifications bigint
)
language sql
stable
security definer
set search_path = ''
as $function$
  select
    p.id,
    p.gd_username,
    p.points,
    coalesce(sum(cs.points_awarded) filter (
      where cs.verification_submission_id is null and cs.status = 'approved'
    ), 0)::bigint,
    coalesce(sum(
      case when cs.verification_submission_id is not null
        then greatest(cs.points_awarded, coalesce(l.points, 0))
        else 0
      end
    ) filter (where cs.verification_submission_id is not null and cs.status = 'approved'), 0)::bigint,
    count(cs.id) filter (
      where cs.verification_submission_id is null and cs.status = 'approved'
    ),
    count(cs.id) filter (
      where cs.verification_submission_id is not null and cs.status = 'approved'
    )
  from public.profiles p
  left join public.completion_submissions cs on cs.submitter_id = p.id and cs.status = 'approved'
  left join public.levels l on l.id = cs.level_id
  group by p.id, p.gd_username, p.points
  order by p.points desc, p.gd_username asc;
$function$;

create or replace function public.wcl_public_accepted_records(
  p_level_id uuid default null,
  p_submitter_id uuid default null,
  p_limit integer default 100
)
returns table(
  id uuid,
  submitter_id uuid,
  gd_username text,
  level_id uuid,
  level_name text,
  level_rank integer,
  gd_level_id text,
  level_thumbnail_url text,
  level_points integer,
  proof_url text,
  progress_percent smallint,
  points_awarded integer,
  verification_submission_id uuid,
  created_at timestamptz,
  reviewed_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $function$
  select
    cs.id,
    cs.submitter_id,
    p.gd_username,
    cs.level_id,
    l.name,
    l.sort_order,
    l.gd_level_id,
    l.thumbnail_url,
    l.points,
    cs.proof_url,
    cs.progress_percent,
    case when cs.verification_submission_id is not null
      then greatest(cs.points_awarded, coalesce(l.points, 0))
      else cs.points_awarded
    end,
    cs.verification_submission_id,
    cs.created_at,
    cs.reviewed_at
  from public.completion_submissions cs
  join public.profiles p on p.id = cs.submitter_id
  join public.levels l on l.id = cs.level_id
  where cs.status = 'approved'
    and (p_level_id is null or cs.level_id = p_level_id)
    and (p_submitter_id is null or cs.submitter_id = p_submitter_id)
  order by cs.progress_percent desc nulls last, cs.reviewed_at desc nulls last, cs.created_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 100);
$function$;

commit;
