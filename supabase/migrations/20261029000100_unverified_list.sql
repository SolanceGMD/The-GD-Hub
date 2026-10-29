begin;

create table if not exists public.unverified_levels (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 1 and 160),
  gd_level_id text,
  creator text not null check (char_length(trim(creator)) between 1 and 120),
  progress_percent smallint not null check (progress_percent between 21 and 100),
  evidence_url text not null check (evidence_url ~* '^https://'),
  notes text not null default '' check (char_length(notes) <= 1000),
  submitter_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create index if not exists unverified_levels_progress_idx
  on public.unverified_levels (progress_percent desc, created_at desc);
create index if not exists unverified_levels_submitted_by_idx
  on public.unverified_levels (submitter_id, created_at desc);

alter table public.unverified_levels enable row level security;

drop policy if exists "Anyone can view unverified list" on public.unverified_levels;
create policy "Anyone can view unverified list"
  on public.unverified_levels for select to anon, authenticated
  using (true);

drop policy if exists "Players submit their own unverified progress" on public.unverified_levels;
create policy "Players submit their own unverified progress"
  on public.unverified_levels for insert to authenticated
  with check (
    auth.uid() = submitter_id
    and progress_percent > 20
    and evidence_url ~* '^https://'
  );

grant select on public.unverified_levels to anon, authenticated;
grant insert on public.unverified_levels to authenticated;

commit;