alter table public.profiles
  add column if not exists tagline text not null default '' check (char_length(tagline) <= 60);

alter table public.profiles
  add column if not exists accent_color text not null default '#68e5eb'
  check (accent_color ~ '^#[0-9A-Fa-f]{6}$');

grant update (tagline, accent_color) on public.profiles to authenticated;
