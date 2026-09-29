-- Analytics reliability fix
-- Run this once in Supabase SQL Editor on the existing project.
-- Keeps RLS enabled and only changes the two existing tracking RPCs.

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
  v_seconds integer := greatest(0, least(coalesce(p_seconds, 0), 90));
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
    user_id = coalesce(public.site_sessions.user_id, v_user_id),
    last_seen_at = now(),
    total_seconds = public.site_sessions.total_seconds + v_seconds,
    page_views = public.site_sessions.page_views
      + case when coalesce(p_page_view, false) then 1 else 0 end,
    current_path = left(coalesce(p_path, ''), 300),
    updated_at = now()
  where public.site_sessions.user_id is not distinct from v_user_id
     or public.site_sessions.user_id is null;

  if v_user_id is not null then
    update public.profiles
    set last_seen_at = now()
    where id = v_user_id;
  end if;
end;
$$;

revoke execute on function public.record_site_session(uuid,text,integer,boolean) from public;
grant execute on function public.record_site_session(uuid,text,integer,boolean) to anon, authenticated;

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
