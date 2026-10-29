begin;
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('profile-assets','profile-assets',true,5242880,array['image/png','image/jpeg','image/webp','image/gif'])
on conflict (id) do update set public=true, file_size_limit=5242880, allowed_mime_types=array['image/png','image/jpeg','image/webp','image/gif'];

drop policy if exists "Profile images are publicly viewable" on storage.objects;
create policy "Profile images are publicly viewable"
  on storage.objects for select to anon, authenticated
  using (bucket_id='profile-assets');
drop policy if exists "Users upload own profile images" on storage.objects;
create policy "Users upload own profile images"
  on storage.objects for insert to authenticated
  with check (bucket_id='profile-assets' and (storage.foldername(name))[1]=(select auth.uid())::text);
drop policy if exists "Users update own profile images" on storage.objects;
create policy "Users update own profile images"
  on storage.objects for update to authenticated
  using (bucket_id='profile-assets' and (storage.foldername(name))[1]=(select auth.uid())::text)
  with check (bucket_id='profile-assets' and (storage.foldername(name))[1]=(select auth.uid())::text);
drop policy if exists "Users delete own profile images" on storage.objects;
create policy "Users delete own profile images"
  on storage.objects for delete to authenticated
  using (bucket_id='profile-assets' and (storage.foldername(name))[1]=(select auth.uid())::text);
commit;