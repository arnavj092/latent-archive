create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text,
  email text,
  avatar_url text,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz
);

create table if not exists public.episodes (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  title text not null,
  description text,
  season integer,
  episode_number integer,
  release_date timestamptz,
  thumbnail_url text,
  video_provider text check (video_provider in ('youtube','vimeo','direct','embed')),
  video_url text,
  is_published boolean not null default false,
  is_premium boolean not null default false,
  accent_color text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.contact_messages (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text not null,
  message text not null,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
alter table public.episodes enable row level security;
alter table public.contact_messages enable row level security;

drop policy if exists own_profile_read on public.profiles;
create policy own_profile_read on public.profiles for select using (auth.uid() = id);

drop policy if exists own_profile_update on public.profiles;
create policy own_profile_update on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);

drop policy if exists published_episodes_read on public.episodes;
create policy published_episodes_read on public.episodes for select using (is_published = true);

drop policy if exists contact_insert on public.contact_messages;
create policy contact_insert on public.contact_messages for insert to anon, authenticated with check (char_length(name) between 2 and 80 and position('@' in email) > 1 and char_length(message) between 10 and 4000);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, name, email, avatar_url, last_seen_at)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
    new.email,
    new.raw_user_meta_data->>'avatar_url',
    now()
  )
  on conflict (id) do update set email = excluded.email, last_seen_at = now();
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row
execute function public.handle_new_user();
