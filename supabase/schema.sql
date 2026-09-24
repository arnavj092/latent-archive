create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text,
  email text,
  avatar_url text,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz,
  is_admin boolean not null default false
);

create table if not exists public.collections (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  description text,
  kind text not null default 'main' check (kind in ('main','bonus','special')),
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

insert into public.collections (slug,name,description,kind,sort_order)
values
  ('main','Main Episodes','The primary episode sequence.','main',10),
  ('bonus','Bonus','Short or extra releases outside the main sequence.','bonus',20),
  ('specials','Specials','Standalone releases and other special entries.','special',30)
on conflict (slug) do nothing;

create table if not exists public.episodes (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  title text not null,
  description text,
  season integer,
  episode_number integer,
  collection_id uuid references public.collections(id) on delete set null,
  content_type text not null default 'main' check (content_type in ('main','bonus','special')),
  sort_order numeric(12,3),
  duration_seconds integer,
  release_date timestamptz,
  thumbnail_url text,
  video_provider text check (video_provider in ('youtube','vimeo','direct','embed')),
  video_url text,
  is_published boolean not null default false,
  is_premium boolean not null default false,
  accent_color text,
  is_featured boolean not null default false,
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
alter table public.collections enable row level security;
alter table public.episodes enable row level security;
alter table public.contact_messages enable row level security;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and is_admin = true
  );
$$;

revoke execute on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

drop policy if exists own_profile_read on public.profiles;
create policy own_profile_read on public.profiles for select using (auth.uid() = id);

drop policy if exists own_profile_update on public.profiles;
create policy own_profile_update on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);

drop policy if exists collections_public_read on public.collections;
create policy collections_public_read on public.collections for select using (true);

drop policy if exists collections_admin_write on public.collections;
create policy collections_admin_write on public.collections for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists published_episodes_read on public.episodes;
create policy published_episodes_read on public.episodes for select using (is_published = true);

drop policy if exists episodes_admin_read on public.episodes;
create policy episodes_admin_read on public.episodes for select to authenticated using (public.is_admin() or is_published = true);

drop policy if exists episodes_admin_insert on public.episodes;
create policy episodes_admin_insert on public.episodes for insert to authenticated with check (public.is_admin());

drop policy if exists episodes_admin_update on public.episodes;
create policy episodes_admin_update on public.episodes for update to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists episodes_admin_delete on public.episodes;
create policy episodes_admin_delete on public.episodes for delete to authenticated using (public.is_admin());

drop policy if exists contact_insert on public.contact_messages;
create policy contact_insert on public.contact_messages for insert to anon, authenticated with check (char_length(name) between 2 and 80 and position('@' in email) > 1 and char_length(message) between 10 and 4000);

drop policy if exists contacts_admin_read on public.contact_messages;
create policy contacts_admin_read on public.contact_messages for select to authenticated using (public.is_admin());

create or replace function public.get_admin_stats()
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'admin access required';
  end if;

  return json_build_object(
    'users', (select count(*) from public.profiles),
    'episodes', (select count(*) from public.episodes),
    'published', (select count(*) from public.episodes where is_published),
    'drafts', (select count(*) from public.episodes where not is_published),
    'premium', (select count(*) from public.episodes where is_premium),
    'featured', (select count(*) from public.episodes where is_featured)
  );
end;
$$;

revoke execute on function public.get_admin_stats() from public;
grant execute on function public.get_admin_stats() to authenticated;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id,name,email,avatar_url,last_seen_at,is_admin)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name',new.raw_user_meta_data->>'name'),
    new.email,
    new.raw_user_meta_data->>'avatar_url',
    now(),
    false
  )
  on conflict (id) do update set email = excluded.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

insert into storage.buckets (id,name,public)
values ('episode-thumbnails','episode-thumbnails',true)
on conflict (id) do update set public = true;

drop policy if exists admin_thumbnail_insert on storage.objects;
create policy admin_thumbnail_insert on storage.objects for insert to authenticated
with check (bucket_id='episode-thumbnails' and public.is_admin());

drop policy if exists admin_thumbnail_update on storage.objects;
create policy admin_thumbnail_update on storage.objects for update to authenticated
using (bucket_id='episode-thumbnails' and public.is_admin())
with check (bucket_id='episode-thumbnails' and public.is_admin());

