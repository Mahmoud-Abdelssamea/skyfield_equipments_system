-- SKY FIELD Equipment System — data integrity, 23 Oct 2026. Run after 2026-10-23-security.sql. Safe to run again.
-- Movements, recipients and devices are saved by database functions that do the whole change in one step and
-- check first that nothing changed meanwhile:
--  • sf_record_movement  — the database gives the record number (never repeated), checks each device is still with
--                          the person shown in the form, updates only the devices in the movement, stores each
--                          device's previous holder / status / location, and ignores a repeated send (client_id).
--  • sf_update_movement  — notes, dates and times can always change; recipient or location only on the latest
--                          movement of all its devices.
--  • sf_delete_movement  — only the latest movement of all its devices; devices go back to their previous state.
--  • sf_save_engineer / sf_delete_engineer — a rename updates devices and old movements too; a recipient who still
--                          holds devices cannot be deleted.
--  • sf_save_device      — saves one device and refuses if someone changed it since it was opened; the holder
--                          changes only through movements.
-- Direct writes to movements, devices and recipients are closed, so an old copy of the page cannot overwrite data.
-- Change checks compare times to the millisecond (what the browser keeps).
-- Movement dates are stored as YYYY-MM-DD (the 42 older rows written in Arabic digits are converted).

begin;

alter table public.sf_movements add column if not exists client_id uuid;
create unique index if not exists sf_movements_client_id_key on public.sf_movements (client_id) where client_id is not null;

create sequence if not exists public.sf_record_no_seq;
select setval('public.sf_record_no_seq', greatest(
  coalesce((select max(substring(record_no from '^REC-(\d+)$')::bigint) from public.sf_movements), 0),
  (select case when is_called then last_value else last_value - 1 end from public.sf_record_no_seq), 1));

-- Dates: "٢٠‏/١٠‏/٢٠٢٦" → "2026-10-20"
update public.sf_movements m set movement_date = to_char(to_date(x.clean, 'DD/MM/YYYY'), 'YYYY-MM-DD')
from (select record_no, regexp_replace(translate(movement_date, '٠١٢٣٤٥٦٧٨٩', '0123456789'), '[^0-9/]', '', 'g') clean
      from public.sf_movements where movement_date !~ '^\d{4}-\d{2}-\d{2}$') x
where m.record_no = x.record_no and x.clean ~ '^\d{1,2}/\d{1,2}/\d{4}$';

-- One-time location repair (was done by the page on every sync): a device with a person but shown in the
-- warehouse takes the location of its latest movement to that person.
update public.sf_devices d set location = l.location
from (select distinct on (dev->>'id') dev->>'id' code, m.engineer, m.location
      from public.sf_movements m, jsonb_array_elements(m.devices) dev
      order by dev->>'id', m.created_at desc, m.record_no desc) l
where d.device_code = l.code and d.status = 'غير متاح' and d.holder <> 'مدير المخزن (صالح)'
  and d.location = 'المستودع' and l.engineer = d.holder and coalesce(l.location, 'المستودع') <> 'المستودع';

-- Is this the latest movement of every device in it?
create or replace function public.sf_movement_is_latest(p_record_no text)
returns boolean language sql stable security definer set search_path = public as $$
  select not exists (
    select 1 from public.sf_movements m
    cross join lateral jsonb_array_elements(m.devices) dev
    join public.sf_movements other on other.record_no <> m.record_no
      and other.devices @> jsonb_build_array(jsonb_build_object('id', dev->>'id'))
      and (other.created_at, other.record_no) > (m.created_at, m.record_no)
    where m.record_no = p_record_no);
$$;

