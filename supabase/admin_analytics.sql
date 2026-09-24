-- Latent Archive Control Room analytics
-- Run this once in Supabase SQL Editor after the existing schema.

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


drop policy if exists own_profile_read on public.profiles;
create policy own_profile_read on public.profiles
for select using (auth.uid() = id or public.is_admin());

do $$
begin
  if to_regclass('public.favorites') is not null then
    execute 'alter table public.favorites enable row level security';
    execute 'drop policy if exists favorites_admin_read on public.favorites';
    execute 'create policy favorites_admin_read on public.favorites for select to authenticated using (public.is_admin())';
  end if;
end $$;
