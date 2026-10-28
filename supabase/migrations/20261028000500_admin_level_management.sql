-- Add safe visibility control for published levels; keep historical completion rows intact.
begin;
alter table public.levels add column if not exists admin_hidden boolean not null default false;
commit;
