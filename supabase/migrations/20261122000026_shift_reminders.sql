-- =====================================================================
-- PadelBros App – Update 26: Erinnerungen vor Schichten (7 Tage, 24 h, 2 h)
-- und Hinweis an die Planung, wenn eine Schicht 10 Tage vorher noch offen ist.
-- Darf mehrfach ausgeführt werden.
-- =====================================================================
alter table public.shifts add column if not exists reminded_7_at  timestamptz;
alter table public.shifts add column if not exists reminded_24_at timestamptz;
alter table public.shifts add column if not exists reminded_2h_at timestamptz;
alter table public.shifts add column if not exists open_alert_at  timestamptz;

-- Bei neuer Person oder neuer Zeit: Zusage und alle Erinnerungen zurücksetzen
create or replace function public.shifts_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.player_id is not null and exists (
       select 1 from public.shifts x where x.player_id = new.player_id and x.id <> new.id
         and tstzrange(x.starts_at, x.ends_at) && tstzrange(new.starts_at, new.ends_at)) then
    raise exception '% hat in dieser Zeit schon eine Schicht.', (select name from public.players where id = new.player_id);
  end if;
  if tg_op = 'UPDATE' and new.player_id is distinct from old.player_id then
    new.agreed_at := null; new.approved_at := null; new.approved_by := null;
  end if;
  if tg_op = 'UPDATE' and (new.player_id is distinct from old.player_id or new.starts_at <> old.starts_at) then
    new.reminded_3_at := null; new.reminded_0_at := null;
    new.reminded_7_at := null; new.reminded_24_at := null; new.reminded_2h_at := null;
  end if;
  if tg_op = 'UPDATE' and new.player_id is null and old.player_id is not null then new.open_alert_at := null; end if;
  new.updated_at := now();
  return new;
end $$;

-- Erinnerungen dürfen auch an die Person gehen, die den Lauf gerade auslöst
create or replace function public.notify(p_recipient uuid, p_kind text, p_title text, p_body text,
                                         p_ref_type text, p_ref_id uuid, p_dedupe text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_recipient is null then return; end if;
  if p_recipient = public.me() and p_kind not in ('task_due_soon', 'task_overdue', 'push_test', 'shift_reminder', 'shift_upcoming', 'shift_open_alert') then return; end if;
  if not exists (select 1 from public.players where id = p_recipient and active) then return; end if;
  insert into public.notifications (recipient_id, kind, title, body, ref_type, ref_id, dedupe_key)
  values (p_recipient, p_kind, left(p_title, 200), left(p_body, 500), p_ref_type, p_ref_id, p_dedupe)
  on conflict do nothing;
end $$;
revoke execute on function public.notify(uuid, text, text, text, text, uuid, text) from public, anon, authenticated;

-- Erinnerungen vor der eigenen Schicht: 7 Tage, 24 Stunden, 2 Stunden (je einmal)
create or replace function public.remind_upcoming_shifts() returns int
language plpgsql security definer set search_path = public as $$
declare s public.shifts%rowtype; n int := 0; v_today date := (now() at time zone 'Europe/Berlin')::date;
begin
  for s in select * from public.shifts where player_id is not null and reminded_7_at is null
             and day between v_today + 6 and v_today + 7 and starts_at > now() + interval '5 days' loop
    perform public.notify(s.player_id, 'shift_upcoming', 'Schicht in 7 Tagen: ' || public.shift_label(s), 'Du bist eingeteilt.', 'shift', s.id, 'up7:' || s.id || ':' || s.player_id);
    update public.shifts set reminded_7_at = now() where id = s.id; n := n + 1;
  end loop;
  for s in select * from public.shifts where player_id is not null and reminded_24_at is null
             and starts_at <= now() + interval '24 hours' and starts_at > now() + interval '3 hours' loop
    perform public.notify(s.player_id, 'shift_upcoming', 'Schicht morgen: ' || public.shift_label(s), 'Erinnerung: deine Schicht in 24 Stunden.', 'shift', s.id, 'up24:' || s.id || ':' || s.player_id);
    update public.shifts set reminded_24_at = now() where id = s.id; n := n + 1;
  end loop;
  for s in select * from public.shifts where player_id is not null and reminded_2h_at is null
             and starts_at <= now() + interval '2 hours' and starts_at > now() + interval '20 minutes' loop
    perform public.notify(s.player_id, 'shift_upcoming', 'Schicht in 2 Stunden: ' || public.shift_label(s), 'Bis gleich in der Halle!', 'shift', s.id, 'up2:' || s.id || ':' || s.player_id);
    update public.shifts set reminded_2h_at = now() where id = s.id; n := n + 1;
  end loop;
  return n;
end $$;

-- An die Planung: Schichten in den nächsten 10 Tagen ohne Zuteilung (gesammelt, je Schicht einmal)
create or replace function public.alert_open_shifts() returns int
language plpgsql security definer set search_path = public as $$
declare v_today date := (now() at time zone 'Europe/Berlin')::date; ids uuid[]; labels text; c int; m record;
begin
  select array_agg(id order by starts_at), count(*),
         string_agg(public.shift_label(s), ' · ' order by starts_at) filter (where true)
    into ids, c, labels
  from public.shifts s where player_id is null and open_alert_at is null and starts_at > now() and day <= v_today + 10;
  if coalesce(c, 0) = 0 then return 0; end if;
  for m in select id from public.players where is_shift_planner and active loop
    perform public.notify(m.id, 'shift_open_alert',
      case when c = 1 then '1 Schicht in den nächsten 10 Tagen ist noch offen' else c || ' Schichten in den nächsten 10 Tagen sind noch offen' end,
      left(labels, 480), 'shift', ids[1], 'open:' || ids[1] || ':' || v_today);
  end loop;
  update public.shifts set open_alert_at = now() where id = any (ids);
  return c;
end $$;
revoke execute on function public.remind_upcoming_shifts(), public.alert_open_shifts() from public, anon;
grant  execute on function public.remind_upcoming_shifts(), public.alert_open_shifts() to authenticated;

-- Zeitpläne: Erinnerungen alle 15 Minuten, offene Schichten täglich um 8 UTC
do $$
begin
  begin create extension if not exists pg_cron;
  exception when others then raise notice 'Zeitplan (pg_cron) nicht verfügbar: %', sqlerrm; return; end;
  perform cron.schedule('schicht-erinnerungen', '*/15 * * * *', 'select public.remind_upcoming_shifts()');
  perform cron.schedule('schicht-offen-hinweis', '0 8 * * *', 'select public.alert_open_shifts()');
exception when others then raise notice 'Zeitplan konnte nicht angelegt werden: %', sqlerrm;
end $$;

select 'Schicht-Erinnerungen eingerichtet' || case when exists (select 1 from pg_extension where extname = 'pg_cron')
  then ' – laufen automatisch alle 15 Minuten' else ' – laufen beim Öffnen der App' end as ergebnis;
