begin;

create or replace function wcl_private.apply_completion_award()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_points integer;
  v_minimum smallint;
begin
  if new.status = 'approved' and old.status is distinct from 'approved' then
    select l.points, l.minimum_record_percent
      into v_points, v_minimum
      from public.levels l
      where l.id = new.level_id and l.status = 'published';
    if v_points is null then
      raise exception 'Cannot approve completion for an unpublished level';
    end if;

    if new.verification_submission_id is not null then
      new.points_awarded := v_points;
    else
      if new.proof_url is null or new.proof_url !~* '^https://' then
        raise exception 'A public HTTPS completion video is required';
      end if;
      if new.raw_footage_url is null or new.raw_footage_url !~* '^https://' then
        raise exception 'A shareable HTTPS raw-footage URL is required';
      end if;
      if new.progress_percent is null or new.progress_percent < v_minimum then
        raise exception 'This level requires at least % percent progress', v_minimum;
      end if;
      new.points_awarded := case when v_points > 0
        then greatest(1, floor(v_points * new.progress_percent / 100.0)::integer)
        else 0
      end;
    end if;

    new.reviewed_at := coalesce(new.reviewed_at, now());
    if new.reviewer_id is null then
      new.reviewer_id := auth.uid();
    end if;
  elsif new.status <> 'approved' then
    new.points_awarded := 0;
  end if;
  return new;
end;
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
    and l.status = 'published'
    and (p_level_id is null or cs.level_id = p_level_id)
    and (p_submitter_id is null or cs.submitter_id = p_submitter_id)
  order by cs.progress_percent desc nulls last, cs.reviewed_at desc nulls last, cs.created_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 100);
$function$;

commit;
