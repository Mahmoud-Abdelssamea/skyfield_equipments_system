-- Equipment system: rental and maintenance movements (23 Oct 2026).
--
-- A movement now goes to one of three kinds of destination:
--   engineer     a person on the recipients list (as before), or back to the warehouse
--   rental       a client renting the device
--   maintenance  an outside repair shop or calibration lab
-- For rental and maintenance the movement keeps the client / provider name (in "engineer", which is the device
-- holder), a reference (contract, PO, job number), the expected return date and, optionally, the engineer going
-- with the device. The device status becomes "مؤجر" or "في الصيانة"; it comes back with a normal return to the
-- warehouse. Run after 2026-10-23-data-integrity.sql.

begin;

alter table public.sf_movements add column if not exists destination_type text not null default 'engineer';
alter table public.sf_movements add column if not exists reference_no text;
alter table public.sf_movements add column if not exists expected_return date;
alter table public.sf_movements add column if not exists escort text;
-- The person who receives the device: contact name and Iqama / ID number (required for rentals); phone uses "phone".
-- For engineer movements id_number keeps the recipient's Iqama from the recipients list at the time.
alter table public.sf_movements add column if not exists contact_name text;
alter table public.sf_movements add column if not exists id_number text;
alter table public.sf_movements drop constraint if exists sf_movements_destination_type_check;
alter table public.sf_movements add constraint sf_movements_destination_type_check
  check (destination_type in ('engineer', 'rental', 'maintenance'));

-- Status a device gets when it goes to this destination.
create or replace function public.sf_destination_status(p_kind text, p_returned boolean)
returns text language sql immutable set search_path = public as $$
  select case when p_returned then 'متاح' when p_kind = 'rental' then 'مؤجر' when p_kind = 'maintenance' then 'في الصيانة' else 'غير متاح' end;
$$;

create or replace function public.sf_record_movement(p_client_id uuid, p_movement jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  warehouse constant text := 'مدير المخزن (صالح)';
  v_kind text := coalesce(nullif(p_movement->>'destination_type', ''), 'engineer');
  v_engineer text := btrim(coalesce(p_movement->>'engineer', ''));
  v_type text := coalesce(p_movement->>'movement_type', '');
  v_location text := nullif(btrim(coalesce(p_movement->>'location', '')), '');
  v_escort text := nullif(btrim(coalesce(p_movement->>'escort', '')), '');
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
  if v_kind not in ('engineer', 'rental', 'maintenance') then raise exception 'INVALID_DESTINATION'; end if;
  if v_engineer = '' then raise exception '%', case when v_kind = 'engineer' then 'RECIPIENT_REQUIRED' else 'PARTY_REQUIRED' end; end if;
  if v_kind <> 'engineer' then
    -- Out to a client or a provider: always an assignment, never to the warehouse or under a recipient's name.
    v_type := 'استلام';
    if v_engineer = warehouse or exists (select 1 from public.sf_engineers where name = v_engineer) then raise exception 'PARTY_IS_RECIPIENT'; end if;
    if nullif(p_movement->>'expected_return', '') is null then raise exception 'EXPECTED_RETURN_REQUIRED'; end if;
    if v_kind = 'rental' and nullif(btrim(coalesce(p_movement->>'id_number', '')), '') is null then raise exception 'ID_NUMBER_REQUIRED'; end if;
    if v_escort is not null and not exists (select 1 from public.sf_engineers where name = v_escort) then raise exception 'UNKNOWN_RECIPIENT'; end if;
  end if;
  if v_type not in ('استلام', 'تسليم') then raise exception 'INVALID_MOVEMENT_TYPE'; end if;
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then raise exception 'DEVICES_REQUIRED'; end if;
  if (select count(distinct x->>'id') from jsonb_array_elements(v_items) x) <> jsonb_array_length(v_items) then raise exception 'DUPLICATE_DEVICE'; end if;
  if v_kind = 'engineer' and v_engineer <> warehouse and not exists (select 1 from public.sf_engineers where name = v_engineer) then raise exception 'UNKNOWN_RECIPIENT'; end if;
  v_returned := v_kind = 'engineer' and v_engineer = warehouse;

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
    location, movement_type, received_date, received_time, delivered_date, delivered_time, notes, devices,
    destination_type, reference_no, expected_return, escort, contact_name, id_number)
  values ('REC-' || lpad(nextval('public.sf_record_no_seq')::text, 3, '0'), p_client_id,
    to_char(now() at time zone 'Asia/Riyadh', 'YYYY-MM-DD'), v_engineer,
    (select string_agg(distinct p, '، ') from unnest(v_prev) p),
    nullif(p_movement->>'empid', ''), nullif(p_movement->>'nationality', ''), nullif(p_movement->>'phone', ''),
    coalesce(v_location, case when v_kind = 'engineer' then 'المستودع' else v_engineer end), v_type,
    nullif(p_movement->>'received_date', '')::date, nullif(p_movement->>'received_time', '')::time,
    nullif(p_movement->>'delivered_date', '')::date, nullif(p_movement->>'delivered_time', '')::time, nullif(p_movement->>'notes', ''), v_snap,
    v_kind, case when v_kind <> 'engineer' then nullif(btrim(coalesce(p_movement->>'reference_no', '')), '') end,
    case when v_kind <> 'engineer' then nullif(p_movement->>'expected_return', '')::date end,
    case when v_kind <> 'engineer' then v_escort end,
    case when v_kind <> 'engineer' then nullif(btrim(coalesce(p_movement->>'contact_name', '')), '') end,
    case when v_kind <> 'engineer' then nullif(btrim(coalesce(p_movement->>'id_number', '')), '')
         else (select nullif(iqama, '') from public.sf_engineers where name = v_engineer) end)
  returning * into v_row;

  update public.sf_devices d set
    holder = case when v_returned then warehouse else v_engineer end,
    status = public.sf_destination_status(v_kind, v_returned),
    location = case when v_returned then 'المستودع' else coalesce(v_location, case when v_kind = 'engineer' then d.location end, v_engineer, 'خارج المستودع') end
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
  v_kind text;
