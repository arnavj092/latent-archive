-- Apply once to an existing Supabase project.
alter table public.profiles add column if not exists last_seen_at timestamptz;

alter table public.episodes add column if not exists is_premium boolean not null default false;
alter table public.episodes add column if not exists accent_color text;

alter table public.profiles enable row level security;
alter table public.episodes enable row level security;

drop policy if exists own_profile_read on public.profiles;
create policy own_profile_read on public.profiles for select using (auth.uid() = id);

drop policy if exists own_profile_update on public.profiles;
create policy own_profile_update on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);

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
  on conflict (id) do update
  set email = excluded.email,
      last_seen_at = now();
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row
execute function public.handle_new_user();
