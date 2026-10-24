-- Equipment system: English names (24 Oct 2026).
--
-- Recipients get an English name, and rentals keep the client's and the receiving person's English names, so the
-- English page and the English printed form do not show Arabic names. Empty English name: the Arabic one is shown.
-- Run after 2026-10-23-documents.sql.

begin;

alter table public.sf_engineers add column if not exists name_en text;
alter table public.sf_movements add column if not exists party_name_en text;
alter table public.sf_movements add column if not exists contact_name_en text;

-- Save recipient: as before, plus the English name.
create or replace function public.sf_save_engineer(p_id bigint, p_engineer jsonb)
returns public.sf_engineers language plpgsql security definer set search_path = public as $$
declare
  warehouse constant text := 'مدير المخزن (صالح)';
  v_name text := btrim(coalesce(p_engineer->>'name', ''));
  v_name_en text := nullif(btrim(coalesce(p_engineer->>'name_en', '')), '');
  v_job text := nullif(btrim(coalesce(p_engineer->>'job_title', '')), '');
  v_sec_expiry date := nullif(p_engineer->>'sec_id_expiry', '')::date;
  v_old public.sf_engineers%rowtype;
  v_row public.sf_engineers%rowtype;
begin
  if not public.sf_can_edit() then raise exception 'ACCESS_DENIED'; end if;
  if v_name = '' then raise exception 'NAME_REQUIRED'; end if;
  if v_job is not null and v_job not in ('مهندس', 'فني') then raise exception 'INVALID_JOB_TITLE'; end if;
  if exists (select 1 from public.sf_engineers where name = v_name and (p_id is null or id <> p_id)) then raise exception 'NAME_EXISTS'; end if;
  if p_id is null then
    if v_name = warehouse then raise exception 'NAME_RESERVED'; end if;
    insert into public.sf_engineers (name, name_en, empid, nationality, iqama, phone, job_title, iqama_expiry, sec_id_no, sec_id_expiry)
    values (v_name, v_name_en, nullif(p_engineer->>'empid', ''), nullif(p_engineer->>'nationality', ''), nullif(p_engineer->>'iqama', ''), nullif(p_engineer->>'phone', ''),
      v_job, nullif(p_engineer->>'iqama_expiry', '')::date, nullif(btrim(coalesce(p_engineer->>'sec_id_no', '')), ''), v_sec_expiry)
    returning * into v_row;
    return v_row;
  end if;
  select * into v_old from public.sf_engineers where id = p_id for update;
  if not found then raise exception 'RECIPIENT_NOT_FOUND'; end if;
  -- The warehouse manager's details can be edited, not his (reserved) name.
  if v_old.name = warehouse and v_name <> warehouse then raise exception 'NAME_RESERVED'; end if;
  if v_old.name <> warehouse and v_name = warehouse then raise exception 'NAME_RESERVED'; end if;
  update public.sf_engineers set name = v_name, name_en = v_name_en, empid = nullif(p_engineer->>'empid', ''), nationality = nullif(p_engineer->>'nationality', ''),
    iqama = nullif(p_engineer->>'iqama', ''), phone = nullif(p_engineer->>'phone', ''), job_title = v_job,
    iqama_expiry = nullif(p_engineer->>'iqama_expiry', '')::date,
    sec_id_no = nullif(btrim(coalesce(p_engineer->>'sec_id_no', '')), ''), sec_id_expiry = v_sec_expiry,
    sec_id_returned_on = case when v_sec_expiry is distinct from v_old.sec_id_expiry then null else v_old.sec_id_returned_on end
  where id = p_id returning * into v_row;
  if v_old.name <> v_name then
    update public.sf_devices set holder = v_name where holder = v_old.name;
    update public.sf_movements set engineer = v_name where engineer = v_old.name;
    update public.sf_movements set escort = v_name where escort = v_old.name;
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

-- Rentals: keep the client's and the receiving person's English names (set after the movement is saved).
create or replace function public.sf_set_movement_english_names(p_record_no text, p_party_name_en text, p_contact_name_en text)
returns public.sf_movements language plpgsql security definer set search_path = public as $$
declare v_row public.sf_movements%rowtype;
begin
  if not public.sf_can_edit() then raise exception 'ACCESS_DENIED'; end if;
  update public.sf_movements set party_name_en = nullif(btrim(coalesce(p_party_name_en, '')), ''),
    contact_name_en = nullif(btrim(coalesce(p_contact_name_en, '')), '')
  where record_no = p_record_no and destination_type <> 'engineer' returning * into v_row;
  if not found then raise exception 'MOVEMENT_NOT_FOUND'; end if;
  return v_row;
end;
$$;

revoke execute on function public.sf_set_movement_english_names(text, text, text) from public, anon;
grant execute on function public.sf_set_movement_english_names(text, text, text) to authenticated;
revoke execute on function public.sf_save_engineer(bigint, jsonb) from public, anon;
grant execute on function public.sf_save_engineer(bigint, jsonb) to authenticated;

commit;