begin
  if not public.sf_can_edit() then raise exception 'ACCESS_DENIED'; end if;
  select * into v_row from public.sf_movements where record_no = p_record_no for update;
  if not found then raise exception 'MOVEMENT_NOT_FOUND'; end if;
  if p_expected_updated_at is not null and date_trunc('milliseconds', v_row.updated_at) <> date_trunc('milliseconds', p_expected_updated_at) then raise exception 'MOVEMENT_CHANGED'; end if;
  v_kind := v_row.destination_type;
  v_engineer := coalesce(nullif(btrim(p_changes->>'engineer'), ''), v_row.engineer);
  v_location := coalesce(nullif(btrim(p_changes->>'location'), ''), v_row.location);
  if v_kind <> 'engineer' and (v_engineer = warehouse or exists (select 1 from public.sf_engineers where name = v_engineer)) then raise exception 'PARTY_IS_RECIPIENT'; end if;
  if v_kind <> 'engineer' and p_changes ? 'expected_return' and nullif(p_changes->>'expected_return', '') is null then raise exception 'EXPECTED_RETURN_REQUIRED'; end if;
  if v_kind = 'rental' and p_changes ? 'id_number' and nullif(btrim(p_changes->>'id_number'), '') is null then raise exception 'ID_NUMBER_REQUIRED'; end if;
  if v_kind <> 'engineer' and nullif(btrim(coalesce(p_changes->>'escort', '')), '') is not null
     and not exists (select 1 from public.sf_engineers where name = btrim(p_changes->>'escort')) then raise exception 'UNKNOWN_RECIPIENT'; end if;
  if v_engineer <> v_row.engineer or v_location is distinct from v_row.location then
    if not public.sf_movement_is_latest(p_record_no) then raise exception 'MOVEMENT_NOT_LATEST'; end if;
    if v_kind = 'engineer' and v_engineer <> warehouse and not exists (select 1 from public.sf_engineers where name = v_engineer) then raise exception 'UNKNOWN_RECIPIENT'; end if;
    perform 1 from public.sf_devices where device_code in (select x->>'id' from jsonb_array_elements(v_row.devices) x) order by device_code for update;
    if exists (select 1 from public.sf_devices d where d.device_code in (select x->>'id' from jsonb_array_elements(v_row.devices) x)
               and coalesce(d.holder, warehouse) <> v_row.engineer) then raise exception 'DEVICE_CHANGED'; end if;
    v_returned := v_kind = 'engineer' and v_engineer = warehouse;
    update public.sf_devices d set
      holder = case when v_returned then warehouse else v_engineer end,
      status = public.sf_destination_status(v_kind, v_returned),
      location = case when v_returned then 'المستودع' else coalesce(v_location, d.location, 'خارج المستودع') end
    where d.device_code in (select x->>'id' from jsonb_array_elements(v_row.devices) x);
  end if;
  update public.sf_movements set
    engineer = v_engineer, location = v_location,
    empid = case when p_changes ? 'empid' then nullif(p_changes->>'empid', '') else empid end,
    movement_type = case when v_kind = 'engineer' and p_changes->>'movement_type' in ('استلام', 'تسليم') then p_changes->>'movement_type' else movement_type end,
    received_date = case when p_changes ? 'received_date' then nullif(p_changes->>'received_date', '')::date else received_date end,
    received_time = case when p_changes ? 'received_time' then nullif(p_changes->>'received_time', '')::time else received_time end,
    delivered_date = case when p_changes ? 'delivered_date' then nullif(p_changes->>'delivered_date', '')::date else delivered_date end,
    delivered_time = case when p_changes ? 'delivered_time' then nullif(p_changes->>'delivered_time', '')::time else delivered_time end,
    notes = case when p_changes ? 'notes' then nullif(p_changes->>'notes', '') else notes end,
    reference_no = case when v_kind <> 'engineer' and p_changes ? 'reference_no' then nullif(btrim(p_changes->>'reference_no'), '') else reference_no end,
    expected_return = case when v_kind <> 'engineer' and p_changes ? 'expected_return' then nullif(p_changes->>'expected_return', '')::date else expected_return end,
    escort = case when v_kind <> 'engineer' and p_changes ? 'escort' then nullif(btrim(p_changes->>'escort'), '') else escort end,
    contact_name = case when v_kind <> 'engineer' and p_changes ? 'contact_name' then nullif(btrim(p_changes->>'contact_name'), '') else contact_name end,
    id_number = case when v_kind <> 'engineer' and p_changes ? 'id_number' then nullif(btrim(p_changes->>'id_number'), '') else id_number end,
    phone = case when v_kind <> 'engineer' and p_changes ? 'phone' then nullif(btrim(p_changes->>'phone'), '') else phone end
  where record_no = p_record_no returning * into v_row;
  return jsonb_build_object('movement', to_jsonb(v_row),
    'devices', (select coalesce(jsonb_agg(to_jsonb(d)), '[]') from public.sf_devices d
                where d.device_code in (select x->>'id' from jsonb_array_elements(v_row.devices) x)));
end;
$$;

-- A device a client or provider has cannot be deleted either.
create or replace function public.sf_delete_device(p_code text)
returns void language plpgsql security definer set search_path = public as $$
declare v_row public.sf_devices%rowtype;
begin
  if not public.sf_can_edit() then raise exception 'ACCESS_DENIED'; end if;
  select * into v_row from public.sf_devices where device_code = p_code for update;
  if not found then return; end if;
  if v_row.status in ('غير متاح', 'مؤجر', 'في الصيانة') or v_row.holder <> 'مدير المخزن (صالح)' then raise exception 'DEVICE_WITH_PERSON'; end if;
  delete from public.sf_devices where device_code = p_code;
end;
$$;

revoke execute on function public.sf_destination_status(text, boolean) from public, anon;
grant execute on function public.sf_destination_status(text, boolean) to authenticated;

commit;
