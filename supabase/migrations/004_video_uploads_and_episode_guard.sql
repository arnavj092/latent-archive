-- Latent Archive: video-file uploads + main episode uniqueness
-- Apply once in Supabase SQL Editor.

create unique index if not exists episodes_main_season_episode_unique
on public.episodes (season, episode_number)
where content_type = 'main'
  and season is not null
  and episode_number is not null;

insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values (
  'episode-videos',
  'episode-videos',
  true,
  52428800,
  array['video/mp4','video/webm','video/quicktime','video/x-matroska','video/mpeg','video/ogg']
)
on conflict (id) do update
set public = true,
    file_size_limit = 52428800,
    allowed_mime_types = array['video/mp4','video/webm','video/quicktime','video/x-matroska','video/mpeg','video/ogg'];

drop policy if exists admin_video_insert on storage.objects;
create policy admin_video_insert
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'episode-videos'
  and public.is_admin()
);

drop policy if exists admin_video_update on storage.objects;
create policy admin_video_update
on storage.objects for update
to authenticated
using (
  bucket_id = 'episode-videos'
  and public.is_admin()
)
with check (
  bucket_id = 'episode-videos'
  and public.is_admin()
);

drop policy if exists admin_video_delete on storage.objects;
create policy admin_video_delete
on storage.objects for delete
to authenticated
using (
  bucket_id = 'episode-videos'
  and public.is_admin()
);
