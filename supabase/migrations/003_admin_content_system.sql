-- Latent Archive: admin content manager + collections + storage
-- Run once in Supabase SQL Editor.

alter table public.profiles
  add column if not exists is_admin boolean not null default false;

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

alter table public.episodes
  add column if not exists collection_id uuid references public.collections(id) on delete set null,
  add column if not exists content_type text not null default 'main' check (content_type in ('main','bonus','special')),
  add column if not exists sort_order numeric(12,3),
  add column if not exists duration_seconds integer,
  add column if not exists is_featured boolean not null default false;

update public.episodes e
set collection_id = c.id
from public.collections c
where e.collection_id is null
  and c.slug = 'main';

update public.episodes
set sort_order = coalesce(sort_order, episode_number::numeric, 0)
where sort_order is null;

create index if not exists episodes_collection_idx on public.episodes(collection_id);
create index if not exists episodes_content_type_idx on public.episodes(content_type);
create index if not exists episodes_sort_order_idx on public.episodes(sort_order);
create index if not exists episodes_published_idx on public.episodes(is_published);

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and is_admin = true
  );
$$;

revoke execute on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

alter table public.collections enable row level security;

drop policy if exists collections_public_read on public.collections;
create policy collections_public_read
on public.collections for select
using (true);

drop policy if exists collections_admin_write on public.collections;
create policy collections_admin_write
on public.collections for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists episodes_admin_read on public.episodes;
create policy episodes_admin_read
on public.episodes for select
to authenticated
using (public.is_admin() or is_published = true);

drop policy if exists episodes_admin_insert on public.episodes;
create policy episodes_admin_insert
on public.episodes for insert
to authenticated
with check (public.is_admin());

drop policy if exists episodes_admin_update on public.episodes;
create policy episodes_admin_update
on public.episodes for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists episodes_admin_delete on public.episodes;
create policy episodes_admin_delete
on public.episodes for delete
to authenticated
using (public.is_admin());

drop policy if exists contacts_admin_read on public.contact_messages;
create policy contacts_admin_read
on public.contact_messages for select
to authenticated
using (public.is_admin());

create or replace function public.get_admin_stats()
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  result json;
begin
  if not public.is_admin() then
    raise exception 'admin access required';
  end if;

  select json_build_object(
    'users', (select count(*) from public.profiles),
    'episodes', (select count(*) from public.episodes),
    'published', (select count(*) from public.episodes where is_published),
    'drafts', (select count(*) from public.episodes where not is_published),
    'premium', (select count(*) from public.episodes where is_premium),
    'featured', (select count(*) from public.episodes where is_featured)
  ) into result;

  return result;
end;
$$;

revoke execute on function public.get_admin_stats() from public;
grant execute on function public.get_admin_stats() to authenticated;

insert into storage.buckets (id,name,public)
values ('episode-thumbnails','episode-thumbnails',true)
on conflict (id) do update set public = true;

drop policy if exists admin_thumbnail_insert on storage.objects;
create policy admin_thumbnail_insert
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'episode-thumbnails'
  and public.is_admin()
);

drop policy if exists admin_thumbnail_update on storage.objects;
create policy admin_thumbnail_update
on storage.objects for update
to authenticated
using (
  bucket_id = 'episode-thumbnails'
  and public.is_admin()
)
with check (
  bucket_id = 'episode-thumbnails'
  and public.is_admin()
);

drop policy if exists admin_thumbnail_delete on storage.objects;
create policy admin_thumbnail_delete
on storage.objects for delete
to authenticated
using (
  bucket_id = 'episode-thumbnails'
  and public.is_admin()
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, name, email, avatar_url, last_seen_at, is_admin)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
    new.email,
    new.raw_user_meta_data->>'avatar_url',
    now(),
    false
  )
  on conflict (id) do update
  set email = excluded.email;
  return new;
end;
$$;


-- Lock administrator status to the database owner workflow.
revoke update on public.profiles from anon, authenticated;
grant update (name, avatar_url, last_seen_at) on public.profiles to authenticated;
