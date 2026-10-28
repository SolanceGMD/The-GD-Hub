-- Extend the existing WCL Geometry Dash Hub schema without replacing its data or role model.
begin;

alter table public.levels
  add column if not exists verifier text,
  add column if not exists minimum_record_percent smallint not null default 100;
alter table public.levels
  drop constraint if exists levels_minimum_record_percent_check;
alter table public.levels
  add constraint levels_minimum_record_percent_check check (minimum_record_percent between 1 and 100);

alter table public.level_submissions
  add column if not exists thumbnail_url text,
  add column if not exists minimum_record_percent smallint not null default 100;
alter table public.level_submissions
  drop constraint if exists level_submissions_minimum_record_percent_check;
alter table public.level_submissions
  add constraint level_submissions_minimum_record_percent_check check (minimum_record_percent between 1 and 100);
alter table public.level_submissions
  drop constraint if exists level_submissions_thumbnail_url_check;
alter table public.level_submissions
  add constraint level_submissions_thumbnail_url_check check (thumbnail_url is null or thumbnail_url ~* '^https://');

alter table public.completion_submissions
  add column if not exists raw_footage_url text,
  add column if not exists progress_percent smallint,
  add column if not exists player_notes text;
alter table public.completion_submissions
  drop constraint if exists completion_submissions_raw_footage_url_check;
alter table public.completion_submissions
  add constraint completion_submissions_raw_footage_url_check check (raw_footage_url is null or raw_footage_url ~* '^https://');
alter table public.completion_submissions
  drop constraint if exists completion_submissions_progress_percent_check;
alter table public.completion_submissions
  add constraint completion_submissions_progress_percent_check check (progress_percent is null or progress_percent between 1 and 100);
alter table public.completion_submissions
  drop constraint if exists completion_submissions_player_notes_check;
alter table public.completion_submissions
  add constraint completion_submissions_player_notes_check check (player_notes is null or char_length(player_notes) <= 1000);

alter table public.level_submissions drop constraint if exists level_submissions_status_check;
alter table public.level_submissions
  add constraint level_submissions_status_check check (status in ('pending','needs_evidence','approved','rejected'));
alter table public.completion_submissions drop constraint if exists completion_submissions_status_check;
alter table public.completion_submissions
  add constraint completion_submissions_status_check check (status in ('pending','needs_evidence','approved','rejected'));

-- User-created completion submissions must include both public proof and raw footage.
-- Verification completions created by the level-review RPC are exempt because they are
-- awarded through the verified_by account and reference their level submission.
create or replace function wcl_private.validate_completion_submission()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_minimum smallint;
begin
  if new.verification_submission_id is not null then
    return new;
  end if;
  if new.status not in ('pending','approved') then
    return new;
  end if;
  if new.proof_url is null or new.proof_url !~* '^https://' then
    raise exception 'A public HTTPS completion video is required';
  end if;
  if new.raw_footage_url is null or new.raw_footage_url !~* '^https://' then
    raise exception 'A shareable HTTPS raw-footage URL is required';
  end if;
  if new.progress_percent is null or new.progress_percent < 1 or new.progress_percent > 100 then
    raise exception 'Progress must be between 1 and 100 percent';
  end if;
  select l.minimum_record_percent into v_minimum
    from public.levels l
    where l.id = new.level_id and l.status = 'published';
  if not found then
    raise exception 'Only published levels accept completion records';
  end if;
  if new.progress_percent < v_minimum then
    raise exception 'This level requires at least % percent progress', v_minimum;
  end if;
  return new;
end;
$function$;

revoke all on function wcl_private.validate_completion_submission() from public, anon, authenticated;
drop trigger if exists wcl_validate_completion_submission on public.completion_submissions;
create trigger wcl_validate_completion_submission
before insert on public.completion_submissions
for each row execute function wcl_private.validate_completion_submission();

-- Completion points scale with the level's configured score and the achieved percentage.
-- Verification completions still award the full level score through the existing RPC.
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
      new.points_awarded := floor(v_points * new.progress_percent / 100.0)::integer;
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

