-- Equipment system: Iqama and SEC-ID card tracking for recipients (23 Oct 2026).
--
-- Each engineer / technician keeps the Iqama expiry date and the SEC-ID safety card (number and expiry). The page
-- warns 60 / 30 / 7 days before either expires so the card is renewed or handed back to the electricity company in
-- time (to avoid the company's fine). "Handed in" keeps the date the card was returned, as proof, and stops the
-- alert; entering a new SEC-ID expiry starts tracking the new card. Run after 2026-10-23-rental-maintenance.sql.

begin;

alter table public.sf_engineers add column if not exists job_title text;
alter table public.sf_engineers add column if not exists iqama_expiry date;
alter table public.sf_engineers add column if not exists sec_id_no text;
alter table public.sf_engineers add column if not exists sec_id_expiry date;
alter table public.sf_engineers add column if not exists sec_id_returned_on date;
alter table public.sf_engineers drop constraint if exists sf_engineers_job_title_check;
alter table public.sf_engineers add constraint sf_engineers_job_title_check check (job_title is null or job_title in ('مهندس', 'فني'));

create or replace function public.sf_save_engineer(p_id bigint, p_engineer jsonb)
returns public.sf_engineers language plpgsql security definer set search_path = public as $$
declare
  warehouse constant text := 'مدير المخزن (صالح)';
  v_name text := btrim(coalesce(p_engineer->>'name', ''));
  v_job text := nullif(btrim(coalesce(p_engineer->>'job_title', '')), '');
  v_sec_expiry date := nullif(p_engineer->>'sec_id_expiry', '')::date;
  v_old public.sf_engineers%rowtype;
  v_row public.sf_engineers%rowtype;
begin
  if not public.sf_can_edit() then raise exception 'ACCESS_DENIED'; end if;
  if v_name = '' then raise exception 'NAME_REQUIRED'; end if;
  if v_name = warehouse then raise exception 'NAME_RESERVED'; end if;
  if v_job is not null and v_job not in ('مهندس', 'فني') then raise exception 'INVALID_JOB_TITLE'; end if;
  if exists (select 1 from public.sf_engineers where name = v_name and (p_id is null or id <> p_id)) then raise exception 'NAME_EXISTS'; end if;
  if p_id is null then
    insert into public.sf_engineers (name, empid, nationality, iqama, phone, job_title, iqama_expiry, sec_id_no, sec_id_expiry)
    values (v_name, nullif(p_engineer->>'empid', ''), nullif(p_engineer->>'nationality', ''), nullif(p_engineer->>'iqama', ''), nullif(p_engineer->>'phone', ''),
      v_job, nullif(p_engineer->>'iqama_expiry', '')::date, nullif(btrim(coalesce(p_engineer->>'sec_id_no', '')), ''), v_sec_expiry)
    returning * into v_row;
    return v_row;
  end if;
  select * into v_old from public.sf_engineers where id = p_id for update;
  if not found then raise exception 'RECIPIENT_NOT_FOUND'; end if;
  update public.sf_engineers set name = v_name, empid = nullif(p_engineer->>'empid', ''), nationality = nullif(p_engineer->>'nationality', ''),
    iqama = nullif(p_engineer->>'iqama', ''), phone = nullif(p_engineer->>'phone', ''), job_title = v_job,
    iqama_expiry = nullif(p_engineer->>'iqama_expiry', '')::date,
    sec_id_no = nullif(btrim(coalesce(p_engineer->>'sec_id_no', '')), ''), sec_id_expiry = v_sec_expiry,
    -- A different expiry means a new card: the old "handed in" date no longer applies.
    sec_id_returned_on = case when v_sec_expiry is distinct from v_old.sec_id_expiry then null else v_old.sec_id_returned_on end
  where id = p_id returning * into v_row;
  if v_old.name <> v_name then
    -- The name is the link: carry it to the devices this person holds and to the movement history.
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

-- Buttons on the recipients page: "renewed" (new expiry date) for the Iqama or the SEC-ID card, and
-- "handed in" for the SEC-ID card (the date it was returned to the electricity company).
create or replace function public.sf_engineer_document(p_id bigint, p_document text, p_action text, p_date date)
returns public.sf_engineers language plpgsql security definer set search_path = public as $$
declare v_row public.sf_engineers%rowtype;
begin
  if not public.sf_can_edit() then raise exception 'ACCESS_DENIED'; end if;
  select * into v_row from public.sf_engineers where id = p_id for update;
  if not found then raise exception 'RECIPIENT_NOT_FOUND'; end if;
  if p_date is null then raise exception 'DATE_REQUIRED'; end if;
  if p_document = 'iqama' and p_action = 'renew' then
    if v_row.iqama_expiry is not null and p_date <= v_row.iqama_expiry then raise exception 'NEW_DATE_NOT_LATER'; end if;
    update public.sf_engineers set iqama_expiry = p_date where id = p_id returning * into v_row;
  elsif p_document = 'sec_id' and p_action = 'renew' then
    if v_row.sec_id_expiry is not null and p_date <= v_row.sec_id_expiry then raise exception 'NEW_DATE_NOT_LATER'; end if;
    update public.sf_engineers set sec_id_expiry = p_date, sec_id_returned_on = null where id = p_id returning * into v_row;
  elsif p_document = 'sec_id' and p_action = 'returned' then
    if v_row.sec_id_expiry is null and v_row.sec_id_no is null then raise exception 'NO_SEC_ID'; end if;
    if p_date > (now() at time zone 'Asia/Riyadh')::date then raise exception 'DATE_IN_FUTURE'; end if;
    update public.sf_engineers set sec_id_returned_on = p_date where id = p_id returning * into v_row;
  else
    raise exception 'INVALID_DOCUMENT_ACTION';
  end if;
  return v_row;
end;
$$;

revoke execute on function public.sf_engineer_document(bigint, text, text, date) from public, anon;
grant execute on function public.sf_engineer_document(bigint, text, text, date) to authenticated;
revoke execute on function public.sf_save_engineer(bigint, jsonb) from public, anon;
grant execute on function public.sf_save_engineer(bigint, jsonb) to authenticated;

commit;
