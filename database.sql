-- Run this in Supabase SQL Editor for your project.
create extension if not exists pgcrypto;
create table if not exists public.members (
 id uuid primary key default gen_random_uuid(),
 member_id text unique,
 name text not null,
 zone text not null,
 gkk text not null,
 position text not null,
 created_at timestamptz not null default now()
);
create sequence if not exists public.church_member_number_seq;
create or replace function public.assign_member_id() returns trigger language plpgsql as $$
begin
 if new.member_id is null then new.member_id := 'CH-' || lpad(nextval('public.church_member_number_seq')::text,5,'0'); end if;
 return new;
end; $$;
drop trigger if exists members_assign_id on public.members;
create trigger members_assign_id before insert on public.members for each row execute function public.assign_member_id();
create table if not exists public.attendance (
 id uuid primary key default gen_random_uuid(),
 member_uuid uuid not null references public.members(id) on delete cascade,
 session_name text not null,
 session_date date not null,
 created_at timestamptz not null default now(),
 checked_out_at timestamptz,
 unique(member_uuid,session_name,session_date)
);
alter table public.members enable row level security;
alter table public.attendance enable row level security;
-- Admin access via authenticated account. Restrict admin account creation in Supabase dashboard.
drop policy if exists "admins read members" on public.members;
create policy "admins read members" on public.members for select to authenticated using (true);
drop policy if exists "admins insert members" on public.members;
create policy "admins insert members" on public.members for insert to authenticated with check (true);
drop policy if exists "admins update members" on public.members;
create policy "admins update members" on public.members for update to authenticated using (true) with check (true);
drop policy if exists "admins delete members" on public.members;
create policy "admins delete members" on public.members for delete to authenticated using (true);
drop policy if exists "admins attendance read" on public.attendance;
create policy "admins attendance read" on public.attendance for select to authenticated using (true);
drop policy if exists "admins attendance insert" on public.attendance;
create policy "admins attendance insert" on public.attendance for insert to authenticated with check (true);
drop policy if exists "admins attendance delete" on public.attendance;
create policy "admins attendance delete" on public.attendance for delete to authenticated using (true);
-- Public registration: controlled RPC only. No public table-read policy.
create or replace function public.register_church_member(p_name text,p_zone text,p_gkk text,p_position text)
returns json language plpgsql security definer set search_path=public as $$
declare m public.members;
begin
 if length(trim(coalesce(p_name,'')))<2 or length(trim(coalesce(p_zone,'')))<1 or length(trim(coalesce(p_gkk,'')))<1 or length(trim(coalesce(p_position,'')))<1 then raise exception 'Please complete all registration fields.'; end if;
 insert into public.members(name,zone,gkk,position) values(trim(p_name),trim(p_zone),trim(p_gkk),trim(p_position)) returning * into m;
 return json_build_object('member_id',m.member_id);
end; $$;
revoke all on function public.register_church_member(text,text,text,text) from public;
grant execute on function public.register_church_member(text,text,text,text) to anon,authenticated;
-- Attendance marking RPC available only to logged-in admins
create or replace function public.mark_attendance_by_member_id(p_member_id text,p_session_name text,p_session_date date)
returns json language plpgsql security invoker set search_path=public as $$
declare m public.members; a public.attendance;
begin
 if auth.uid() is null then raise exception 'Admin login required'; end if;
 select * into m from public.members where member_id=p_member_id;
 if not found then raise exception 'Member ID not found'; end if;
 insert into public.attendance(member_uuid,session_name,session_date) values(m.id,coalesce(nullif(trim(p_session_name),''),'Session'),p_session_date) on conflict(member_uuid,session_name,session_date) do nothing returning * into a;
 if a.id is null then return json_build_object('message',m.name || ' is already marked present.'); end if;
 return json_build_object('message',m.name || ' marked present.');
end; $$;
revoke all on function public.mark_attendance_by_member_id(text,text,date) from public;
grant execute on function public.mark_attendance_by_member_id(text,text,date) to authenticated;

-- Member QR image-upload self check-in (public RPC). QR encodes the member ID.
-- NOTE: Anyone possessing a member QR can self-check-in; use only if this is acceptable.
create or replace function public.member_self_checkin(p_member_id text,p_session_name text,p_session_date date)
returns json language plpgsql security definer set search_path=public as $$
declare m public.members; a public.attendance;
begin
 if length(trim(coalesce(p_member_id,'')))<1 then raise exception 'QR code is empty'; end if;
 select * into m from public.members where member_id=trim(p_member_id);
 if not found then raise exception 'Member ID not found'; end if;
 insert into public.attendance(member_uuid,session_name,session_date)
 values(m.id,coalesce(nullif(trim(p_session_name),''),'Member self check-in'),p_session_date)
 on conflict(member_uuid,session_name,session_date) do nothing returning * into a;
 if a.id is null then
  select * into a from public.attendance where member_uuid=m.id and session_name=coalesce(nullif(trim(p_session_name),''),'Member self check-in') and session_date=p_session_date;
  return json_build_object('message',m.name || ' is already checked in for this date.', 'checked_in_at',a.created_at);
 end if;
 return json_build_object('message',m.name || ' checked in successfully.', 'checked_in_at',a.created_at);
end; $$;
revoke all on function public.member_self_checkin(text,text,date) from public;
grant execute on function public.member_self_checkin(text,text,date) to anon,authenticated;

-- Add clock-out timestamp to existing attendance tables if needed
alter table public.attendance add column if not exists checked_out_at timestamptz;

-- Public QR self-service clock in/out (QR holds the member ID).
create or replace function public.member_self_checkin(p_member_id text,p_session_name text,p_session_date date,p_action text default 'clock_in')
returns json language plpgsql security definer set search_path=public as $$
declare m public.members; a public.attendance; sn text:=coalesce(nullif(trim(p_session_name),''),'Member self check-in');
begin
 if p_action not in ('clock_in','clock_out') then raise exception 'Invalid attendance action'; end if;
 select * into m from public.members where member_id=trim(p_member_id);
 if not found then raise exception 'Member ID not found'; end if;
 if p_action='clock_in' then
  insert into public.attendance(member_uuid,session_name,session_date) values(m.id,sn,p_session_date) on conflict(member_uuid,session_name,session_date) do nothing returning * into a;
  if a.id is null then select * into a from public.attendance where member_uuid=m.id and session_name=sn and session_date=p_session_date;
    if a.checked_out_at is not null then raise exception 'You have already clocked out for this session.'; end if;
    return json_build_object('message',m.name || ' is already clocked in.', 'checked_in_at',a.created_at);
  end if;
  return json_build_object('message',m.name || ' clocked in successfully.', 'checked_in_at',a.created_at);
 else
  select * into a from public.attendance where member_uuid=m.id and session_name=sn and session_date=p_session_date;
  if not found then raise exception 'No clock-in record found for today/session.'; end if;
  if a.checked_out_at is not null then return json_build_object('message',m.name || ' already clocked out.', 'checked_in_at',a.created_at,'checked_out_at',a.checked_out_at); end if;
  update public.attendance set checked_out_at=now() where id=a.id returning * into a;
  return json_build_object('message',m.name || ' clocked out successfully.', 'checked_out_at',a.checked_out_at);
 end if;
end; $$;
revoke all on function public.member_self_checkin(text,text,date,text) from public;
grant execute on function public.member_self_checkin(text,text,date,text) to anon,authenticated;
