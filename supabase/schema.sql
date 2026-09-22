create extension if not exists pgcrypto;
create table if not exists public.episodes (id uuid primary key default gen_random_uuid(), slug text not null unique, title text not null, description text, season integer, episode_number integer, release_date timestamptz, thumbnail_url text, video_provider text check (video_provider in ('youtube','vimeo','direct','embed')), video_url text, is_published boolean not null default false, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table if not exists public.contact_messages (id uuid primary key default gen_random_uuid(), name text not null, email text not null, message text not null, created_at timestamptz not null default now());
alter table public.episodes enable row level security;
alter table public.contact_messages enable row level security;
drop policy if exists published_episodes_read on public.episodes;
create policy published_episodes_read on public.episodes for select using (is_published = true);
drop policy if exists contact_insert on public.contact_messages;
create policy contact_insert on public.contact_messages for insert to anon, authenticated with check (char_length(name) between 2 and 80 and position('@' in email) > 1 and char_length(message) between 10 and 4000);