create or replace function public.sf_record_movement(p_client_id uuid, p_movement jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  warehouse constant text := 'مدير المخزن (صالح)';
  v_engineer text := btrim(coalesce(p_movement->>'engineer', ''));
  v_type text := coalesce(p_movement->>'movement_type', '');
  v_location text := nullif(btrim(coalesce(p_movement->>'location', '')), '');
  v_items jsonb := coalesce(p_movement->'devices', '[]'::jsonb);
  v_existing public.sf_movements%rowtype;
  v_row public.sf_movements%rowtype;
  v_dev public.sf_devices%rowtype;
  v_item jsonb;
  v_snap jsonb := '[]'::jsonb;
  v_prev text[] := '{}';
  v_returned boolean;
  v_all_same boolean := true;
begin
  if not public.sf_can_edit() then raise exception 'ACCESS_DENIED'; end if;
  if p_client_id is not null then
    select * into v_existing from public.sf_movements where client_id = p_client_id;
    if found then
      return jsonb_build_object('movement', to_jsonb(v_existing), 'repeat', true,
        'devices', (select coalesce(jsonb_agg(to_jsonb(d)), '[]') from public.sf_devices d
                    where d.device_code in (select x->>'id' from jsonb_array_elements(v_existing.devices) x)));
    end if;
  end if;
  if v_engineer = '' then raise exception 'RECIPIENT_REQUIRED'; end if;
  if v_type not in ('استلام', 'تسليم') then raise exception 'INVALID_MOVEMENT_TYPE'; end if;
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then raise exception 'DEVICES_REQUIRED'; end if;
  if (select count(distinct x->>'id') from jsonb_array_elements(v_items) x) <> jsonb_array_length(v_items) then raise exception 'DUPLICATE_DEVICE'; end if;
  if v_engineer <> warehouse and not exists (select 1 from public.sf_engineers where name = v_engineer) then raise exception 'UNKNOWN_RECIPIENT'; end if;
  v_returned := v_engineer = warehouse;

  -- Lock the devices (in a fixed order) and check each is still where the form saw it.
  perform 1 from public.sf_devices where device_code in (select x->>'id' from jsonb_array_elements(v_items) x) order by device_code for update;
  for v_item in select * from jsonb_array_elements(v_items) loop
    select * into v_dev from public.sf_devices where device_code = v_item->>'id';
    if not found then raise exception 'DEVICE_NOT_FOUND:%', v_item->>'id'; end if;
    if coalesce(v_dev.holder, warehouse) <> coalesce(nullif(v_item->>'expected_holder', ''), warehouse) then
      raise exception 'DEVICE_CHANGED:%', v_dev.device_code;
    end if;
    if coalesce(v_dev.holder, warehouse) <> v_engineer then v_all_same := false; end if;
    v_prev := array_append(v_prev, coalesce(v_dev.holder, warehouse));
    v_snap := v_snap || jsonb_build_array(jsonb_build_object('id', v_dev.device_code, 'name', v_dev.name, 'type', v_dev.type,
      'serial', coalesce(v_dev.serial, ''), 'specs', coalesce(v_dev.specs, ''), 'brand', coalesce(v_dev.brand, ''),
      'previousHolder', coalesce(v_dev.holder, warehouse), 'previousStatus', v_dev.status, 'previousLocation', v_dev.location));
  end loop;
  if v_all_same then raise exception 'ALREADY_WITH_RECIPIENT'; end if;

  insert into public.sf_movements (record_no, client_id, movement_date, engineer, delivered_by, empid, nationality, phone,
    location, movement_type, received_date, received_time, delivered_date, delivered_time, notes, devices)
  values ('REC-' || lpad(nextval('public.sf_record_no_seq')::text, 3, '0'), p_client_id,
    to_char(now() at time zone 'Asia/Riyadh', 'YYYY-MM-DD'), v_engineer,
    (select string_agg(distinct p, '، ') from unnest(v_prev) p),
    nullif(p_movement->>'empid', ''), nullif(p_movement->>'nationality', ''), nullif(p_movement->>'phone', ''),
    coalesce(v_location, 'المستودع'), v_type, nullif(p_movement->>'received_date', '')::date, nullif(p_movement->>'received_time', '')::time,
    nullif(p_movement->>'delivered_date', '')::date, nullif(p_movement->>'delivered_time', '')::time, nullif(p_movement->>'notes', ''), v_snap)
  returning * into v_row;

  update public.sf_devices d set
    holder = case when v_returned then warehouse else v_engineer end,
    status = case when v_returned then 'متاح' else 'غير متاح' end,
    location = case when v_returned then 'المستودع' else coalesce(v_location, d.location, 'خارج المستودع') end
  where d.device_code in (select x->>'id' from jsonb_array_elements(v_items) x);

  return jsonb_build_object('movement', to_jsonb(v_row), 'repeat', false,
    'devices', (select coalesce(jsonb_agg(to_jsonb(d)), '[]') from public.sf_devices d
                where d.device_code in (select x->>'id' from jsonb_array_elements(v_items) x)));
end;
$$;

create or replace function public.sf_update_movement(p_record_no text, p_changes jsonb, p_expected_updated_at timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  warehouse constant text := 'مدير المخزن (صالح)';
  v_row public.sf_movements%rowtype;
  v_engineer text;
  v_location text;
  v_returned boolean;
begin
  if not public.sf_can_edit() then raise exception 'ACCESS_DENIED'; end if;
  select * into v_row from public.sf_movements where record_no = p_record_no for update;
  if not found then raise exception 'MOVEMENT_NOT_FOUND'; end if;
  if p_expected_updated_at is not null and date_trunc('milliseconds', v_row.updated_at) <> date_trunc('milliseconds', p_expected_updated_at) then raise exception 'MOVEMENT_CHANGED'; end if;
  v_engineer := coalesce(nullif(btrim(p_changes->>'engineer'), ''), v_row.engineer);
  v_location := coalesce(nullif(btrim(p_changes->>'location'), ''), v_row.location);
  if v_engineer <> v_row.engineer or v_location is distinct from v_row.location then
    if not public.sf_movement_is_latest(p_record_no) then raise exception 'MOVEMENT_NOT_LATEST'; end if;
    if v_engineer <> warehouse and not exists (select 1 from public.sf_engineers where name = v_engineer) then raise exception 'UNKNOWN_RECIPIENT'; end if;
    perform 1 from public.sf_devices where device_code in (select x->>'id' from jsonb_array_elements(v_row.devices) x) order by device_code for update;
    if exists (select 1 from public.sf_devices d where d.device_code in (select x->>'id' from jsonb_array_elements(v_row.devices) x)
               and coalesce(d.holder, warehouse) <> v_row.engineer) then raise exception 'DEVICE_CHANGED'; end if;
    v_returned := v_engineer = warehouse;
    update public.sf_devices d set
      holder = case when v_returned then warehouse else v_engineer end,
      status = case when v_returned then 'متاح' else 'غير متاح' end,
      location = case when v_returned then 'المستودع' else coalesce(v_location, d.location, 'خارج المستودع') end
    where d.device_code in (select x->>'id' from jsonb_array_elements(v_row.devices) x);
  end if;
  update public.sf_movements set
    engineer = v_engineer, location = v_location,
    empid = case when p_changes ? 'empid' then nullif(p_changes->>'empid', '') else empid end,
    movement_type = case when p_changes->>'movement_type' in ('استلام', 'تسليم') then p_changes->>'movement_type' else movement_type end,
    received_date = case when p_changes ? 'received_date' then nullif(p_changes->>'received_date', '')::date else received_date end,
    received_time = case when p_changes ? 'received_time' then nullif(p_changes->>'received_time', '')::time else received_time end,
    delivered_date = case when p_changes ? 'delivered_date' then nullif(p_changes->>'delivered_date', '')::date else delivered_date end,
    delivered_time = case when p_changes ? 'delivered_time' then nullif(p_changes->>'delivered_time', '')::time else delivered_time end,
    notes = case when p_changes ? 'notes' then nullif(p_changes->>'notes', '') else notes end
  where record_no = p_record_no returning * into v_row;
  return jsonb_build_object('movement', to_jsonb(v_row),
    'devices', (select coalesce(jsonb_agg(to_jsonb(d)), '[]') from public.sf_devices d
                where d.device_code in (select x->>'id' from jsonb_array_elements(v_row.devices) x)));
end;
$$;

create or replace function public.sf_delete_movement(p_record_no text, p_expected_updated_at timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  warehouse constant text := 'مدير المخزن (صالح)';
  v_row public.sf_movements%rowtype;
  v_item jsonb;
  v_prev text;
begin
  if not public.sf_can_edit() then raise exception 'ACCESS_DENIED'; end if;
  select * into v_row from public.sf_movements where record_no = p_record_no for update;
  if not found then raise exception 'MOVEMENT_NOT_FOUND'; end if;
  if p_expected_updated_at is not null and date_trunc('milliseconds', v_row.updated_at) <> date_trunc('milliseconds', p_expected_updated_at) then raise exception 'MOVEMENT_CHANGED'; end if;
  if not public.sf_movement_is_latest(p_record_no) then raise exception 'MOVEMENT_NOT_LATEST'; end if;
  perform 1 from public.sf_devices where device_code in (select x->>'id' from jsonb_array_elements(v_row.devices) x) order by device_code for update;
  if exists (select 1 from public.sf_devices d where d.device_code in (select x->>'id' from jsonb_array_elements(v_row.devices) x)
             and coalesce(d.holder, warehouse) <> v_row.engineer) then raise exception 'DEVICE_CHANGED'; end if;
  for v_item in select * from jsonb_array_elements(v_row.devices) loop
    v_prev := coalesce(nullif(v_item->>'previousHolder', ''), warehouse);
    update public.sf_devices d set holder = v_prev,
      status = coalesce(nullif(v_item->>'previousStatus', ''), case when v_prev = warehouse then 'متاح' else 'غير متاح' end),
      location = coalesce(nullif(v_item->>'previousLocation', ''), case when v_prev = warehouse then 'المستودع' else d.location end)
    where d.device_code = v_item->>'id';
  end loop;
  delete from public.sf_movements where record_no = p_record_no;
  return jsonb_build_object('deleted', p_record_no,
    'devices', (select coalesce(jsonb_agg(to_jsonb(d)), '[]') from public.sf_devices d
                where d.device_code in (select x->>'id' from jsonb_array_elements(v_row.devices) x)));
end;
$$;

create or replace function public.sf_save_engineer(p_id bigint, p_engineer jsonb)
returns public.sf_engineers language plpgsql security definer set search_path = public as $$
declare
  warehouse constant text := 'مدير المخزن (صالح)';
  v_name text := btrim(coalesce(p_engineer->>'name', ''));
  v_old public.sf_engineers%rowtype;
  v_row public.sf_engineers%rowtype;
begin
  if not public.sf_can_edit() then raise exception 'ACCESS_DENIED'; end if;
  if v_name = '' then raise exception 'NAME_REQUIRED'; end if;
  if v_name = warehouse then raise exception 'NAME_RESERVED'; end if;
  if exists (select 1 from public.sf_engineers where name = v_name and (p_id is null or id <> p_id)) then raise exception 'NAME_EXISTS'; end if;
  if p_id is null then
    insert into public.sf_engineers (name, empid, nationality, iqama, phone)
    values (v_name, nullif(p_engineer->>'empid', ''), nullif(p_engineer->>'nationality', ''), nullif(p_engineer->>'iqama', ''), nullif(p_engineer->>'phone', ''))
    returning * into v_row;
    return v_row;
  end if;
  select * into v_old from public.sf_engineers where id = p_id for update;
  if not found then raise exception 'RECIPIENT_NOT_FOUND'; end if;
  update public.sf_engineers set name = v_name, empid = nullif(p_engineer->>'empid', ''), nationality = nullif(p_engineer->>'nationality', ''),
    iqama = nullif(p_engineer->>'iqama', ''), phone = nullif(p_engineer->>'phone', '') where id = p_id returning * into v_row;
  if v_old.name <> v_name then
    -- The name is the link: carry it to the devices this person holds and to the movement history.
    update public.sf_devices set holder = v_name where holder = v_old.name;
    update public.sf_movements set engineer = v_name where engineer = v_old.name;
    update public.sf_movements set delivered_by = array_to_string(array(
        select case when p = v_old.name then v_name else p end from unnest(string_to_array(delivered_by, '، ')) p), '، ')
      where delivered_by is not null and v_old.name = any(string_to_array(delivered_by, '، '));
    update public.sf_movements set devices = (select jsonb_agg(case when x->>'previousHolder' = v_old.name
        then jsonb_set(x, '{previousHolder}', to_jsonb(v_name)) else x end) from jsonb_array_elements(devices) x)
      where devices @> jsonb_build_array(jsonb_build_object('previousHolder', v_old.name));
  end if;
  return v_row;
end;
$$;

create or replace function public.sf_delete_engineer(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_name text; v_count int;
begin
  if not public.sf_can_edit() then raise exception 'ACCESS_DENIED'; end if;
  select name into v_name from public.sf_engineers where id = p_id for update;
  if not found then raise exception 'RECIPIENT_NOT_FOUND'; end if;
  select count(*) into v_count from public.sf_devices where holder = v_name;
  if v_count > 0 then raise exception 'RECIPIENT_HAS_DEVICES:%', v_count; end if;
  delete from public.sf_engineers where id = p_id;
end;
$$;

create or replace function public.sf_save_device(p_device jsonb, p_expected_updated_at timestamptz)
returns public.sf_devices language plpgsql security definer set search_path = public as $$
declare
  v_code text := btrim(coalesce(p_device->>'device_code', ''));
  v_row public.sf_devices%rowtype;
begin
  if not public.sf_can_edit() then raise exception 'ACCESS_DENIED'; end if;
  if v_code = '' or btrim(coalesce(p_device->>'name', '')) = '' then raise exception 'DEVICE_FIELDS_REQUIRED'; end if;
  if p_expected_updated_at is null then
    if exists (select 1 from public.sf_devices where device_code = v_code) then raise exception 'DEVICE_EXISTS'; end if;
    insert into public.sf_devices (device_code, name, type, brand, serial, specs, status, location, calibration_required,
      calibration_date, calibration_expiry, certificate_no, calibration_lab, certificate_path, certificate_url, notes)
    values (v_code, btrim(p_device->>'name'), coalesce(nullif(p_device->>'type', ''), 'أجهزة اختبارات'), nullif(p_device->>'brand', ''),
      nullif(btrim(coalesce(p_device->>'serial', '')), ''), nullif(p_device->>'specs', ''), coalesce(nullif(p_device->>'status', ''), 'متاح'),
      coalesce(nullif(p_device->>'location', ''), 'المستودع'), coalesce((p_device->>'calibration_required')::boolean, false),
      nullif(p_device->>'calibration_date', '')::date, nullif(p_device->>'calibration_expiry', '')::date, nullif(p_device->>'certificate_no', ''),
      nullif(p_device->>'calibration_lab', ''), nullif(p_device->>'certificate_path', ''), nullif(p_device->>'certificate_url', ''), nullif(p_device->>'notes', ''))
    returning * into v_row;
    return v_row;
  end if;
  update public.sf_devices set name = btrim(p_device->>'name'), type = coalesce(nullif(p_device->>'type', ''), type),
    brand = nullif(p_device->>'brand', ''), serial = nullif(btrim(coalesce(p_device->>'serial', '')), ''), specs = nullif(p_device->>'specs', ''),
    status = coalesce(nullif(p_device->>'status', ''), status), location = coalesce(nullif(p_device->>'location', ''), location),
    calibration_required = coalesce((p_device->>'calibration_required')::boolean, false),
    calibration_date = nullif(p_device->>'calibration_date', '')::date, calibration_expiry = nullif(p_device->>'calibration_expiry', '')::date,
    certificate_no = nullif(p_device->>'certificate_no', ''), calibration_lab = nullif(p_device->>'calibration_lab', ''),
    certificate_path = nullif(p_device->>'certificate_path', ''), certificate_url = nullif(p_device->>'certificate_url', ''),
    notes = nullif(p_device->>'notes', '')
  where device_code = v_code and date_trunc('milliseconds', updated_at) = date_trunc('milliseconds', p_expected_updated_at) returning * into v_row;
  if not found then
    if exists (select 1 from public.sf_devices where device_code = v_code) then raise exception 'DEVICE_CONFLICT'; end if;
    raise exception 'DEVICE_NOT_FOUND:%', v_code;
  end if;
  return v_row;
end;
$$;

create or replace function public.sf_delete_device(p_code text)
returns void language plpgsql security definer set search_path = public as $$
declare v_row public.sf_devices%rowtype;
begin
  if not public.sf_can_edit() then raise exception 'ACCESS_DENIED'; end if;
  select * into v_row from public.sf_devices where device_code = p_code for update;
  if not found then return; end if;
  if v_row.status = 'غير متاح' or v_row.holder <> 'مدير المخزن (صالح)' then raise exception 'DEVICE_WITH_PERSON'; end if;
  delete from public.sf_devices where device_code = p_code;
end;
$$;

-- Writes only through the functions above (locations keep their simple insert / delete).
drop policy if exists sf_movements_insert on public.sf_movements;
drop policy if exists sf_movements_update on public.sf_movements;
drop policy if exists sf_movements_delete on public.sf_movements;
drop policy if exists sf_devices_insert on public.sf_devices;
drop policy if exists sf_devices_update on public.sf_devices;
drop policy if exists sf_devices_delete on public.sf_devices;
drop policy if exists sf_engineers_insert on public.sf_engineers;
drop policy if exists sf_engineers_update on public.sf_engineers;
drop policy if exists sf_engineers_delete on public.sf_engineers;

revoke execute on function public.sf_movement_is_latest(text), public.sf_record_movement(uuid, jsonb),
  public.sf_update_movement(text, jsonb, timestamptz), public.sf_delete_movement(text, timestamptz),
  public.sf_save_engineer(bigint, jsonb), public.sf_delete_engineer(bigint), public.sf_save_device(jsonb, timestamptz),
  public.sf_delete_device(text) from public, anon;
grant execute on function public.sf_movement_is_latest(text), public.sf_record_movement(uuid, jsonb),
  public.sf_update_movement(text, jsonb, timestamptz), public.sf_delete_movement(text, timestamptz),
  public.sf_save_engineer(bigint, jsonb), public.sf_delete_engineer(bigint), public.sf_save_device(jsonb, timestamptz),
  public.sf_delete_device(text) to authenticated;

commit;
