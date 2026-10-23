-- SKY FIELD Equipment System — security update, 23 Oct 2026.
-- Run once on the equipment project (kfaytvoihwzfwxmlkkwn). Safe to run again.
--  1. Removes sf_kv_store: unused by the system and open to anyone (read, write, delete without signing in).
--     It is dropped only when empty.
--  2. Data needs an ACTIVE account: devices, movements, recipients, locations and calibration certificates
--     are readable only by active admin / storekeeper / viewer accounts (before: any signed-in account).
--  3. New accounts start INACTIVE until an administrator activates them:
--       update public.sf_profiles set active = true where id = 'USER_UUID';
--  4. The old "equipment" table is kept with its data, but only active accounts can read it and only
--     admin / storekeeper can change it (before: any signed-in account could add, change or delete).
--  5. Function fixes from the Supabase security advisor.

begin;

-- 1. Unused open table
do $$
begin
  if to_regclass('public.sf_kv_store') is not null then
    if exists (select 1 from public.sf_kv_store) then
      raise exception 'sf_kv_store contains rows; it was not dropped. Check its contents first.';
    end if;
    drop table public.sf_kv_store;
  end if;
end $$;

-- 2. Active account check (used by the read policies)
create or replace function public.sf_is_member()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.sf_profiles
    where id = auth.uid() and active = true and role in ('admin','storekeeper','viewer')
  );
$$;

-- 3. New accounts start inactive
alter table public.sf_profiles alter column active set default false;
create or replace function public.sf_create_profile()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.sf_profiles (id, full_name, role, active)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', new.email), 'viewer', false)
  on conflict (id) do nothing;
  return new;
end;
$$;

-- 2 (continued). Reads need an active account
drop policy if exists sf_devices_read on public.sf_devices;
create policy sf_devices_read on public.sf_devices for select to authenticated using (public.sf_is_member());
drop policy if exists sf_movements_read on public.sf_movements;
create policy sf_movements_read on public.sf_movements for select to authenticated using (public.sf_is_member());
drop policy if exists sf_engineers_read on public.sf_engineers;
create policy sf_engineers_read on public.sf_engineers for select to authenticated using (public.sf_is_member());
drop policy if exists sf_locations_read on public.sf_locations;
create policy sf_locations_read on public.sf_locations for select to authenticated using (public.sf_is_member());
drop policy if exists sf_equipment_docs_read on storage.objects;
create policy sf_equipment_docs_read on storage.objects for select to authenticated
  using (bucket_id = 'equipment-documents' and public.sf_is_member());

-- 4. Old equipment table: kept, locked
drop policy if exists "Authenticated users can read equipment" on public.equipment;
drop policy if exists "Authenticated users can insert equipment" on public.equipment;
drop policy if exists "Authenticated users can update equipment" on public.equipment;
drop policy if exists "Authenticated users can delete equipment" on public.equipment;
drop policy if exists equipment_read on public.equipment;
drop policy if exists equipment_insert on public.equipment;
drop policy if exists equipment_update on public.equipment;
drop policy if exists equipment_delete on public.equipment;
create policy equipment_read on public.equipment for select to authenticated using (public.sf_is_member());
create policy equipment_insert on public.equipment for insert to authenticated with check (public.sf_can_edit());
create policy equipment_update on public.equipment for update to authenticated using (public.sf_can_edit()) with check (public.sf_can_edit());
create policy equipment_delete on public.equipment for delete to authenticated using (public.sf_can_edit());

-- 5. Functions: the profile trigger is not callable from the API; permission checks are not callable
--    by visitors who are not signed in; fixed search path.
revoke execute on function public.sf_create_profile() from public, anon, authenticated;
revoke execute on function public.sf_can_edit(), public.sf_is_admin(), public.sf_is_member() from public, anon;
grant execute on function public.sf_can_edit(), public.sf_is_admin(), public.sf_is_member() to authenticated;
alter function public.sf_set_updated_at() set search_path = public;

commit;