-- Use the existing secure review RPC and existing point-award triggers, while also
-- publishing the thumbnail, verifier, and per-level minimum record threshold.
create or replace function public.wcl_review_level_submission(
  p_submission_id uuid,
  p_status text,
  p_points integer,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  s public.level_submissions%rowtype;
  v_level_id uuid;
  v_run_id uuid;
  v_verifier_name text;
begin
  if auth.uid() is null or not wcl_private.has_permission('submissions.review') then
    raise exception 'Missing permission: submissions.review' using errcode = '42501';
  end if;
  if p_status not in ('approved','rejected','needs_evidence') then
    raise exception 'Review status must be approved, rejected, or needs_evidence';
  end if;
  if p_points is null or p_points < 0 or p_points > 1000000 then
    raise exception 'Approved points must be between 0 and 1000000';
  end if;
  if p_note is not null and char_length(p_note) > 1000 then
    raise exception 'Review note is too long';
  end if;

  select * into s
  from public.level_submissions
  where id = p_submission_id
  for update;

  if not found or s.status not in ('pending','needs_evidence') then
    raise exception 'Pending level submission not found';
  end if;

  if p_status = 'approved' then
    if s.gd_level_id is not null and exists (
      select 1 from public.levels l where l.gd_level_id = s.gd_level_id and l.status = 'published'
    ) then
      raise exception 'A published level already uses Geometry Dash ID %', s.gd_level_id;
    end if;

    select p.gd_username into v_verifier_name
      from public.profiles p where p.id = s.verified_by;

    insert into public.levels(
      name, gd_level_id, creator, description, points, difficulty, length,
      youtube_url, status, created_by, thumbnail_url, minimum_record_percent, verifier
    )
    values(
      s.name, s.gd_level_id, s.creator, s.description, p_points, s.difficulty, s.length,
      s.youtube_url, 'published', s.submitter_id, s.thumbnail_url,
      s.minimum_record_percent, v_verifier_name
    )
    returning id into v_level_id;

    if s.verified_by is not null then
      insert into public.completion_submissions(
        submitter_id, level_id, proof_url, status, points_awarded,
        reviewer_id, review_note, reviewed_at, verification_submission_id,
        progress_percent, raw_footage_url, player_notes
      )
      values(s.verified_by, v_level_id, null, 'pending', 0, null, null, null, s.id, 100, null, null)
      returning id into v_run_id;

      update public.completion_submissions
      set status = 'approved', reviewer_id = auth.uid(), reviewed_at = now()
      where id = v_run_id;
    end if;
  end if;

  update public.level_submissions
  set status = p_status,
      reviewer_id = auth.uid(),
      reviewed_at = now(),
      review_note = nullif(trim(p_note),'')
  where id = p_submission_id;

  return v_level_id;
end;
$function$;

revoke all on function public.wcl_review_level_submission(uuid,text,integer,text) from public, anon;
grant execute on function public.wcl_review_level_submission(uuid,text,integer,text) to authenticated;

-- Public leaderboard RPC exposes only aggregate public player statistics, not submission rows.
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
    coalesce(sum(cs.points_awarded) filter (where cs.verification_submission_id is null and cs.status = 'approved'), 0)::bigint,
    coalesce(sum(cs.points_awarded) filter (where cs.verification_submission_id is not null and cs.status = 'approved'), 0)::bigint,
    count(cs.id) filter (where cs.verification_submission_id is null and cs.status = 'approved'),
    count(cs.id) filter (where cs.verification_submission_id is not null and cs.status = 'approved')
  from public.profiles p
  left join public.completion_submissions cs on cs.submitter_id = p.id and cs.status = 'approved'
  group by p.id, p.gd_username, p.points
  order by p.points desc, p.gd_username asc;
$function$;
revoke all on function public.wcl_public_player_points() from public;
grant execute on function public.wcl_public_player_points() to anon, authenticated;

-- Public, read-only feed for approved records. Raw footage and review notes are deliberately omitted.
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
    cs.points_awarded,
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
revoke all on function public.wcl_public_accepted_records(uuid,uuid,integer) from public;
grant execute on function public.wcl_public_accepted_records(uuid,uuid,integer) to anon, authenticated;

commit;
