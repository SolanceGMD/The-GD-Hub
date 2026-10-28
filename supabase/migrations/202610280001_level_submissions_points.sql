-- Add level proposals, review workflow, and auditable player points.
-- Point policy: +5 for an approved level verification; +1 for each accepted completion.
-- Points are awarded only by database triggers after staff approval, never by client-supplied values.

create type public.level_submission_status as enum ('pending','needs_evidence','accepted','rejected','withdrawn');

create table public.level_submissions (
  id uuid primary key default gen_random_uuid(),
  submitter_id uuid not null references public.profiles(id) on delete restrict,
  level_name text not null check (char_length(trim(level_name)) between 1 and 120),
  game_level_id text not null check (game_level_id ~ '^[0-9]{1,20}$'),
  creators text[] not null default '{}' check (cardinality(creators) <= 12),
  verifier_name text not null check (char_length(trim(verifier_name)) between 1 and 80),
  verification_video_url text not null check (verification_video_url ~ '^https://'),
  description text not null check (char_length(trim(description)) between 1 and 4000),
  thumbnail_url text not null check (thumbnail_url ~ '^https://'),
  difficulty text not null default 'Extreme Demon' check (char_length(difficulty) between 1 and 60),
  status public.level_submission_status not null default 'pending',
  review_reason text check (review_reason is null or char_length(review_reason) <= 2000),
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index level_submissions_review_idx on public.level_submissions(status, created_at) where status in ('pending','needs_evidence');
create index level_submissions_submitter_idx on public.level_submissions(submitter_id, created_at desc);
create unique index one_active_level_submission_per_game_id on public.level_submissions(game_level_id) where status in ('pending','needs_evidence','accepted');

create table public.points_ledger (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.profiles(id) on delete restrict,
  event_type text not null check (event_type in ('completion','verification')),
  points integer not null check (points > 0),
  record_submission_id uuid references public.record_submissions(id) on delete restrict,
  level_submission_id uuid references public.level_submissions(id) on delete restrict,
  description text not null check (char_length(description) between 1 and 240),
  created_at timestamptz not null default now(),
  check (
    (event_type = 'completion' and record_submission_id is not null and level_submission_id is null and points = 1)
    or
    (event_type = 'verification' and level_submission_id is not null and record_submission_id is null and points = 5)
  )
);
create unique index one_completion_point_per_record on public.points_ledger(record_submission_id) where record_submission_id is not null;
create unique index one_verification_point_per_level_submission on public.points_ledger(level_submission_id) where level_submission_id is not null;
create index points_ledger_player_created_idx on public.points_ledger(player_id, created_at desc);

alter table public.level_submissions enable row level security;
alter table public.points_ledger enable row level security;

create policy "players read own level submissions and staff read all"
  on public.level_submissions for select to authenticated
  using (submitter_id = (select auth.uid()) or (select private.has_role(array['moderator','administrator']::public.app_role[])));
create policy "players submit level proposals for themselves"
  on public.level_submissions for insert to authenticated
  with check (
    submitter_id = (select auth.uid())
    and status = 'pending'
    and reviewed_by is null
    and reviewed_at is null
  );
create policy "staff review level proposals"
  on public.level_submissions for update to authenticated
  using ((select private.has_role(array['moderator','administrator']::public.app_role[])))
  with check (
    (select private.has_role(array['moderator','administrator']::public.app_role[]))
    and status in ('pending','needs_evidence','accepted','rejected','withdrawn')
  );

create policy "public read points ledger"
  on public.points_ledger for select to anon, authenticated using (true);
create policy "staff write points ledger"
  on public.points_ledger for insert to authenticated
  with check ((select private.has_role(array['moderator','administrator']::public.app_role[])));

create trigger level_submissions_touch before update on public.level_submissions
  for each row execute function private.touch_updated_at();

-- Approval creates the ranked level and creator rows in the same transaction as the review.
-- The database assigns rank; submitted rank values are never trusted.
create or replace function private.publish_approved_level_submission()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  created_level_id uuid;
  next_rank integer;
  creator text;
begin
  if new.status = 'accepted' and old.status is distinct from 'accepted' then
    if exists (select 1 from public.levels l where l.level_id = new.game_level_id) then
      raise exception 'A level with game ID % already exists', new.game_level_id;
    end if;

    select coalesce(max(l.rank), 0) + 1 into next_rank
      from public.levels l where l.status = 'ranked';

    insert into public.levels (
      rank, name, level_id, verifier, difficulty, description,
      status, video_url, thumbnail_url, added_by, date_verified
    ) values (
      next_rank, new.level_name, new.game_level_id, new.verifier_name,
      new.difficulty, new.description, 'ranked', new.verification_video_url,
      new.thumbnail_url, new.submitter_id, now()
    ) returning id into created_level_id;

    foreach creator in array new.creators loop
      if char_length(trim(creator)) > 0 then
        insert into public.level_creators(level_id, creator_name)
        values (created_level_id, trim(creator))
        on conflict (level_id, creator_name) do nothing;
      end if;
    end loop;

    insert into public.points_ledger(player_id, event_type, points, level_submission_id, description)
    values (new.submitter_id, 'verification', 5, new.id, 'Level verification approved: ' || new.level_name)
    on conflict do nothing;

    insert into public.moderation_actions(actor_id, target_user_id, level_id, action, reason, metadata)
    values (new.reviewed_by, new.submitter_id, created_level_id, 'level_created', new.review_reason,
      jsonb_build_object('source_submission_id', new.id, 'game_level_id', new.game_level_id, 'rank', next_rank));
  end if;
  return new;
end;
$$;

create trigger publish_approved_level_submission
  after update of status on public.level_submissions
  for each row execute function private.publish_approved_level_submission();

-- Award completion points only when staff changes a record to accepted.
create or replace function private.award_accepted_completion_points()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  level_name text;
begin
  if new.status = 'accepted' and old.status is distinct from 'accepted' then
    select l.name into level_name from public.levels l where l.id = new.level_id;
    insert into public.points_ledger(player_id, event_type, points, record_submission_id, description)
    values (new.player_id, 'completion', 1, new.id, 'Accepted completion: ' || coalesce(level_name, 'ranked level'))
    on conflict do nothing;
  end if;
  return new;
end;
$$;
create trigger award_accepted_completion_points
  after update of status on public.record_submissions
  for each row execute function private.award_accepted_completion_points();

create or replace view public.player_points with (security_invoker = true) as
select
  p.id as player_id,
  p.username,
  coalesce(sum(pl.points), 0)::integer as points,
  coalesce(sum(pl.points) filter (where pl.event_type = 'completion'), 0)::integer as completion_points,
  coalesce(sum(pl.points) filter (where pl.event_type = 'verification'), 0)::integer as verification_points,
  count(pl.id) filter (where pl.event_type = 'completion')::integer as accepted_completions,
  count(pl.id) filter (where pl.event_type = 'verification')::integer as verified_levels
from public.profiles p
left join public.points_ledger pl on pl.player_id = p.id
group by p.id, p.username;

grant select on public.level_submissions to authenticated;
grant insert(submitter_id,level_name,game_level_id,creators,verifier_name,verification_video_url,description,thumbnail_url,difficulty,status) on public.level_submissions to authenticated;
grant update(status,review_reason,reviewed_by,reviewed_at) on public.level_submissions to authenticated;
grant select on public.points_ledger, public.player_points to anon, authenticated;
grant insert on public.points_ledger to authenticated;

-- Staff may create level rows from an approved proposal. The trigger still validates
-- and populates the complete level; public users cannot create or rank levels.
create policy "staff insert levels" on public.levels for insert to authenticated
  with check ((select private.has_role(array['moderator','administrator']::public.app_role[])));
grant insert on public.levels to authenticated;
