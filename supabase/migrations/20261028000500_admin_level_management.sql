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

create or replace function public.wcl_admin_set_level_rank(p_level_id uuid, p_rank integer)
returns void language plpgsql security definer set search_path = ''
as $function$
declare v_old_rank integer; v_count integer; v_target_rank integer;
begin
  if auth.uid() is null or not wcl_private.has_permission('levels.manage') then
    raise exception 'Missing permission: levels.manage' using errcode = '42501';
  end if;
  if p_rank is null or p_rank < 1 or p_rank > 100000 then raise exception 'Invalid rank'; end if;
  select sort_order into v_old_rank from public.levels
    where id=p_level_id and status='published' and not admin_hidden for update;
  if not found then raise exception 'Published level not found'; end if;
  select count(*) into v_count from public.levels where status='published' and not admin_hidden;
  v_target_rank := least(p_rank,v_count);
  if v_target_rank = v_old_rank then return; end if;
  update public.levels set sort_order=sort_order+1000000 where status='published' and not admin_hidden;
  with ordered as (
    select id, row_number() over (order by
      case
        when id=p_level_id then v_target_rank
        when v_old_rank < v_target_rank and sort_order-1000000 > v_old_rank and sort_order-1000000 <= v_target_rank then sort_order-1000001
        when v_old_rank > v_target_rank and sort_order-1000000 >= v_target_rank and sort_order-1000000 < v_old_rank then sort_order-999999
        else sort_order-1000000
      end, sort_order, id) as new_rank
    from public.levels where status='published' and not admin_hidden
  )
  update public.levels l set sort_order=o.new_rank from ordered o where o.id=l.id;
end;
$function$;
revoke all on function public.wcl_admin_set_level_rank(uuid,integer) from public, anon;
grant execute on function public.wcl_admin_set_level_rank(uuid,integer) to authenticated;

create or replace function public.wcl_admin_update_level(
  p_level_id uuid, p_name text, p_gd_level_id text, p_creator text, p_description text,
  p_points integer, p_minimum_record_percent integer, p_verifier text, p_youtube_url text
)
returns void language plpgsql security definer set search_path = ''
as $function$
begin
  if auth.uid() is null or not wcl_private.has_permission('levels.manage') then
    raise exception 'Missing permission: levels.manage' using errcode = '42501';
  end if;
  if nullif(trim(p_name),'') is null or char_length(trim(p_name)) > 160 then raise exception 'Invalid level name'; end if;
  if p_points is null or p_points < 0 or p_points > 1000000 then raise exception 'Invalid points'; end if;
  if p_minimum_record_percent is null or p_minimum_record_percent < 1 or p_minimum_record_percent > 100 then raise exception 'Invalid minimum record percent'; end if;
  if nullif(trim(coalesce(p_youtube_url,'')),'') is not null and trim(p_youtube_url) !~* '^https://' then raise exception 'Video URL must use HTTPS'; end if;
  update public.levels set
    name=trim(p_name), gd_level_id=nullif(trim(coalesce(p_gd_level_id,'')),''),
    creator=nullif(trim(coalesce(p_creator,'')),''),
    description=nullif(trim(coalesce(p_description,'')),''),
    points=p_points, minimum_record_percent=p_minimum_record_percent::smallint,
    verifier=nullif(trim(coalesce(p_verifier,'')),''),
    youtube_url=nullif(trim(coalesce(p_youtube_url,'')),''),
    thumbnail_url=case
      when nullif(trim(coalesce(p_youtube_url,'')),'') is null then null
      when regexp_match(trim(p_youtube_url), '(?:youtu\\.be/|youtube\\.com/(?:watch\\?v=|embed/|shorts/|live/))([A-Za-z0-9_-]{6,})') is not null
      then 'https://img.youtube.com/vi/' || (regexp_match(trim(p_youtube_url), '(?:youtu\\.be/|youtube\\.com/(?:watch\\?v=|embed/|shorts/|live/))([A-Za-z0-9_-]{6,})'))[1] || '/hqdefault.jpg'
      else thumbnail_url end
  where id=p_level_id and status='published';
  if not found then raise exception 'Published level not found'; end if;
end;
$function$;
revoke all on function public.wcl_admin_update_level(uuid,text,text,text,text,integer,integer,text,text) from public, anon;
grant execute on function public.wcl_admin_update_level(uuid,text,text,text,text,integer,integer,text,text) to authenticated;