drop policy if exists admin_thumbnail_delete on storage.objects;
create policy admin_thumbnail_delete on storage.objects for delete to authenticated
using (bucket_id='episode-thumbnails' and public.is_admin());


-- Lock administrator status to the database owner workflow.
revoke update on public.profiles from anon, authenticated;
grant update (name, avatar_url, last_seen_at) on public.profiles to authenticated;

-- Admin analytics: session time, visitor activity, and signed-in watch activity.
create table if not exists public.site_sessions (
  id uuid primary key,
  user_id uuid references auth.users(id) on delete set null,
  started_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  total_seconds integer not null default 0 check (total_seconds >= 0),
  page_views integer not null default 0 check (page_views >= 0),
  current_path text,
  updated_at timestamptz not null default now()
);

create index if not exists site_sessions_user_id_idx on public.site_sessions(user_id);
create index if not exists site_sessions_started_at_idx on public.site_sessions(started_at);
create index if not exists site_sessions_last_seen_at_idx on public.site_sessions(last_seen_at);

alter table public.site_sessions enable row level security;

drop policy if exists site_sessions_admin_read on public.site_sessions;
create policy site_sessions_admin_read on public.site_sessions
for select to authenticated
using (public.is_admin());

create or replace function public.record_site_session(
  p_session_id uuid,
  p_path text,
  p_seconds integer default 0,
  p_page_view boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_seconds integer := greatest(0, least(coalesce(p_seconds, 0), 120));
begin
  insert into public.site_sessions (
    id, user_id, started_at, last_seen_at, total_seconds, page_views, current_path, updated_at
  )
  values (
    p_session_id, v_user_id, now(), now(), v_seconds,
    case when coalesce(p_page_view, false) then 1 else 0 end,
    left(coalesce(p_path, ''), 300), now()
  )
  on conflict (id) do update
  set
    last_seen_at = now(),
    total_seconds = public.site_sessions.total_seconds + v_seconds,
    page_views = public.site_sessions.page_views + case when coalesce(p_page_view, false) then 1 else 0 end,
    current_path = left(coalesce(p_path, ''), 300),
    updated_at = now()
  where public.site_sessions.user_id is not distinct from v_user_id;

  if v_user_id is not null then
    update public.profiles
    set last_seen_at = now()
    where id = v_user_id;
  end if;
end;
$$;

revoke execute on function public.record_site_session(uuid,text,integer,boolean) from public;
grant execute on function public.record_site_session(uuid,text,integer,boolean) to anon, authenticated;


create table if not exists public.watch_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  episode_id uuid references public.episodes(id) on delete set null,
  watched_seconds integer not null default 0 check (watched_seconds >= 0),
  position_seconds integer,
  created_at timestamptz not null default now()
);

create index if not exists watch_events_user_id_idx on public.watch_events(user_id);
create index if not exists watch_events_episode_id_idx on public.watch_events(episode_id);
create index if not exists watch_events_created_at_idx on public.watch_events(created_at);

alter table public.watch_events enable row level security;

drop policy if exists watch_events_admin_read on public.watch_events;
create policy watch_events_admin_read on public.watch_events
for select to authenticated
using (public.is_admin());

create or replace function public.record_watch_event(
  p_episode_id uuid,
  p_seconds integer,
  p_position_seconds integer default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required';
  end if;

  insert into public.watch_events (
    user_id, episode_id, watched_seconds, position_seconds
  )
  values (
    auth.uid(),
    p_episode_id,
    greatest(0, least(coalesce(p_seconds, 0), 120)),
    case
      when p_position_seconds is null then null
      else greatest(0, least(p_position_seconds, 86400))
    end
  );
end;
$$;

revoke execute on function public.record_watch_event(uuid,integer,integer) from public;
grant execute on function public.record_watch_event(uuid,integer,integer) to authenticated;


-- Administrators may read user directory rows for the Control Room.
drop policy if exists own_profile_read on public.profiles;
create policy own_profile_read on public.profiles
for select using (auth.uid() = id or public.is_admin());

-- Favorites already exist in the deployed project; give administrators read-only
-- access when that table is present, while keeping this schema file idempotent.
do $$
begin
  if to_regclass('public.favorites') is not null then
    execute 'alter table public.favorites enable row level security';
    execute 'drop policy if exists favorites_admin_read on public.favorites';
    execute 'create policy favorites_admin_read on public.favorites for select to authenticated using (public.is_admin())';
  end if;
end $$;
