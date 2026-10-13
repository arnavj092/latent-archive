-- Commission configuration is now paise per 1,000 qualified signups.
-- Preserve each existing creator's effective per-signup rate by scaling its stored rate.
update public.creator_partners
set commission_paise_per_signup = commission_paise_per_signup * 1000;
alter table public.creator_referrals
  alter column commission_paise type numeric(14,3)
  using commission_paise::numeric(14,3);

create or replace function public.claim_creator_referral(p_slug text, p_visitor_key uuid)
returns void language plpgsql security definer set search_path=public as $$
declare
  v_user_id uuid := auth.uid();
  v_creator public.creator_partners%rowtype;
  v_created_at timestamptz;
begin
  if v_user_id is null or p_slug is null or p_visitor_key is null then return; end if;
  select created_at into v_created_at from auth.users where id=v_user_id and email_confirmed_at is not null;
  if v_created_at is null or v_created_at < now()-interval '30 days' then return; end if;
  select * into v_creator from public.creator_partners
    where lower(slug)=lower(left(p_slug,40)) and is_active=true;
  if v_creator.id is null or v_creator.auth_user_id=v_user_id then return; end if;
  if not exists (
    select 1 from public.creator_referral_visits v
    where v.creator_id=v_creator.id and v.visitor_key=p_visitor_key
      and v.created_at<=v_created_at and v.created_at>=v_created_at-interval '7 days'
  ) then return; end if;
  insert into public.creator_referrals(creator_id,referred_user_id,status,commission_paise)
  values(v_creator.id,v_user_id,'pending',v_creator.commission_paise_per_signup::numeric/1000)
  on conflict(referred_user_id) do nothing;
end; $$;
revoke all on function public.claim_creator_referral(text,uuid) from public;
grant execute on function public.claim_creator_referral(text,uuid) to authenticated;

-- Remove campaign date/budget/signup-cap checks from referral review. Admin-only
-- review and the existing RLS/execute permissions remain in force.
create or replace function public.admin_review_creator_referral(p_id uuid,p_status text)
returns void language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and is_admin=true) then
   raise exception 'admin access required';
 end if;
 if p_status not in ('qualified','rejected') then raise exception 'invalid referral status'; end if;
 update public.creator_referrals
 set status=p_status,reviewed_at=now(),reviewed_by=auth.uid()
 where id=p_id;
 if not found then raise exception 'referral not found'; end if;
end; $$;
revoke all on function public.admin_review_creator_referral(uuid,text) from public;
grant execute on function public.admin_review_creator_referral(uuid,text) to authenticated;
