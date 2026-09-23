-- Latent Archive: Bunny Stream metadata
alter table public.episodes
  add column if not exists bunny_video_id text,
  add column if not exists bunny_status integer,
  add column if not exists bunny_encode_progress integer;

create index if not exists episodes_bunny_video_idx on public.episodes(bunny_video_id);

alter table public.episodes
  drop constraint if exists episodes_video_provider_check;

alter table public.episodes
  add constraint episodes_video_provider_check
  check (video_provider in ('youtube','vimeo','direct','embed','bunny'));
