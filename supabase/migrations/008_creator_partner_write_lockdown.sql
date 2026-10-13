-- Tighten creator-partner write privileges.
-- Admin UI mutations go through SECURITY DEFINER RPCs that verify profiles.is_admin.
revoke insert, update, delete on public.creator_referrals from authenticated;
revoke insert, update, delete on public.creator_payouts from authenticated;

create or replace function public.admin_review_creator_referral(
  p_id uuid,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and is_admin = true
  ) then
    raise exception 'admin access required';
  end if;

  if p_status not in ('qualified', 'rejected') then
    raise exception 'invalid referral status';
  end if;

  update public.creator_referrals
  set status = p_status,
      reviewed_at = now(),
      reviewed_by = auth.uid()
  where id = p_id;

  if not found then
    raise exception 'referral not found';
  end if;
end;
$$;

create or replace function public.admin_update_creator_payout(
  p_id uuid,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and is_admin = true
  ) then
    raise exception 'admin access required';
  end if;

  if p_status not in ('paid', 'rejected') then
    raise exception 'invalid payout status';
  end if;

  update public.creator_payouts
  set status = p_status,
      reviewed_at = now(),
      reviewed_by = auth.uid(),
      paid_at = case when p_status = 'paid' then now() else null end
  where id = p_id
    and status in ('pending', 'approved');

  if not found then
    raise exception 'payout not found or already processed';
  end if;
end;
$$;

revoke all on function public.admin_review_creator_referral(uuid, text) from public;
grant execute on function public.admin_review_creator_referral(uuid, text) to authenticated;
revoke all on function public.admin_update_creator_payout(uuid, text) from public;
grant execute on function public.admin_update_creator_payout(uuid, text) to authenticated;
