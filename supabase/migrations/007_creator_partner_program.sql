-- Creator Partner Program: attribution, isolated creator access, and admin-controlled payouts.
create extension if not exists pgcrypto;

create table if not exists public.creator_partners (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique references auth.users(id) on delete set null,
  email text not null,
  display_name text not null,
  instagram_handle text not null default '',
  slug text not null unique,
  commission_paise_per_signup integer not null default 10 check (commission_paise_per_signup >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint creator_slug_format check (slug ~ '^[a-zA-Z0-9_-]{3,40}$')
);

create table if not exists public.creator_referral_visits (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.creator_partners(id) on delete cascade,
  visitor_key uuid not null,
  landing_path text not null default '/',
  created_at timestamptz not null default now(),
  unique (creator_id, visitor_key)
);

create table if not exists public.creator_referrals (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.creator_partners(id) on delete cascade,
  referred_user_id uuid not null unique references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','qualified','rejected')),
  commission_paise integer not null default 10 check (commission_paise >= 0),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null
);

create table if not exists public.creator_payouts (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.creator_partners(id) on delete cascade,
  amount_paise integer not null check (amount_paise > 0),
  status text not null default 'pending' check (status in ('pending','approved','paid','rejected')),
  payment_note text not null default '',
  requested_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  paid_at timestamptz
);

create index if not exists creator_referral_visits_creator_created_idx on public.creator_referral_visits(creator_id, created_at desc);
create index if not exists creator_referrals_creator_status_idx on public.creator_referrals(creator_id, status, created_at desc);
create index if not exists creator_payouts_creator_status_idx on public.creator_payouts(creator_id, status, requested_at desc);

alter table public.creator_partners enable row level security;
alter table public.creator_referral_visits enable row level security;
alter table public.creator_referrals enable row level security;
alter table public.creator_payouts enable row level security;

-- Remove broad client writes. Admin actions are restricted by the is_admin profile check.
revoke all on public.creator_partners from anon, authenticated;
revoke all on public.creator_referral_visits from anon, authenticated;
revoke all on public.creator_referrals from anon, authenticated;
revoke all on public.creator_payouts from anon, authenticated;
grant select on public.creator_partners to authenticated;
grant update (display_name, instagram_handle) on public.creator_partners to authenticated;
grant select on public.creator_referral_visits, public.creator_referrals, public.creator_payouts to authenticated;
grant insert, update, delete on public.creator_partners, public.creator_referrals, public.creator_payouts to authenticated;
grant insert on public.creator_referral_visits to authenticated;

drop policy if exists creator_partners_select_self_or_admin on public.creator_partners;
create policy creator_partners_select_self_or_admin on public.creator_partners for select to authenticated
using (auth_user_id = auth.uid() or exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true));

drop policy if exists creator_partners_update_self_profile on public.creator_partners;
create policy creator_partners_update_self_profile on public.creator_partners for update to authenticated
using (auth_user_id = auth.uid() and is_active = true)
with check (auth_user_id = auth.uid() and is_active = true);

drop policy if exists creator_partners_admin_all on public.creator_partners;
create policy creator_partners_admin_all on public.creator_partners for all to authenticated
using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true))
with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true));

drop policy if exists creator_visits_select_owner_or_admin on public.creator_referral_visits;
create policy creator_visits_select_owner_or_admin on public.creator_referral_visits for select to authenticated
using (exists (select 1 from public.creator_partners cp where cp.id = creator_id and (cp.auth_user_id = auth.uid() or exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true))));

drop policy if exists creator_referrals_select_owner_or_admin on public.creator_referrals;
create policy creator_referrals_select_owner_or_admin on public.creator_referrals for select to authenticated
using (exists (select 1 from public.creator_partners cp where cp.id = creator_id and (cp.auth_user_id = auth.uid() or exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true))));

drop policy if exists creator_referrals_admin_manage on public.creator_referrals;
create policy creator_referrals_admin_manage on public.creator_referrals for all to authenticated
using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true))
with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true));

drop policy if exists creator_payouts_select_owner_or_admin on public.creator_payouts;
create policy creator_payouts_select_owner_or_admin on public.creator_payouts for select to authenticated
using (exists (select 1 from public.creator_partners cp where cp.id = creator_id and (cp.auth_user_id = auth.uid() or exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true))));

drop policy if exists creator_payouts_admin_manage on public.creator_payouts;
create policy creator_payouts_admin_manage on public.creator_payouts for all to authenticated
using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true))
with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true));

create or replace function public.track_creator_referral_visit(p_slug text, p_visitor_key uuid, p_landing_path text default '/')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_creator_id uuid;
begin
  if p_slug is null or p_visitor_key is null then return; end if;
  select id into v_creator_id from public.creator_partners
  where lower(slug) = lower(left(p_slug, 40)) and is_active = true;
  if v_creator_id is null then return; end if;
  insert into public.creator_referral_visits(creator_id, visitor_key, landing_path)
  values(v_creator_id, p_visitor_key, left(coalesce(p_landing_path, '/'), 300))
  on conflict (creator_id, visitor_key) do nothing;
end;
$$;

create or replace function public.claim_creator_referral(p_slug text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_creator public.creator_partners%rowtype;
  v_created_at timestamptz;
begin
  if v_user_id is null or p_slug is null then return; end if;
  select created_at into v_created_at from auth.users where id = v_user_id;
  -- Do not attribute established accounts: the referred account must be less than 30 days old.
  if v_created_at is null or v_created_at < now() - interval '30 days' then return; end if;
  select * into v_creator from public.creator_partners
  where lower(slug) = lower(left(p_slug, 40)) and is_active = true;
  if v_creator.id is null or v_creator.auth_user_id = v_user_id then return; end if;
  insert into public.creator_referrals(creator_id, referred_user_id, status, commission_paise)
  values(v_creator.id, v_user_id, 'pending', v_creator.commission_paise_per_signup)
  on conflict (referred_user_id) do nothing;
end;
$$;

revoke all on function public.track_creator_referral_visit(text,uuid,text) from public;
grant execute on function public.track_creator_referral_visit(text,uuid,text) to anon, authenticated;
revoke all on function public.claim_creator_referral(text) from public;
grant execute on function public.claim_creator_referral(text) to authenticated;
