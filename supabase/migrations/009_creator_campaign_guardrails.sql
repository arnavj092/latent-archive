-- Add server-enforced creator campaign limits.
alter table public.creator_partners add column if not exists campaign_enabled boolean not null default false;
alter table public.creator_partners add column if not exists campaign_max_qualified_signups integer;
alter table public.creator_partners add column if not exists campaign_budget_paise bigint;
alter table public.creator_partners add column if not exists campaign_start_at timestamptz;
alter table public.creator_partners add column if not exists campaign_end_at timestamptz;
alter table public.creator_partners drop constraint if exists creator_campaign_max_signups_positive;
alter table public.creator_partners add constraint creator_campaign_max_signups_positive check (campaign_max_qualified_signups is null or campaign_max_qualified_signups > 0);
alter table public.creator_partners drop constraint if exists creator_campaign_budget_positive;
alter table public.creator_partners add constraint creator_campaign_budget_positive check (campaign_budget_paise is null or campaign_budget_paise > 0);
alter table public.creator_partners drop constraint if exists creator_campaign_window_valid;
alter table public.creator_partners add constraint creator_campaign_window_valid check (campaign_start_at is null or campaign_end_at is null or campaign_end_at > campaign_start_at);

create or replace function public.admin_set_creator_campaign(p_creator_id uuid,p_enabled boolean,p_max_qualified_signups integer,p_budget_paise bigint,p_start_at timestamptz,p_end_at timestamptz) returns void language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and is_admin=true) then raise exception 'admin access required'; end if;
 if p_enabled and (p_max_qualified_signups is null or p_max_qualified_signups<1) then raise exception 'Set a positive signup limit'; end if;
 if p_enabled and (p_budget_paise is null or p_budget_paise<1) then raise exception 'Set a positive campaign budget'; end if;
 if p_enabled and (p_start_at is null or p_end_at is null or p_end_at<=p_start_at) then raise exception 'Set valid campaign dates'; end if;
 update public.creator_partners set campaign_enabled=p_enabled,campaign_max_qualified_signups=p_max_qualified_signups,campaign_budget_paise=p_budget_paise,campaign_start_at=p_start_at,campaign_end_at=p_end_at,updated_at=now() where id=p_creator_id;
 if not found then raise exception 'creator not found'; end if;
end; $$;
revoke all on function public.admin_set_creator_campaign(uuid,boolean,integer,bigint,timestamptz,timestamptz) from public;
grant execute on function public.admin_set_creator_campaign(uuid,boolean,integer,bigint,timestamptz,timestamptz) to authenticated;

create or replace function public.admin_review_creator_referral(p_id uuid,p_status text) returns void language plpgsql security definer set search_path=public as $$
declare v_ref public.creator_referrals%rowtype; v_creator public.creator_partners%rowtype; v_count integer; v_total bigint;
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and is_admin=true) then raise exception 'admin access required'; end if;
 if p_status not in ('qualified','rejected') then raise exception 'invalid referral status'; end if;
 select * into v_ref from public.creator_referrals where id=p_id;
 if not found then raise exception 'referral not found'; end if;
 select * into v_creator from public.creator_partners where id=v_ref.creator_id for update;
 if not found then raise exception 'creator not found'; end if;
 if p_status='qualified' and v_ref.status<>'qualified' and v_creator.campaign_enabled then
  if v_creator.campaign_start_at is null or v_creator.campaign_end_at is null then raise exception 'campaign dates are not configured'; end if;
  if v_ref.created_at<v_creator.campaign_start_at or v_ref.created_at>=v_creator.campaign_end_at then raise exception 'signup falls outside campaign dates'; end if;
  select count(*)::integer,coalesce(sum(r.commission_paise),0)::bigint into v_count,v_total from public.creator_referrals r where r.creator_id=v_creator.id and r.status='qualified' and r.created_at>=v_creator.campaign_start_at and r.created_at<v_creator.campaign_end_at;
  if v_count>=v_creator.campaign_max_qualified_signups then raise exception 'campaign signup limit reached'; end if;
  if v_total+v_ref.commission_paise>v_creator.campaign_budget_paise then raise exception 'campaign budget would be exceeded'; end if;
 end if;
 update public.creator_referrals set status=p_status,reviewed_at=now(),reviewed_by=auth.uid() where id=p_id;
end; $$;
revoke all on function public.admin_review_creator_referral(uuid,text) from public;
grant execute on function public.admin_review_creator_referral(uuid,text) to authenticated;