create or replace function public.wcl_admin_resubmit_level(p_level_id uuid)
returns uuid language plpgsql security definer set search_path = ''
as $function$
declare l public.levels%rowtype; v_verifier_id uuid; v_submission_id uuid;
begin
  if auth.uid() is null or not wcl_private.has_permission('levels.manage') then
    raise exception 'Missing permission: levels.manage' using errcode = '42501';
  end if;
  select * into l from public.levels where id=p_level_id and status='published';
  if not found then raise exception 'Published level not found'; end if;
  update public.levels set admin_hidden = true where id = p_level_id;
  if l.verifier is not null then
    select id into v_verifier_id from public.profiles where lower(gd_username)=lower(l.verifier) limit 1;
  end if;
  insert into public.level_submissions(
    name, gd_level_id, creator, description, suggested_points, difficulty, length,
    youtube_url, status, submitter_id, verified_by, thumbnail_url, minimum_record_percent
  ) values (
    l.name, l.gd_level_id, coalesce(l.creator,''), l.description, coalesce(l.points,0),
    l.difficulty, coalesce(l.length,'Unrated'), l.youtube_url, 'pending',
    auth.uid(), v_verifier_id, l.thumbnail_url, coalesce(l.minimum_record_percent,100)
  ) returning id into v_submission_id;
  return v_submission_id;
end;
$function$;
revoke all on function public.wcl_admin_resubmit_level(uuid) from public, anon;
grant execute on function public.wcl_admin_resubmit_level(uuid) to authenticated;


-- Resubmitted levels are hidden while pending; permit the replacement to reuse the same GD ID.
create or replace function public.wcl_review_level_submission(
  p_submission_id uuid, p_status text, p_points integer, p_note text default null
)
returns uuid language plpgsql security definer set search_path = ''
as $function$
declare s public.level_submissions%rowtype; v_level_id uuid; v_run_id uuid; v_verifier_name text;
begin
  if auth.uid() is null or not wcl_private.has_permission('submissions.review') then
    raise exception 'Missing permission: submissions.review' using errcode = '42501';
  end if;
  if p_status not in ('approved','rejected','needs_evidence') then raise exception 'Invalid review status'; end if;
  if p_points is null or p_points < 0 or p_points > 1000000 then raise exception 'Invalid points'; end if;
  if p_note is not null and char_length(p_note) > 1000 then raise exception 'Review note is too long'; end if;
  select * into s from public.level_submissions where id=p_submission_id for update;
  if not found or s.status not in ('pending','needs_evidence') then raise exception 'Pending level submission not found'; end if;
  if p_status='approved' then
    if s.gd_level_id is not null and exists (
      select 1 from public.levels l where l.gd_level_id=s.gd_level_id and l.status='published' and not l.admin_hidden
    ) then raise exception 'A visible published level already uses Geometry Dash ID %', s.gd_level_id; end if;
    select p.gd_username into v_verifier_name from public.profiles p where p.id=s.verified_by;
    insert into public.levels(
      name, gd_level_id, creator, description, points, difficulty, length,
      youtube_url, status, created_by, thumbnail_url, minimum_record_percent, verifier
    ) values (
      s.name, s.gd_level_id, s.creator, s.description, p_points, s.difficulty, s.length,
      s.youtube_url, 'published', s.submitter_id, s.thumbnail_url, s.minimum_record_percent, v_verifier_name
    ) returning id into v_level_id;
    if s.verified_by is not null then
      insert into public.completion_submissions(
        submitter_id, level_id, proof_url, status, points_awarded, reviewer_id, review_note,
        reviewed_at, verification_submission_id, progress_percent, raw_footage_url, player_notes
      ) values(s.verified_by,v_level_id,null,'pending',0,null,null,null,s.id,100,null,null)
      returning id into v_run_id;
      update public.completion_submissions set status='approved',reviewer_id=auth.uid(),reviewed_at=now() where id=v_run_id;
    end if;
  end if;
  update public.level_submissions set status=p_status, reviewer_id=auth.uid(), reviewed_at=now(),
    review_note=nullif(trim(p_note),'') where id=p_submission_id;
  return v_level_id;
end;
$function$;
revoke all on function public.wcl_review_level_submission(uuid,text,integer,text) from public, anon;
grant execute on function public.wcl_review_level_submission(uuid,text,integer,text) to authenticated;

commit;
