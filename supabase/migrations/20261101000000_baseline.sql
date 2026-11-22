


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."absences_watch"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin perform public.notify_watchers(new.session_id); return null; end $$;


ALTER FUNCTION "public"."absences_watch"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."actor_name"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce((select name from public.players where id = public.me()), 'System')
$$;


ALTER FUNCTION "public"."actor_name"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."add_session_guest"("p_session" "uuid", "p_player" "uuid" DEFAULT NULL::"uuid", "p_name" "text" DEFAULT NULL::"text") RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_s record; v_rep uuid; v_asg uuid; v_created boolean := false;
        v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
begin
  if not public.is_coach_or_admin() then raise exception 'Nur Trainer und Admins können Gäste hinzufügen.'; end if;
  select * into v_s from public.sessions where id = p_session;
  if v_s.id is null then raise exception 'Training nicht gefunden.'; end if;
  if v_s.cancelled then raise exception 'Dieses Training ist abgesagt.'; end if;
  if p_player is not null then
    if not exists (select 1 from public.players where id = p_player and active) then raise exception 'Person nicht gefunden.'; end if;
    v_rep := p_player;
  else
    if length(v_name) < 2 or length(v_name) > 60 then raise exception 'Bitte den vollständigen Namen des Gastes angeben.'; end if;
    select id into v_rep from public.players where is_guest and lower(name) = lower(v_name) limit 1;
    if v_rep is null then
      insert into public.players (name, is_guest) values (v_name, true) returning id into v_rep; v_created := true;
    end if;
  end if;
  if exists (select 1 from public.players where id = v_rep and team_id = v_s.team_id) then
    raise exception 'Diese Person spielt selbst in diesem Team.';
  end if;
  if exists (select 1 from public.assignments where session_id = p_session and player_id = v_rep) then
    raise exception 'Diese Person ist für dieses Training schon eingeteilt.';
  end if;
  perform set_config('pb.skip_watch', '1', true);
  insert into public.assignments (session_id, player_id, absence_id, assigned_by)
  values (p_session, v_rep, null, public.me()) returning id into v_asg;
  perform set_config('pb.skip_watch', '0', true);
  return json_build_object('assignment_id', v_asg, 'player_id', v_rep, 'guest_created', v_created);
end $$;


ALTER FUNCTION "public"."add_session_guest"("p_session" "uuid", "p_player" "uuid", "p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_login_status"() RETURNS TABLE("id" "uuid", "name" "text", "email" "text", "team_id" "text", "in_pool" boolean, "is_staff" boolean, "last_sign_in_at" timestamp with time zone, "last_seen_at" timestamp with time zone, "installed_at" timestamp with time zone, "push" boolean, "platform" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
  select p.id, p.name, p.email, p.team_id,
         exists (select 1 from public.player_pools pp where pp.player_id = p.id),
         p.is_staff or p.is_manager,
         (select max(u.last_sign_in_at) from auth.users u where lower(u.email) = p.email),
         pr.last_seen_at, pr.installed_at,
         exists (select 1 from public.push_subscriptions s where s.player_id = p.id),
         pr.last_platform
  from public.players p
  left join public.player_presence pr on pr.player_id = p.id
  where public.is_admin() and p.active and not p.is_guest
  order by p.team_id nulls last, p.name
$$;


ALTER FUNCTION "public"."admin_login_status"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_players"() RETURNS TABLE("id" "uuid", "name" "text", "email" "text", "team_id" "text", "is_admin" boolean, "active" boolean, "is_staff" boolean, "is_manager" boolean, "is_coach" boolean, "is_super_admin" boolean)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select p.id, p.name, p.email, p.team_id, p.is_admin, p.active, p.is_staff, p.is_manager, p.is_coach, p.is_super_admin
  from public.players p where public.is_admin()
  order by p.team_id nulls last, p.name
$$;


ALTER FUNCTION "public"."admin_players"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."agree_shift"("p_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  update public.shifts set agreed_at = coalesce(agreed_at, now()) where id = p_id and player_id = public.me();
  if not found then raise exception 'Das ist nicht deine Schicht.'; end if;
end $$;


ALTER FUNCTION "public"."agree_shift"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."applications_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare a record;
begin
  for a in select ab.player_id from public.absences ab
           where ab.session_id = new.session_id
             and not exists (select 1 from public.assignments x where x.absence_id = ab.id) loop
    perform public.notify(a.player_id, 'replacement_application', 'Neue Bewerbung: ' || public.session_label(new.session_id),
      public.actor_name() || ' möchte für dich einspringen. Du kannst bestätigen.', 'session', new.session_id, 'app:' || new.id);
  end loop;
  return null;
end $$;


ALTER FUNCTION "public"."applications_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assignments_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare absent uuid;
begin
  if tg_op = 'INSERT' then
    select player_id into absent from public.absences where id = new.absence_id;
    perform public.notify(new.player_id, 'replacement_confirmed', 'Bestätigt: ' || public.session_label(new.session_id),
      case when absent is not null then 'Du springst für ' || (select name from public.players where id = absent)
        || ' ein. Bitte zahl die 25 € direkt an ' || (select split_part(name, ' ', 1) from public.players where id = absent) || '.'
      else 'Du bist für dieses Training eingeteilt.' end, 'session', new.session_id, 'asg:' || new.id);
    return null;
  end if;
  select player_id into absent from public.absences where id = old.absence_id;
  if old.player_id = public.me() then
    perform public.notify(absent, 'replacement_cancelled', 'Ersatz abgesagt: ' || public.session_label(old.session_id),
      public.actor_name() || ' hat abgesagt. Der Platz ist wieder frei – du kannst jemand Neues bestätigen.', 'session', old.session_id, null);
  else
    perform public.notify(old.player_id, 'replacement_removed', 'Zuordnung aufgehoben: ' || public.session_label(old.session_id),
      'Ein Admin hat deine Zuordnung für dieses Training aufgehoben.', 'session', old.session_id, null);
  end if;
  return null;
end $$;


ALTER FUNCTION "public"."assignments_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assignments_payment_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v record; v_body text;
begin
  if new.absence_id is null then return null; end if;
  select p.name, pp.paypal, pp.whatsapp, pp.note into v
  from public.absences a join public.players p on p.id = a.player_id
  left join public.player_payment pp on pp.player_id = a.player_id
  where a.id = new.absence_id;
  if v.name is null or (v.paypal is null and v.whatsapp is null and v.note is null) then return null; end if;
  v_body := concat_ws(' · ', 'PayPal: ' || v.paypal, 'WhatsApp: ' || v.whatsapp, v.note);
  perform public.notify(new.player_id, 'payment_info', 'So bezahlst du ' || v.name || ' (25 €)',
    v_body, 'session', new.session_id, 'pay:' || new.id);
  return null;
end $$;


ALTER FUNCTION "public"."assignments_payment_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assignments_watch"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin perform public.notify_watchers(old.session_id); return null; end $$;


ALTER FUNCTION "public"."assignments_watch"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."board_visible"("bid" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select bid is null or exists (select 1 from public.boards b where b.id = bid and (not b.confidential or public.is_super_admin()))
$$;


ALTER FUNCTION "public"."board_visible"("bid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_apply"("sid" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from public.sessions s
    where s.id = sid
      and not s.cancelled
      and s.starts_at > now()
      and s.team_id is distinct from public.my_team()
      and exists (select 1 from public.team_pools tp
                    join public.player_pools pp on pp.pool_id = tp.pool_id
                   where tp.team_id = s.team_id and pp.player_id = public.me())
      and public.session_open(s.id) > 0
  )
$$;


ALTER FUNCTION "public"."can_apply"("sid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_see_event"("eid" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.is_manager() or (public.is_staff() and (
       exists (select 1 from public.events e where e.id = eid and e.manager_id = public.me())
    or exists (select 1 from public.event_staff s where s.event_id = eid and s.player_id = public.me())
    or exists (select 1 from public.tasks t where t.event_id = eid and (t.owner_id = public.me()
               or exists (select 1 from public.task_participants p where p.task_id = t.id and p.player_id = public.me())))))
$$;


ALTER FUNCTION "public"."can_see_event"("eid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_see_task"("tid" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (select 1 from public.tasks t where t.id = tid and public.board_visible(t.board_id) and (
    public.is_manager() or (public.is_staff() and (
         t.owner_id = public.me() or t.owner_id is null or t.created_by = public.me() or t.board_id is not null
      or exists (select 1 from public.task_participants p where p.task_id = t.id and p.player_id = public.me())))))
$$;


ALTER FUNCTION "public"."can_see_task"("tid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_my_replacement"("sid" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_me    uuid := public.me();
  v_start timestamptz;
begin
  if v_me is null then
    raise exception 'Bitte zuerst anmelden.';
  end if;
  select starts_at into v_start from public.sessions where id = sid;
  if v_start is null then
    raise exception 'Training nicht gefunden.';
  end if;
  if not exists (select 1 from public.assignments where session_id = sid and player_id = v_me) then
    raise exception 'Du bist für dieses Training nicht als Ersatz bestätigt.';
  end if;
  if v_start <= now() + interval '2 days' then
    raise exception 'Absagen geht nur bis 2 Tage vor dem Training. Melde dich bitte bei einem Admin.';
  end if;
  delete from public.assignments  where session_id = sid and player_id = v_me;
  delete from public.applications where session_id = sid and player_id = v_me;
end $$;


ALTER FUNCTION "public"."cancel_my_replacement"("sid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."chat_member"("p_assignment" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (select 1 from public.assignments x join public.absences a on a.id = x.absence_id
                 where x.id = p_assignment and public.me() in (x.player_id, a.player_id))
$$;


ALTER FUNCTION "public"."chat_member"("p_assignment" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."chat_peer"("p_assignment" "uuid") RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select case when x.player_id = public.me() then a.player_id else x.player_id end
  from public.assignments x join public.absences a on a.id = x.absence_id where x.id = p_assignment
$$;


ALTER FUNCTION "public"."chat_peer"("p_assignment" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."checklist_guard"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not public.is_manager() and (new.text is distinct from old.text or new.sort is distinct from old.sort
                                  or new.task_id is distinct from old.task_id) then
    raise exception 'Checklistenpunkte können nur Manager ändern.';
  end if;
  if new.done and not old.done then new.done_by := public.me(); new.done_at := now();
  elsif not new.done then new.done_by := null; new.done_at := null; end if;
  if new.done is distinct from old.done then
    insert into public.task_history (task_id, actor_id, action, details)
    values (new.task_id, public.me(), case when new.done then 'abgehakt' else 'Haken entfernt' end,
            jsonb_build_object('punkt', new.text));
  end if;
  return new;
end $$;


ALTER FUNCTION "public"."checklist_guard"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."coach_add_player"("p_team" "text", "p_name" "text", "p_email" "text" DEFAULT NULL::"text") RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_mail text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_team public.teams%rowtype; v_old public.players%rowtype; v_id uuid; v_count int; v_created boolean := false;
begin
  if not public.is_coach_or_admin() then raise exception 'Nur Trainer und Admins können Spieler zu Teams hinzufügen.'; end if;
  select * into v_team from public.teams where id = p_team;
  if v_team.id is null then raise exception 'Team nicht gefunden.'; end if;
  if length(v_name) < 2 or length(v_name) > 60 then raise exception 'Bitte den vollständigen Namen angeben.'; end if;
  if v_mail is not null and v_mail !~ '^\S+@\S+\.\S+$' then raise exception 'Die E-Mail-Adresse sieht nicht richtig aus.'; end if;

  select count(*) into v_count from public.players where team_id = p_team and active;
  if v_mail is not null then select * into v_old from public.players where email = v_mail; end if;

  if v_old.id is not null then
    if v_old.team_id = p_team and v_old.active then raise exception '% ist schon in diesem Team.', v_old.name; end if;
    if v_old.team_id is not null and v_old.active then
      raise exception '% spielt schon in einem anderen Team. Ein Teamwechsel geht nur über einen Admin.', v_old.name;
    end if;
    if not v_old.active then raise exception '% ist deaktiviert. Bitte einen Admin fragen.', v_old.name; end if;
    if v_count >= v_team.size then raise exception '% ist voll (% von % Plätzen).', v_team.name, v_count, v_team.size; end if;
    update public.players set team_id = p_team where id = v_old.id;
    v_id := v_old.id;
  else
    if v_count >= v_team.size then raise exception '% ist voll (% von % Plätzen).', v_team.name, v_count, v_team.size; end if;
    insert into public.players (name, email, team_id) values (v_name, v_mail, p_team) returning id into v_id;
    v_created := true;
  end if;

  -- Replacement-Pools wie bei allen Spielern des Teams
  delete from public.player_pools where player_id = v_id;
  insert into public.player_pools (player_id, pool_id)
  select v_id, pool_id from public.team_pools where team_id = p_team on conflict do nothing;
  return json_build_object('id', v_id, 'created', v_created, 'team_full', v_count + 1 >= v_team.size);
end $_$;


ALTER FUNCTION "public"."coach_add_player"("p_team" "text", "p_name" "text", "p_email" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."comments_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare t record; r uuid;
begin
  select * into t from public.tasks where id = new.task_id;
  for r in select distinct x from unnest(array[t.owner_id, t.created_by] ||
             array(select player_id from public.task_participants where task_id = t.id)) x where x is not null loop
    perform public.notify(r, 'task_comment', 'Kommentar: ' || t.title,
      public.actor_name() || ': ' || left(new.body, 140), 'task', t.id, null);
  end loop;
  return null;
end $$;


ALTER FUNCTION "public"."comments_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_shift_month"("p_month" "date") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare d date; n int := 0; we boolean; m date := date_trunc('month', p_month)::date;
begin
  if not public.is_planner() then raise exception 'Nur die Dienstplanung darf das.'; end if;
  insert into public.shift_months (month) values (m) on conflict do nothing;
  for d in select generate_series(m, (m + interval '1 month - 1 day')::date, '1 day')::date loop
    we := extract(isodow from d) >= 6;
    insert into public.shifts (day, kind, starts_at, ends_at)
    values (d, 'frueh', (d + case when we then time '07:45' else time '08:45' end) at time zone 'Europe/Berlin',
                        (d + case when we then time '16:00' else time '16:30' end) at time zone 'Europe/Berlin')
    on conflict do nothing;
    if found then n := n + 1; end if;
    insert into public.shifts (day, kind, starts_at, ends_at)
    values (d, 'spaet', (d + case when we then time '16:00' else time '16:30' end) at time zone 'Europe/Berlin',
                        (d + 1 + time '00:15') at time zone 'Europe/Berlin')
    on conflict do nothing;
    if found then n := n + 1; end if;
  end loop;
  return n;
end $$;


ALTER FUNCTION "public"."create_shift_month"("p_month" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ensure_daily_tasks"("p_day" "date" DEFAULT (("now"() AT TIME ZONE 'Europe/Berlin'::"text"))::"date") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare n int := 0; r record; v_id uuid;
begin
  if coalesce(auth.jwt() ->> 'email', '') <> '' and not public.is_staff() then
    raise exception 'Nur für Mitarbeiter.';
  end if;
  if p_day < (now() at time zone 'Europe/Berlin')::date - 30
     or p_day > (now() at time zone 'Europe/Berlin')::date + 14 then
    raise exception 'Datum außerhalb des erlaubten Bereichs.';
  end if;
  for r in select * from public.recurring_tasks rt
           where rt.active and p_day >= rt.start_date and (
             (rt.monthly_day is not null and extract(day from p_day)::int = rt.monthly_day)
             or (rt.monthly_day is null and extract(isodow from p_day)::int = any (rt.weekdays)
                 and ((p_day - (rt.start_date - (extract(isodow from rt.start_date)::int - 1))) / 7) % rt.interval_weeks = 0)) loop
    v_id := null;
    insert into public.tasks (title, description, category_id, priority, due_at, owner_id,
                              recurring_id, occurrence_date, created_by, board_id)
    values (r.title, r.description, r.category_id, r.priority,
            case when r.due_time is null then null else (p_day + r.due_time) at time zone 'Europe/Berlin' end,
            r.assignee_id, r.id, p_day, r.created_by, r.board_id)
    on conflict (recurring_id, occurrence_date) do nothing
    returning id into v_id;
    if v_id is not null then
      insert into public.task_checklist (task_id, text, sort)
      select v_id, x, o from unnest(r.checklist) with ordinality as u(x, o);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;


ALTER FUNCTION "public"."ensure_daily_tasks"("p_day" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."event_label"("eid" "uuid") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select title || ', ' || to_char(starts_at at time zone 'Europe/Berlin', 'DD.MM. HH24:MI') || ' Uhr' from public.events where id = eid
$$;


ALTER FUNCTION "public"."event_label"("eid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."event_staff_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public.notify(new.player_id, 'event_assigned', 'Event: ' || public.event_label(new.event_id),
    public.actor_name() || ' hat dich für dieses Event eingeteilt.', 'event', new.event_id, 'ev:' || new.event_id);
  return null;
end $$;


ALTER FUNCTION "public"."event_staff_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."events_guard"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if tg_op = 'INSERT' then new.created_by := coalesce(public.me(), new.created_by); new.created_at := now();
  else new.created_by := old.created_by; new.created_at := old.created_at; end if;
  new.updated_at := now();
  return new;
end $$;


ALTER FUNCTION "public"."events_guard"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."events_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare r uuid;
begin
  if tg_op = 'INSERT' then
    perform public.notify(new.manager_id, 'event_assigned', 'Du leitest: ' || public.event_label(new.id),
      public.actor_name() || ' hat dich als Eventmanager eingetragen.', 'event', new.id, 'evm:' || new.id || ':' || new.manager_id);
    return null;
  end if;
  if new.manager_id is distinct from old.manager_id and new.manager_id is not null then
    perform public.notify(new.manager_id, 'event_assigned', 'Du leitest: ' || public.event_label(new.id),
      public.actor_name() || ' hat dich als Eventmanager eingetragen.', 'event', new.id, 'evm:' || new.id || ':' || new.manager_id);
  end if;
  if new.starts_at is distinct from old.starts_at or (new.status = 'abgesagt' and old.status <> 'abgesagt') then
    for r in select player_id from public.event_staff where event_id = new.id union select new.manager_id loop
      perform public.notify(r, 'event_changed',
        case when new.status = 'abgesagt' then 'Abgesagt: ' else 'Geändert: ' end || public.event_label(new.id),
        case when new.status = 'abgesagt' then 'Das Event findet nicht statt.' else 'Neuer Termin – bitte prüfen.' end,
        'event', new.id, null);
    end loop;
  end if;
  return null;
end $$;


ALTER FUNCTION "public"."events_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_permission"("p" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.is_admin()
      or exists (select 1 from public.player_permissions where player_id = public.me() and permission = p)
$$;


ALTER FUNCTION "public"."has_permission"("p" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce((select is_admin from public.players where id = public.me()), false)
$$;


ALTER FUNCTION "public"."is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_coach"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce((select is_coach from public.players where id = public.me()), false)
$$;


ALTER FUNCTION "public"."is_coach"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_coach_or_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce((select is_admin or is_coach from public.players where id = public.me()), false)
$$;


ALTER FUNCTION "public"."is_coach_or_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_manager"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce((select is_admin or is_manager from public.players where id = public.me()), false)
$$;


ALTER FUNCTION "public"."is_manager"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_planner"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce((select is_shift_planner and active from public.players where id = public.me()), false)
$$;


ALTER FUNCTION "public"."is_planner"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_staff"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce((select is_admin or is_manager or is_staff from public.players where id = public.me()), false)
$$;


ALTER FUNCTION "public"."is_staff"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_super_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce((select is_admin and is_super_admin from public.players where id = public.me()), false)
$$;


ALTER FUNCTION "public"."is_super_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_chat_read"("p_assignment" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not public.chat_member(p_assignment) then return; end if;
  update public.replacement_messages set read_at = now()
  where assignment_id = p_assignment and sender_id <> public.me() and read_at is null;
  update public.notifications set read_at = now()
  where recipient_id = public.me() and kind = 'chat_message' and ref_id = p_assignment and read_at is null;
end $$;


ALTER FUNCTION "public"."mark_chat_read"("p_assignment" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."me"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select id from public.players
  where active and email is not null
    and email = lower(coalesce(auth.jwt() ->> 'email', ''))
  limit 1
$$;


ALTER FUNCTION "public"."me"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."me_profile"() RETURNS json
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select json_build_object(
    'id', p.id, 'name', p.name, 'email', p.email, 'team_id', p.team_id,
    'is_admin', p.is_admin, 'is_super_admin', p.is_super_admin and p.is_admin, 'is_coach', p.is_coach, 'is_manager', p.is_manager or p.is_admin,
    'is_staff', p.is_staff or p.is_manager or p.is_admin,
    'pools', coalesce((select json_agg(pool_id order by pool_id) from public.player_pools where player_id = p.id), '[]'::json),
    'permissions', coalesce((select json_agg(permission order by permission) from public.player_permissions where player_id = p.id), '[]'::json))
  from public.players p where p.id = public.me()
$$;


ALTER FUNCTION "public"."me_profile"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."my_chat_unread"() RETURNS TABLE("assignment_id" "uuid", "unread" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select m.assignment_id, count(*) from public.replacement_messages m
  where m.sender_id <> public.me() and m.read_at is null and public.chat_member(m.assignment_id)
  group by m.assignment_id
$$;


ALTER FUNCTION "public"."my_chat_unread"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."my_payment_targets"() RETURNS TABLE("absence_id" "uuid", "session_id" "uuid", "name" "text", "paypal" "text", "whatsapp" "text", "note" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select a.id, a.session_id, p.name, pp.paypal, pp.whatsapp, pp.note
  from public.assignments x
  join public.absences a on a.id = x.absence_id
  join public.players p on p.id = a.player_id
  join public.sessions s on s.id = x.session_id
  left join public.player_payment pp on pp.player_id = a.player_id
  where x.player_id = public.me() and s.starts_at > now() - interval '60 days'
$$;


ALTER FUNCTION "public"."my_payment_targets"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."my_team"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select team_id from public.players where id = public.me()
$$;


ALTER FUNCTION "public"."my_team"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notifications_push"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not exists (select 1 from public.push_subscriptions where player_id = new.recipient_id) then return null; end if;
  begin
    perform net.http_post(
      url     := 'https://nweoqhozcbrkihktqyqc.supabase.co/functions/v1/send-push',
      body    := jsonb_build_object('notification_id', new.id),
      headers := jsonb_build_object('Content-Type', 'application/json',
        'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im53ZW9xaG96Y2Jya2loa3RxeXFjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTEzODE2NDUsImV4cCI6MjEwNjk1NzY0NX0.zKCgmf41Gw-y6WEnzaYmH2u1RGP2xoEPE7pF236k3lk'));
  exception when others then
    raise warning 'Push nicht angestoßen: %', sqlerrm;
  end;
  return null;
end $$;


ALTER FUNCTION "public"."notifications_push"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify"("p_recipient" "uuid", "p_kind" "text", "p_title" "text", "p_body" "text", "p_ref_type" "text", "p_ref_id" "uuid", "p_dedupe" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if p_recipient is null then return; end if;
  if p_recipient = public.me() and p_kind not in ('task_due_soon', 'task_overdue', 'push_test', 'shift_reminder') then return; end if;
  if not exists (select 1 from public.players where id = p_recipient and active) then return; end if;
  insert into public.notifications (recipient_id, kind, title, body, ref_type, ref_id, dedupe_key)
  values (p_recipient, p_kind, left(p_title, 200), left(p_body, 500), p_ref_type, p_ref_id, p_dedupe)
  on conflict do nothing;
end $$;


ALTER FUNCTION "public"."notify"("p_recipient" "uuid", "p_kind" "text", "p_title" "text", "p_body" "text", "p_ref_type" "text", "p_ref_id" "uuid", "p_dedupe" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_due_tasks"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare n int := 0; t record; m record; who text; v_day text := to_char(now() at time zone 'Europe/Berlin', 'YYYY-MM-DD');
begin
  if coalesce(auth.jwt() ->> 'email', '') <> '' and not public.is_staff() then
    raise exception 'Nur für Mitarbeiter.';
  end if;
  for t in select * from public.tasks where status not in ('erledigt', 'on_hold') and owner_id is not null
           and due_at between now() and now() + interval '2 hours' loop
    perform public.notify(t.owner_id, 'task_due_soon', 'Bald fällig: ' || t.title,
      'Fällig um ' || to_char(t.due_at at time zone 'Europe/Berlin', 'HH24:MI') || ' Uhr.', 'task', t.id, 'soon:' || t.id);
    n := n + 1;
  end loop;
  for t in select * from public.tasks where status not in ('erledigt', 'on_hold')
           and due_at < now() and due_at > now() - interval '14 days' loop
    perform public.notify(t.owner_id, 'task_overdue', 'Überfällig: ' || t.title,
      'War fällig am ' || to_char(t.due_at at time zone 'Europe/Berlin', 'DD.MM., HH24:MI') || ' Uhr.', 'task', t.id, 'late:' || t.id || ':' || v_day);
    if t.priority in ('hoch', 'dringend') then
      who := coalesce((select name from public.players where id = t.owner_id), 'Alle Mitarbeiter');
      for m in select id from public.players where (is_manager or is_admin) and active and id is distinct from t.owner_id loop
        perform public.notify(m.id, 'task_escalated', 'Überfällig (' || case t.priority when 'dringend' then 'Kritisch' else 'Hoch' end || '): ' || t.title,
          who || ' – fällig war ' || to_char(t.due_at at time zone 'Europe/Berlin', 'DD.MM., HH24:MI') || ' Uhr.', 'task', t.id, 'esc:' || t.id);
      end loop;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;


ALTER FUNCTION "public"."notify_due_tasks"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_watchers"("sid" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare w record; v_s record;
begin
  if coalesce(current_setting('pb.skip_watch', true), '') = '1' then return; end if;
  select * into v_s from public.sessions where id = sid;
  if v_s.id is null or v_s.cancelled or v_s.starts_at <= now() then return; end if;
  if public.session_open(sid) <= 0 then return; end if;
  for w in select tw.player_id from public.team_watches tw
           join public.players p on p.id = tw.player_id and p.active
           where tw.team_id = v_s.team_id and p.team_id is distinct from v_s.team_id loop
    perform public.notify(w.player_id, 'spot_open', 'Platz frei: ' || public.session_label(sid),
      'In einem Team, das du beobachtest, ist ein Platz frei geworden. Jetzt bewerben.', 'session', sid, 'open:' || sid);
  end loop;
end $$;


ALTER FUNCTION "public"."notify_watchers"("sid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."participants_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public.notify(new.player_id, 'task_participant',
    'Du bist beteiligt: ' || (select title from public.tasks where id = new.task_id),
    public.actor_name() || ' hat dich zu einer Aufgabe hinzugefügt.', 'task', new.task_id, 'part:' || new.task_id);
  return null;
end $$;


ALTER FUNCTION "public"."participants_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."players_guard"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_me uuid := public.me(); v_super boolean;
begin
  if v_me is null then return coalesce(new, old); end if;
  v_super := public.is_super_admin();
  if tg_op = 'INSERT' then
    if (new.is_admin or new.is_super_admin) and not v_super then
      raise exception 'Admins können nur von Super-Admins angelegt werden.';
    end if;
    return new;
  end if;
  if tg_op = 'DELETE' then
    if (old.is_admin or old.is_super_admin) and not v_super then
      raise exception 'Admins können nur von Super-Admins entfernt werden.';
    end if;
    if old.is_super_admin and not exists (select 1 from public.players where is_super_admin and active and id <> old.id) then
      raise exception 'Der letzte Super-Admin kann nicht entfernt werden.';
    end if;
    return old;
  end if;
  if (new.is_admin is distinct from old.is_admin or new.is_super_admin is distinct from old.is_super_admin) and not v_super then
    raise exception 'Admin-Rechte können nur Super-Admins vergeben oder entziehen.';
  end if;
  if (old.is_admin or old.is_super_admin) and old.id <> v_me and not v_super then
    raise exception 'Admins können nur von Super-Admins bearbeitet werden.';
  end if;
  if old.is_super_admin and (not new.is_super_admin or not new.is_admin or not new.active)
     and not exists (select 1 from public.players where is_super_admin and active and id <> old.id) then
    raise exception 'Der letzte Super-Admin kann nicht entfernt werden.';
  end if;
  return new;
end $$;


ALTER FUNCTION "public"."players_guard"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."pool_options"() RETURNS TABLE("id" "text", "name" "text", "sort" integer)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select p.id, p.name, p.sort from public.pools p
  where coalesce(auth.jwt() ->> 'email', '') <> ''
  order by p.sort
$$;


ALTER FUNCTION "public"."pool_options"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."publish_shift_month"("p_month" "date") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare m date := date_trunc('month', p_month)::date; r record; n int := 0;
begin
  if not public.is_planner() then raise exception 'Nur die Dienstplanung darf das.'; end if;
  insert into public.shift_months (month, published_at, published_by) values (m, now(), public.me())
  on conflict (month) do update set published_at = now(), published_by = public.me();
  for r in select player_id, count(*) c, sum(extract(epoch from ends_at - starts_at)) / 3600 h from public.shifts
           where day >= m and day < m + interval '1 month' and player_id is not null group by player_id loop
    perform public.notify(r.player_id, 'shift_published', 'Dienstplan ' || to_char(m, 'MM/YYYY') || ' ist da',
      r.c || case when r.c = 1 then ' Schicht, ' else ' Schichten, ' end || replace(to_char(round(r.h::numeric, 2), 'FM990.99'), '.', ',') || ' Stunden.', null, null, 'pub:' || m || ':' || now()::date);
    n := n + 1;
  end loop;
  return n;
end $$;


ALTER FUNCTION "public"."publish_shift_month"("p_month" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."purge_old_chats"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare n int;
begin
  delete from public.replacement_messages where created_at < now() - interval '30 days';
  get diagnostics n = row_count;
  delete from public.notifications where kind = 'chat_message' and created_at < now() - interval '30 days';
  return n;
end $$;


ALTER FUNCTION "public"."purge_old_chats"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."push_public_key"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public_key from public.push_keys where id = 1
$$;


ALTER FUNCTION "public"."push_public_key"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."push_test"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if public.me() is null then raise exception 'Bitte zuerst anmelden.'; end if;
  perform public.notify(public.me(), 'push_test', 'Push-Nachrichten funktionieren 🎾',
    'So erfährst du künftig sofort von Bewerbungen, Bestätigungen und freien Plätzen.', null, null, null);
end $$;


ALTER FUNCTION "public"."push_test"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_self"("p_name" "text", "p_pools" "text"[]) RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_name  text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_id    uuid;
begin
  if v_email = '' then
    raise exception 'Bitte zuerst mit deiner E-Mail anmelden.';
  end if;
  if exists (select 1 from public.players where email = v_email and not active) then
    raise exception 'Dein Zugang ist deaktiviert. Melde dich bei Lukas oder Fernando.';
  end if;
  if exists (select 1 from public.players where email = v_email) then
    return public.me_profile();          -- schon registriert: nichts ändern
  end if;
  if length(v_name) < 2 or length(v_name) > 60 then
    raise exception 'Bitte gib deinen Vor- und Nachnamen an.';
  end if;
  if p_pools is null or cardinality(p_pools) = 0 then
    raise exception 'Bitte wähle mindestens ein Niveau.';
  end if;
  if exists (select 1 from unnest(p_pools) x where x not in (select id from public.pools)) then
    raise exception 'Unbekanntes Niveau.';
  end if;

  insert into public.players (name, email, team_id, is_admin, active)
  values (v_name, v_email, null, false, true)
  returning id into v_id;

  insert into public.player_pools (player_id, pool_id)
  select distinct v_id, x from unnest(p_pools) x;

  return public.me_profile();
end $$;


ALTER FUNCTION "public"."register_self"("p_name" "text", "p_pools" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."remind_shift_agreements"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_today date := (now() at time zone 'Europe/Berlin')::date; r record; n int := 0;
begin
  -- 3 Tage vorher
  for r in select player_id, array_agg(id order by starts_at) ids, string_agg(public.shift_label(s), ' · ' order by starts_at) labels, count(*) c
           from public.shifts s where player_id is not null and agreed_at is null and reminded_3_at is null and day = v_today + 3
           group by player_id loop
    perform public.notify(r.player_id, 'shift_reminder',
      case when r.c = 1 then 'Bitte Schicht zusagen' else 'Bitte ' || r.c || ' Schichten zusagen' end,
      r.labels, 'shift', r.ids[1], 'rem3:' || r.player_id || ':' || v_today);
    update public.shifts set reminded_3_at = now() where id = any (r.ids);
    n := n + 1;
  end loop;
  -- am Tag der Schicht (nur wenn sie noch nicht begonnen hat)
  for r in select player_id, array_agg(id order by starts_at) ids, string_agg(public.shift_label(s), ' · ' order by starts_at) labels, count(*) c
           from public.shifts s where player_id is not null and agreed_at is null and reminded_0_at is null and day = v_today and starts_at > now()
           group by player_id loop
    perform public.notify(r.player_id, 'shift_reminder',
      case when r.c = 1 then 'Heute: Schicht noch nicht zugesagt' else 'Heute: ' || r.c || ' Schichten noch nicht zugesagt' end,
      r.labels, 'shift', r.ids[1], 'rem0:' || r.player_id || ':' || v_today);
    update public.shifts set reminded_0_at = now() where id = any (r.ids);
    n := n + 1;
  end loop;
  return n;
end $$;


ALTER FUNCTION "public"."remind_shift_agreements"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."replacement_messages_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_peer uuid;
begin
  select case when x.player_id = new.sender_id then a.player_id else x.player_id end into v_peer
  from public.assignments x join public.absences a on a.id = x.absence_id where x.id = new.assignment_id;
  if v_peer is null or exists (select 1 from public.notifications n where n.recipient_id = v_peer and n.kind = 'chat_message'
                                and n.ref_id = new.assignment_id and n.read_at is null) then return null; end if;
  perform public.notify(v_peer, 'chat_message', 'Nachricht von ' || coalesce((select name from public.players where id = new.sender_id), 'deinem Ersatz'),
    'Tippe, um die Nachricht zu lesen.', 'chat', new.assignment_id, null);
  return null;
end $$;


ALTER FUNCTION "public"."replacement_messages_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."report_absence"("p_session" "uuid", "p_player" "uuid" DEFAULT NULL::"uuid", "p_replacement" "uuid" DEFAULT NULL::"uuid", "p_replacement_name" "text" DEFAULT NULL::"text", "p_reason" "text" DEFAULT NULL::"text") RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_me uuid := public.me(); v_target uuid; v_s record; v_abs uuid; v_rep uuid; v_asg uuid;
        v_name text := btrim(regexp_replace(coalesce(p_replacement_name, ''), '\s+', ' ', 'g'));
        v_admin boolean := public.is_coach_or_admin();
begin
  if v_me is null then raise exception 'Bitte zuerst anmelden.'; end if;
  v_target := coalesce(p_player, v_me);
  if v_target <> v_me and not v_admin then raise exception 'Nur Admins können andere Spieler abmelden.'; end if;
  select * into v_s from public.sessions where id = p_session;
  if v_s.id is null then raise exception 'Training nicht gefunden.'; end if;
  if v_s.cancelled then raise exception 'Dieses Training ist abgesagt.'; end if;
  if v_s.starts_at <= now() and not v_admin then raise exception 'Das Training hat schon begonnen.'; end if;
  if not exists (select 1 from public.players where id = v_target and team_id = v_s.team_id and active) then
    raise exception 'Diese Person spielt nicht in diesem Team.';
  end if;
  if p_replacement is not null then
    if not exists (select 1 from public.players where id = p_replacement and active) then raise exception 'Ersatzperson nicht gefunden.'; end if;
    v_rep := p_replacement;
  elsif v_name <> '' and (length(v_name) < 2 or length(v_name) > 60) then
    raise exception 'Bitte den vollständigen Namen des Ersatzes angeben.';
  end if;

  -- Wird der Ersatz gleich mit eingetragen, ist der Platz nie wirklich frei: keine „Platz frei“-Meldung.
  if v_rep is not null or v_name <> '' then perform set_config('pb.skip_watch', '1', true); end if;
  select id into v_abs from public.absences where session_id = p_session and player_id = v_target;
  if v_abs is null then
    insert into public.absences (session_id, player_id) values (p_session, v_target) returning id into v_abs;
  end if;
  if p_reason in ('Urlaub','Krankheit','Arbeit','Verletzung','Sonstiges') then
    insert into public.absence_reasons (absence_id, reason) values (v_abs, p_reason)
    on conflict (absence_id) do update set reason = excluded.reason;
  end if;
  if v_rep is null and v_name = '' then
    perform set_config('pb.skip_watch', '0', true);
    return json_build_object('absence_id', v_abs);
  end if;

  if exists (select 1 from public.assignments where absence_id = v_abs) then
    raise exception 'Für diesen Platz ist schon ein Ersatz eingetragen.';
  end if;
  if v_rep is null then
    select id into v_rep from public.players where is_guest and lower(name) = lower(v_name) limit 1;
    if v_rep is null then
      insert into public.players (name, is_guest) values (v_name, true) returning id into v_rep;
    end if;
  end if;
  if v_rep = v_target or exists (select 1 from public.players where id = v_rep and team_id = v_s.team_id) then
    raise exception 'Der Ersatz spielt selbst in diesem Team.';
  end if;
  if exists (select 1 from public.assignments where session_id = p_session and player_id = v_rep) then
    raise exception 'Diese Person ist für dieses Training schon eingeteilt.';
  end if;
  insert into public.assignments (session_id, player_id, absence_id, assigned_by)
  values (p_session, v_rep, v_abs, v_me) returning id into v_asg;
  perform set_config('pb.skip_watch', '0', true);
  return json_build_object('absence_id', v_abs, 'assignment_id', v_asg, 'replacement_id', v_rep);
end $$;


ALTER FUNCTION "public"."report_absence"("p_session" "uuid", "p_player" "uuid", "p_replacement" "uuid", "p_replacement_name" "text", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."report_sick"("p_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare s public.shifts; m record;
begin
  select * into s from public.shifts where id = p_id and player_id = public.me();
  if s.id is null then raise exception 'Das ist nicht deine Schicht.'; end if;
  if s.ends_at < now() then raise exception 'Diese Schicht ist schon vorbei.'; end if;
  insert into public.sick_reports (player_id, shift_id, day) values (public.me(), s.id, s.day);
  update public.shifts set player_id = null where id = s.id;
  for m in select id from public.players where is_shift_planner and active loop
    perform public.notify(m.id, 'shift_sick', 'Krankmeldung: ' || public.shift_label(s),
      coalesce((select name from public.players where id = public.me()), 'Jemand') || ' fällt aus – die Schicht ist jetzt OFFEN.', 'shift', s.id, 'sick:' || s.id || ':' || public.me());
  end loop;
end $$;


ALTER FUNCTION "public"."report_sick"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_push_subscription"("p_endpoint" "text", "p_p256dh" "text", "p_auth" "text", "p_user_agent" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if public.me() is null then raise exception 'Bitte zuerst anmelden.'; end if;
  if length(p_endpoint) > 1000 or p_endpoint !~ '^https://(fcm\.googleapis\.com|android\.googleapis\.com|[a-z0-9.-]*\.push\.apple\.com|[a-z0-9.-]*push\.services\.mozilla\.com|[a-z0-9.-]*\.notify\.windows\.com)/' then
    raise exception 'Dieses Gerät wird für Push-Nachrichten nicht unterstützt.';
  end if;
  if coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then raise exception 'Gerätedaten unvollständig.'; end if;
  insert into public.push_subscriptions (endpoint, player_id, p256dh, auth, user_agent)
  values (p_endpoint, public.me(), p_p256dh, p_auth, left(p_user_agent, 200))
  on conflict (endpoint) do update set player_id = excluded.player_id, p256dh = excluded.p256dh,
    auth = excluded.auth, user_agent = excluded.user_agent, created_at = now();
end $$;


ALTER FUNCTION "public"."save_push_subscription"("p_endpoint" "text", "p_p256dh" "text", "p_auth" "text", "p_user_agent" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."session_label"("sid" "uuid") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select t.name || ', ' || to_char(s.starts_at at time zone 'Europe/Berlin', 'DD.MM. HH24:MI') || ' Uhr'
  from public.sessions s join public.teams t on t.id = s.team_id where s.id = sid
$$;


ALTER FUNCTION "public"."session_label"("sid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."session_open"("sid" "uuid") RETURNS integer
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select greatest(0, t.size - (
           (select count(*) from public.players p
             where p.team_id = s.team_id and p.active)
         - (select count(*) from public.absences a
              join public.players p on p.id = a.player_id and p.team_id = s.team_id
             where a.session_id = s.id)
         + (select count(*) from public.assignments x where x.session_id = s.id)
         ))::int
  from public.sessions s join public.teams t on t.id = s.team_id
  where s.id = sid
$$;


ALTER FUNCTION "public"."session_open"("sid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sessions_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare r uuid;
begin
  if new.cancelled and not old.cancelled then
    for r in select id from public.players where team_id = new.team_id and active
             union select player_id from public.assignments where session_id = new.id loop
      perform public.notify(r, 'session_cancelled', 'Abgesagt: ' || public.session_label(new.id),
        coalesce(nullif(new.note, ''), 'Dieses Training findet nicht statt.'), 'session', new.id, 'cancel:' || new.id);
    end loop;
  end if;
  return null;
end $$;


ALTER FUNCTION "public"."sessions_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_avatar"("p_player" "uuid", "p_url" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if public.me() is null then raise exception 'Bitte zuerst anmelden.'; end if;
  if p_player is distinct from public.me() and not public.is_admin() then raise exception 'Nicht erlaubt.'; end if;
  if p_url is not null and (p_url !~ '^https://' or position('/storage/v1/object/public/avatars/' || p_player::text || '/' in p_url) = 0
                            or length(p_url) > 500) then
    raise exception 'Ungültige Bildadresse.';
  end if;
  update public.players set avatar_url = p_url where id = p_player;
  if not found then raise exception 'Person nicht gefunden.'; end if;
end $$;


ALTER FUNCTION "public"."set_avatar"("p_player" "uuid", "p_url" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_my_language"("p_lang" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if public.me() is null then return; end if;
  if p_lang not in ('de', 'en') then raise exception 'Unbekannte Sprache.'; end if;
  update public.players set language = p_lang where id = public.me() and language is distinct from p_lang;
end $$;


ALTER FUNCTION "public"."set_my_language"("p_lang" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."shifts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "day" "date" NOT NULL,
    "kind" "text" DEFAULT 'extra'::"text" NOT NULL,
    "starts_at" timestamp with time zone NOT NULL,
    "ends_at" timestamp with time zone NOT NULL,
    "player_id" "uuid",
    "agreed_at" timestamp with time zone,
    "approved_at" timestamp with time zone,
    "approved_by" "uuid",
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reminded_3_at" timestamp with time zone,
    "reminded_0_at" timestamp with time zone,
    CONSTRAINT "shift_time_ok" CHECK ((("ends_at" > "starts_at") AND (("ends_at" - "starts_at") <= '16:00:00'::interval))),
    CONSTRAINT "shifts_kind_check" CHECK (("kind" = ANY (ARRAY['frueh'::"text", 'spaet'::"text", 'extra'::"text"]))),
    CONSTRAINT "shifts_note_check" CHECK ((("note" IS NULL) OR ("length"("note") <= 200)))
);


ALTER TABLE "public"."shifts" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."shift_label"("s" "public"."shifts") RETURNS "text"
    LANGUAGE "sql" STABLE
    AS $$
  select (array['Mo','Di','Mi','Do','Fr','Sa','So'])[extract(isodow from s.day)::int] || ' ' || to_char(s.day, 'DD.MM.') || ' '
      || to_char(s.starts_at at time zone 'Europe/Berlin', 'HH24:MI') || '–' || to_char(s.ends_at at time zone 'Europe/Berlin', 'HH24:MI')
$$;


ALTER FUNCTION "public"."shift_label"("s" "public"."shifts") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."shifts_after"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare tpl record; v_tid uuid;
begin
  perform set_config('pb.system', '1', true);
  if new.player_id is null then
    update public.tasks set owner_id = null where shift_id = new.id and status <> 'erledigt';
    perform set_config('pb.system', '0', true);
    return null;
  end if;
  if tg_op = 'UPDATE' and new.player_id is not distinct from old.player_id
     and new.starts_at = old.starts_at and new.ends_at = old.ends_at then perform set_config('pb.system', '0', true); return null; end if;
  if new.ends_at > now() then
    perform public.notify(new.player_id, 'shift_assigned', 'Schicht: ' || public.shift_label(new),
      'Du bist eingeteilt. Bitte im Dienstplan zusagen.', 'shift', new.id, 'shift:' || new.id || ':' || new.player_id);
    select * into tpl from public.shift_task_templates where kind = new.kind;
    if tpl.kind is not null then
      update public.tasks set owner_id = new.player_id, due_at = new.ends_at where shift_id = new.id and status <> 'erledigt' returning id into v_tid;
      if v_tid is null and not exists (select 1 from public.tasks where shift_id = new.id) then
        insert into public.tasks (title, description, owner_id, due_at, shift_id, priority)
        values (tpl.title || ' ' || to_char(new.day, 'DD.MM.'), tpl.description, new.player_id, new.ends_at, new.id, 'normal') returning id into v_tid;
        insert into public.task_checklist (task_id, text, sort) select v_tid, x, o from unnest(tpl.checklist) with ordinality u(x, o);
      end if;
    end if;
  end if;
  perform set_config('pb.system', '0', true);
  return null;
end $$;


ALTER FUNCTION "public"."shifts_after"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."shifts_guard"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.player_id is not null and exists (
       select 1 from public.shifts x where x.player_id = new.player_id and x.id <> new.id
         and tstzrange(x.starts_at, x.ends_at) && tstzrange(new.starts_at, new.ends_at)) then
    raise exception '% hat in dieser Zeit schon eine Schicht.', (select name from public.players where id = new.player_id);
  end if;
  if tg_op = 'UPDATE' and new.player_id is distinct from old.player_id then
    new.agreed_at := null; new.approved_at := null; new.approved_by := null;
  end if;
  new.updated_at := now();
  return new;
end $$;


ALTER FUNCTION "public"."shifts_guard"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."suggestion_to_task"("p_id" "uuid", "p_board" "uuid" DEFAULT NULL::"uuid", "p_owner" "uuid" DEFAULT NULL::"uuid", "p_priority" "text" DEFAULT 'normal'::"text", "p_note" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v record; v_tid uuid;
begin
  if not public.is_manager() then raise exception 'Nur Manager können Vorschläge übernehmen.'; end if;
  select * into v from public.suggestions where id = p_id;
  if v.id is null then raise exception 'Vorschlag nicht gefunden.'; end if;
  if v.task_id is not null then raise exception 'Daraus wurde schon eine Aufgabe gemacht.'; end if;
  if not public.board_visible(p_board) then raise exception 'Board nicht gefunden.'; end if;
  insert into public.tasks (title, description, priority, owner_id, board_id)
  values (v.title, concat_ws(E'\n\n', v.body, 'Vorschlag von ' || coalesce((select name from public.players where id = v.author_id), 'unbekannt') || ' (' || v.area || ')'),
          coalesce(nullif(p_priority, ''), 'normal'), p_owner, p_board)
  returning id into v_tid;
  update public.suggestions set status = 'als_aufgabe', task_id = v_tid, decision_note = nullif(btrim(coalesce(p_note, '')), '') where id = p_id;
  return v_tid;
end $$;


ALTER FUNCTION "public"."suggestion_to_task"("p_id" "uuid", "p_board" "uuid", "p_owner" "uuid", "p_priority" "text", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."suggestions_guard"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if tg_op = 'INSERT' then new.created_at := now(); new.decided_by := null; new.decided_at := null; return new; end if;
  new.author_id := old.author_id; new.created_at := old.created_at;
  if new.status is distinct from old.status then new.decided_by := public.me(); new.decided_at := now(); end if;
  return new;
end $$;


ALTER FUNCTION "public"."suggestions_guard"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."suggestions_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare m record;
begin
  if tg_op = 'INSERT' then
    for m in select id from public.players where (is_manager or is_admin) and active loop
      perform public.notify(m.id, 'suggestion_new', 'Neuer Vorschlag: ' || new.title,
        coalesce((select name from public.players where id = new.author_id), 'Jemand') || ' · ' || new.area, 'suggestion', new.id, 'sug:' || new.id);
    end loop;
  elsif new.status is distinct from old.status and new.status <> 'neu' then
    perform public.notify(new.author_id, 'suggestion_decided', 'Dein Vorschlag: ' || new.title,
      case new.status when 'in_pruefung' then 'Wird geprüft.' when 'als_aufgabe' then 'Wird umgesetzt – es gibt jetzt eine Aufgabe dazu.'
        when 'zurueckgestellt' then 'Wurde vorerst zurückgestellt.' else 'Wird nicht umgesetzt.' end
      || coalesce(' ' || nullif(new.decision_note, ''), ''), 'suggestion', new.id, null);
  end if;
  return null;
end $$;


ALTER FUNCTION "public"."suggestions_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tags_ok"("x" "text"[]) RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select cardinality(x) <= 10 and coalesce(bool_and(length(btrim(t)) between 1 and 30), true) from unnest(x) t
$$;


ALTER FUNCTION "public"."tags_ok"("x" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tasks_board_sync"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_n int; v_mid int; v_moved boolean; v_park boolean;
begin
  if new.board_id is null then new.board_column := null; return new; end if;
  select cardinality(columns), coalesce(array_position(columns, 'In Bearbeitung'), 2) - 1
    into v_n, v_mid from public.boards where id = new.board_id;
  if v_n is null then new.board_id := null; new.board_column := null; return new; end if;
  v_mid := case when v_n <= 2 then 0 else least(greatest(v_mid, 1), v_n - 2) end;
  v_park := new.status in ('blockiert', 'on_hold');
  v_moved := new.board_column is not null and (
    tg_op = 'INSERT' or (new.board_id = old.board_id and new.board_column is distinct from old.board_column));
  if v_moved then
    new.board_column := least(greatest(new.board_column, 0), v_n - 1);
    if new.board_column = v_n - 1 then new.status := 'erledigt';
    elsif not v_park then new.status := case when new.board_column = 0 then 'offen' else 'in_bearbeitung' end;
    end if;
  elsif tg_op = 'INSERT' or new.status is distinct from old.status or new.board_id is distinct from old.board_id then
    new.board_column := case new.status
      when 'erledigt' then v_n - 1
      when 'offen' then 0
      when 'in_bearbeitung' then
        case when tg_op = 'UPDATE' and new.board_id = old.board_id and old.board_column between 1 and v_n - 2
             then old.board_column else v_mid end
      else coalesce(case when tg_op = 'UPDATE' and new.board_id = old.board_id and old.board_column < v_n - 1
                         then old.board_column end, 0) end;
  end if;
  return new;
end $$;


ALTER FUNCTION "public"."tasks_board_sync"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tasks_guard"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if tg_op = 'INSERT' then
    if new.recurring_id is null then new.created_by := coalesce(public.me(), new.created_by); end if;
    new.created_at := now(); new.updated_at := now();
    if new.status = 'erledigt' then new.completed_at := now(); new.completed_by := public.me(); end if;
    return new;
  end if;
  -- Automatische Änderungen (z. B. Dienstplan: Schichtaufgabe umhängen) sind Systemaktionen
  if not public.is_manager() and public.me() is not null and coalesce(current_setting('pb.system', true), '') <> '1' then
    if old.board_id is not null then
      if new.owner_id is distinct from old.owner_id and new.owner_id is not null and new.owner_id <> public.me() then
        raise exception 'Andere zuweisen dürfen nur Manager. Du kannst die Karte selbst übernehmen.';
      end if;
      if new.category_id is distinct from old.category_id or new.recurring_id is distinct from old.recurring_id
         or new.occurrence_date is distinct from old.occurrence_date or new.event_id is distinct from old.event_id
         or new.board_id is distinct from old.board_id then
        raise exception 'Das dürfen nur Manager ändern.';
      end if;
    elsif new.title is distinct from old.title or new.description is distinct from old.description
       or new.category_id is distinct from old.category_id or new.priority is distinct from old.priority
       or new.due_at is distinct from old.due_at or new.owner_id is distinct from old.owner_id
       or new.link_url is distinct from old.link_url or new.recurring_id is distinct from old.recurring_id
       or new.occurrence_date is distinct from old.occurrence_date or new.event_id is distinct from old.event_id
       or new.board_id is distinct from old.board_id then
      raise exception 'Das dürfen nur Manager ändern. Du kannst den Bearbeitungsstand anpassen.';
    end if;
  end if;
  new.created_by := old.created_by; new.created_at := old.created_at; new.updated_at := now();
  if new.status = 'erledigt' and old.status <> 'erledigt' then new.completed_at := now(); new.completed_by := public.me();
  elsif new.status <> 'erledigt' then new.completed_at := null; new.completed_by := null; end if;
  if new.status <> 'blockiert' then new.blocked_reason := null; end if;
  return new;
end $$;


ALTER FUNCTION "public"."tasks_guard"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tasks_log"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare d jsonb := '{}'::jsonb; f text;
begin
  if tg_op = 'INSERT' then
    insert into public.task_history (task_id, actor_id, action, details)
    values (new.id, case when new.recurring_id is null then public.me() end,
            case when new.recurring_id is null then 'erstellt' else 'automatisch erstellt' end,
            jsonb_build_object('status', new.status, 'owner_id', new.owner_id));
    return null;
  end if;
  foreach f in array array['title','description','category_id','priority','status','blocked_reason','due_at','owner_id'] loop
    if (to_jsonb(old) -> f) is distinct from (to_jsonb(new) -> f) then
      d := d || jsonb_build_object(f, jsonb_build_object('von', to_jsonb(old) -> f, 'zu', to_jsonb(new) -> f));
    end if;
  end loop;
  if d <> '{}'::jsonb then
    insert into public.task_history (task_id, actor_id, action, details) values (new.id, public.me(), 'geändert', d);
  end if;
  return null;
end $$;


ALTER FUNCTION "public"."tasks_log"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tasks_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare who text := public.actor_name(); m record;
begin
  if tg_op = 'INSERT' then
    if new.recurring_id is null and new.owner_id is not null then
      perform public.notify(new.owner_id, 'task_assigned', 'Neue Aufgabe: ' || new.title,
        who || ' hat dir eine Aufgabe zugewiesen.', 'task', new.id, 'assigned:' || new.id || ':' || new.owner_id);
    end if;
    return null;
  end if;
  if new.owner_id is distinct from old.owner_id and new.owner_id is not null then
    perform public.notify(new.owner_id, 'task_assigned', 'Neue Aufgabe: ' || new.title,
      who || ' hat dir eine Aufgabe zugewiesen.', 'task', new.id, 'assigned:' || new.id || ':' || new.owner_id);
  end if;
  if new.status = 'blockiert' and old.status <> 'blockiert' then
    for m in select id from public.players where (is_manager or is_admin) and active loop
      perform public.notify(m.id, 'task_blocked', 'Blockiert: ' || new.title,
        who || ': ' || coalesce(new.blocked_reason, ''), 'task', new.id, null);
    end loop;
  end if;
  if new.status = 'erledigt' and old.status <> 'erledigt' and new.recurring_id is null then
    perform public.notify(new.created_by, 'task_done', 'Erledigt: ' || new.title,
      who || ' hat die Aufgabe erledigt.', 'task', new.id, null);
  end if;
  if (new.due_at is distinct from old.due_at or new.title is distinct from old.title)
     and new.owner_id is not null and new.owner_id is not distinct from old.owner_id then
    perform public.notify(new.owner_id, 'task_changed', 'Geändert: ' || new.title,
      who || ' hat Titel oder Frist geändert.', 'task', new.id, null);
  end if;
  return null;
end $$;


ALTER FUNCTION "public"."tasks_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_presence"("p_installed" boolean, "p_platform" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_me uuid := public.me();
begin
  if v_me is null then return; end if;
  insert into public.player_presence (player_id, installed_at, last_platform)
  values (v_me, case when p_installed then now() end, left(p_platform, 40))
  on conflict (player_id) do update
    set last_seen_at = now(),
        installed_at = coalesce(public.player_presence.installed_at, case when p_installed then now() end),
        last_platform = coalesce(left(p_platform, 40), public.player_presence.last_platform);
end $$;


ALTER FUNCTION "public"."touch_presence"("p_installed" boolean, "p_platform" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."absence_reasons" (
    "absence_id" "uuid" NOT NULL,
    "reason" "text" NOT NULL,
    CONSTRAINT "absence_reasons_reason_check" CHECK (("reason" = ANY (ARRAY['Urlaub'::"text", 'Krankheit'::"text", 'Arbeit'::"text", 'Verletzung'::"text", 'Sonstiges'::"text"])))
);


ALTER TABLE "public"."absence_reasons" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."absences" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "player_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."absences" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."applications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "player_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."applications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "player_id" "uuid" NOT NULL,
    "absence_id" "uuid",
    "assigned_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."assignments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."boards" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "columns" "text"[] DEFAULT '{"Zu erledigen",Vorbereitet,"In Bearbeitung",Erledigt}'::"text"[] NOT NULL,
    "sort" integer DEFAULT 0 NOT NULL,
    "archived" boolean DEFAULT false NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "confidential" boolean DEFAULT false NOT NULL,
    CONSTRAINT "boards_columns_check" CHECK ((("cardinality"("columns") >= 2) AND ("cardinality"("columns") <= 8))),
    CONSTRAINT "boards_description_check" CHECK ((("description" IS NULL) OR ("length"("description") <= 500))),
    CONSTRAINT "boards_name_check" CHECK ((("length"("btrim"("name")) >= 1) AND ("length"("btrim"("name")) <= 60)))
);


ALTER TABLE "public"."boards" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_comments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "author_id" "uuid",
    "body" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "event_comments_body_check" CHECK ((("length"("btrim"("body")) >= 1) AND ("length"("btrim"("body")) <= 4000)))
);


ALTER TABLE "public"."event_comments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_staff" (
    "event_id" "uuid" NOT NULL,
    "player_id" "uuid" NOT NULL
);


ALTER TABLE "public"."event_staff" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "event_type" "text" DEFAULT 'sonstiges'::"text" NOT NULL,
    "starts_at" timestamp with time zone NOT NULL,
    "ends_at" timestamp with time zone,
    "manager_id" "uuid",
    "status" "text" DEFAULT 'geplant'::"text" NOT NULL,
    "link_url" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "events_event_type_check" CHECK (("event_type" = ANY (ARRAY['gps_turnier'::"text", 'internes_turnier'::"text", 'social_night'::"text", 'she_plays_padel'::"text", 'academy'::"text", 'teamevent'::"text", 'firmenevent'::"text", 'sichtung'::"text", 'sonstiges'::"text"]))),
    CONSTRAINT "events_status_check" CHECK (("status" = ANY (ARRAY['geplant'::"text", 'in_vorbereitung'::"text", 'bereit'::"text", 'abgeschlossen'::"text", 'abgesagt'::"text"]))),
    CONSTRAINT "events_title_check" CHECK ((("length"("btrim"("title")) >= 1) AND ("length"("btrim"("title")) <= 200)))
);


ALTER TABLE "public"."events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "recipient_id" "uuid" NOT NULL,
    "kind" "text" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text",
    "ref_type" "text",
    "ref_id" "uuid",
    "dedupe_key" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "read_at" timestamp with time zone,
    "pushed_at" timestamp with time zone,
    CONSTRAINT "notifications_ref_type_check" CHECK (("ref_type" = ANY (ARRAY['task'::"text", 'session'::"text", 'event'::"text", 'suggestion'::"text", 'shift'::"text", 'chat'::"text"])))
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."player_payment" (
    "player_id" "uuid" NOT NULL,
    "paypal" "text",
    "whatsapp" "text",
    "note" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "player_payment_note_check" CHECK ((("note" IS NULL) OR ("length"("note") <= 300))),
    CONSTRAINT "player_payment_paypal_check" CHECK ((("paypal" IS NULL) OR ("length"("paypal") <= 200))),
    CONSTRAINT "player_payment_whatsapp_check" CHECK ((("whatsapp" IS NULL) OR ("length"("whatsapp") <= 40)))
);


ALTER TABLE "public"."player_payment" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."player_permissions" (
    "player_id" "uuid" NOT NULL,
    "permission" "text" NOT NULL,
    CONSTRAINT "player_permissions_permission_check" CHECK (("permission" ~ '^[a-z_:]+$'::"text"))
);


ALTER TABLE "public"."player_permissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."player_pools" (
    "player_id" "uuid" NOT NULL,
    "pool_id" "text" NOT NULL
);


ALTER TABLE "public"."player_pools" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."player_presence" (
    "player_id" "uuid" NOT NULL,
    "first_seen_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_seen_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "installed_at" timestamp with time zone,
    "last_platform" "text"
);


ALTER TABLE "public"."player_presence" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."players" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "email" "text",
    "team_id" "text",
    "is_admin" boolean DEFAULT false NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_staff" boolean DEFAULT false NOT NULL,
    "is_manager" boolean DEFAULT false NOT NULL,
    "is_guest" boolean DEFAULT false NOT NULL,
    "is_coach" boolean DEFAULT false NOT NULL,
    "is_super_admin" boolean DEFAULT false NOT NULL,
    "language" "text" DEFAULT 'de'::"text" NOT NULL,
    "avatar_url" "text",
    "is_shift_planner" boolean DEFAULT false NOT NULL,
    CONSTRAINT "players_avatar_len" CHECK ((("avatar_url" IS NULL) OR ("length"("avatar_url") <= 500))),
    CONSTRAINT "players_email_check" CHECK ((("email" IS NULL) OR ("email" = "lower"("email")))),
    CONSTRAINT "players_language_ok" CHECK (("language" = ANY (ARRAY['de'::"text", 'en'::"text"]))),
    CONSTRAINT "super_admin_ist_admin" CHECK (((NOT "is_super_admin") OR "is_admin"))
);


ALTER TABLE "public"."players" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pools" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "sort" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."pools" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."push_keys" (
    "id" integer NOT NULL,
    "public_key" "text" NOT NULL,
    "private_key" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "push_keys_id_check" CHECK (("id" = 1))
);


ALTER TABLE "public"."push_keys" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."push_subscriptions" (
    "endpoint" "text" NOT NULL,
    "player_id" "uuid" NOT NULL,
    "p256dh" "text" NOT NULL,
    "auth" "text" NOT NULL,
    "user_agent" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."push_subscriptions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."recurring_tasks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "category_id" integer,
    "priority" "text" DEFAULT 'normal'::"text" NOT NULL,
    "weekdays" integer[] DEFAULT '{1,2,3,4,5,6,7}'::integer[] NOT NULL,
    "due_time" time without time zone,
    "assignee_id" "uuid",
    "checklist" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "interval_weeks" integer DEFAULT 1 NOT NULL,
    "monthly_day" integer,
    "start_date" "date" DEFAULT (("now"() AT TIME ZONE 'Europe/Berlin'::"text"))::"date" NOT NULL,
    "board_id" "uuid",
    CONSTRAINT "recurring_interval_ok" CHECK (("interval_weeks" = ANY (ARRAY[1, 2, 3, 4]))),
    CONSTRAINT "recurring_monthly_ok" CHECK ((("monthly_day" IS NULL) OR (("monthly_day" >= 1) AND ("monthly_day" <= 28)))),
    CONSTRAINT "recurring_tasks_priority_check" CHECK (("priority" = ANY (ARRAY['niedrig'::"text", 'normal'::"text", 'hoch'::"text", 'dringend'::"text"]))),
    CONSTRAINT "recurring_tasks_title_check" CHECK ((("length"("btrim"("title")) >= 1) AND ("length"("btrim"("title")) <= 200))),
    CONSTRAINT "recurring_tasks_weekdays_check" CHECK ((("cardinality"("weekdays") > 0) AND ("weekdays" <@ '{1,2,3,4,5,6,7}'::integer[])))
);


ALTER TABLE "public"."recurring_tasks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."replacement_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "assignment_id" "uuid" NOT NULL,
    "sender_id" "uuid" NOT NULL,
    "body" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "read_at" timestamp with time zone,
    CONSTRAINT "replacement_messages_body_check" CHECK ((("length"("btrim"("body")) >= 1) AND ("length"("btrim"("body")) <= 2000)))
);


ALTER TABLE "public"."replacement_messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slot_id" integer,
    "team_id" "text" NOT NULL,
    "label" "text" DEFAULT 'Training'::"text" NOT NULL,
    "coach" "text",
    "starts_at" timestamp with time zone NOT NULL,
    "ends_at" timestamp with time zone NOT NULL,
    "cancelled" boolean DEFAULT false NOT NULL,
    "note" "text"
);


ALTER TABLE "public"."sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."shift_months" (
    "month" "date" NOT NULL,
    "published_at" timestamp with time zone,
    "published_by" "uuid",
    CONSTRAINT "shift_months_month_check" CHECK ((EXTRACT("day" FROM "month") = (1)::numeric))
);


ALTER TABLE "public"."shift_months" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."shift_task_templates" (
    "kind" "text" NOT NULL,
    "title" "text" NOT NULL,
    "checklist" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "description" "text",
    CONSTRAINT "shift_task_templates_kind_check" CHECK (("kind" = ANY (ARRAY['frueh'::"text", 'spaet'::"text", 'extra'::"text"])))
);


ALTER TABLE "public"."shift_task_templates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sick_reports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "player_id" "uuid" NOT NULL,
    "shift_id" "uuid",
    "day" "date" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."sick_reports" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."slots" (
    "id" integer NOT NULL,
    "team_id" "text" NOT NULL,
    "label" "text" DEFAULT 'Training'::"text" NOT NULL,
    "weekday" integer NOT NULL,
    "start_time" time without time zone NOT NULL,
    "end_time" time without time zone NOT NULL,
    "coach" "text",
    CONSTRAINT "slots_weekday_check" CHECK ((("weekday" >= 1) AND ("weekday" <= 7)))
);


ALTER TABLE "public"."slots" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."slots_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."slots_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."slots_id_seq" OWNED BY "public"."slots"."id";



CREATE TABLE IF NOT EXISTS "public"."suggestions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "author_id" "uuid",
    "title" "text" NOT NULL,
    "body" "text",
    "area" "text" DEFAULT 'Sonstiges'::"text" NOT NULL,
    "status" "text" DEFAULT 'neu'::"text" NOT NULL,
    "decision_note" "text",
    "task_id" "uuid",
    "decided_by" "uuid",
    "decided_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "suggestions_area_check" CHECK (("area" = ANY (ARRAY['Hallenbetrieb'::"text", 'Sauberkeit'::"text", 'Lager'::"text", 'Technik'::"text", 'Events'::"text", 'Marketing'::"text", 'Akademie'::"text", 'Teams'::"text", 'Sonstiges'::"text"]))),
    CONSTRAINT "suggestions_body_check" CHECK ((("body" IS NULL) OR ("length"("body") <= 4000))),
    CONSTRAINT "suggestions_decision_note_check" CHECK ((("decision_note" IS NULL) OR ("length"("decision_note") <= 1000))),
    CONSTRAINT "suggestions_status_check" CHECK (("status" = ANY (ARRAY['neu'::"text", 'in_pruefung'::"text", 'als_aufgabe'::"text", 'zurueckgestellt'::"text", 'abgelehnt'::"text"]))),
    CONSTRAINT "suggestions_title_check" CHECK ((("length"("btrim"("title")) >= 3) AND ("length"("btrim"("title")) <= 200)))
);


ALTER TABLE "public"."suggestions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."task_categories" (
    "id" integer NOT NULL,
    "name" "text" NOT NULL,
    "sort" integer DEFAULT 0 NOT NULL,
    "active" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."task_categories" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."task_categories_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."task_categories_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."task_categories_id_seq" OWNED BY "public"."task_categories"."id";



CREATE TABLE IF NOT EXISTS "public"."task_checklist" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "task_id" "uuid" NOT NULL,
    "text" "text" NOT NULL,
    "sort" integer DEFAULT 0 NOT NULL,
    "done" boolean DEFAULT false NOT NULL,
    "done_by" "uuid",
    "done_at" timestamp with time zone,
    CONSTRAINT "task_checklist_text_check" CHECK ((("length"("btrim"("text")) >= 1) AND ("length"("btrim"("text")) <= 300)))
);


ALTER TABLE "public"."task_checklist" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."task_comments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "task_id" "uuid" NOT NULL,
    "author_id" "uuid",
    "body" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "task_comments_body_check" CHECK ((("length"("btrim"("body")) >= 1) AND ("length"("btrim"("body")) <= 4000)))
);


ALTER TABLE "public"."task_comments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."task_history" (
    "id" bigint NOT NULL,
    "task_id" "uuid" NOT NULL,
    "actor_id" "uuid",
    "action" "text" NOT NULL,
    "details" "jsonb",
    "at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."task_history" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."task_history_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."task_history_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."task_history_id_seq" OWNED BY "public"."task_history"."id";



CREATE TABLE IF NOT EXISTS "public"."task_participants" (
    "task_id" "uuid" NOT NULL,
    "player_id" "uuid" NOT NULL
);


ALTER TABLE "public"."task_participants" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tasks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "category_id" integer,
    "priority" "text" DEFAULT 'normal'::"text" NOT NULL,
    "status" "text" DEFAULT 'offen'::"text" NOT NULL,
    "blocked_reason" "text",
    "due_at" timestamp with time zone,
    "owner_id" "uuid",
    "link_url" "text",
    "recurring_id" "uuid",
    "occurrence_date" "date",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "completed_at" timestamp with time zone,
    "completed_by" "uuid",
    "event_id" "uuid",
    "board_id" "uuid",
    "board_column" integer,
    "tags" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "notes" "text",
    "board_sort" double precision,
    "shift_id" "uuid",
    CONSTRAINT "blocked_needs_reason" CHECK ((("status" <> 'blockiert'::"text") OR ("length"("btrim"(COALESCE("blocked_reason", ''::"text"))) > 0))),
    CONSTRAINT "tasks_notes_len" CHECK ((("notes" IS NULL) OR ("length"("notes") <= 20000))),
    CONSTRAINT "tasks_priority_check" CHECK (("priority" = ANY (ARRAY['niedrig'::"text", 'normal'::"text", 'hoch'::"text", 'dringend'::"text"]))),
    CONSTRAINT "tasks_status_check" CHECK (("status" = ANY (ARRAY['offen'::"text", 'in_bearbeitung'::"text", 'blockiert'::"text", 'on_hold'::"text", 'erledigt'::"text"]))),
    CONSTRAINT "tasks_tags_ok" CHECK ("public"."tags_ok"("tags")),
    CONSTRAINT "tasks_title_check" CHECK ((("length"("btrim"("title")) >= 1) AND ("length"("btrim"("title")) <= 200)))
);


ALTER TABLE "public"."tasks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."team_pools" (
    "team_id" "text" NOT NULL,
    "pool_id" "text" NOT NULL
);


ALTER TABLE "public"."team_pools" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."team_watches" (
    "player_id" "uuid" NOT NULL,
    "team_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."team_watches" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."teams" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "size" integer DEFAULT 8 NOT NULL,
    "sort" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "teams_size_check" CHECK ((("size" >= 1) AND ("size" <= 20)))
);


ALTER TABLE "public"."teams" OWNER TO "postgres";


ALTER TABLE ONLY "public"."slots" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."slots_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."task_categories" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."task_categories_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."task_history" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."task_history_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."absence_reasons"
    ADD CONSTRAINT "absence_reasons_pkey" PRIMARY KEY ("absence_id");



ALTER TABLE ONLY "public"."absences"
    ADD CONSTRAINT "absences_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."absences"
    ADD CONSTRAINT "absences_session_id_player_id_key" UNIQUE ("session_id", "player_id");



ALTER TABLE ONLY "public"."applications"
    ADD CONSTRAINT "applications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."applications"
    ADD CONSTRAINT "applications_session_id_player_id_key" UNIQUE ("session_id", "player_id");



ALTER TABLE ONLY "public"."assignments"
    ADD CONSTRAINT "assignments_absence_id_key" UNIQUE ("absence_id");



ALTER TABLE ONLY "public"."assignments"
    ADD CONSTRAINT "assignments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."assignments"
    ADD CONSTRAINT "assignments_session_id_player_id_key" UNIQUE ("session_id", "player_id");



ALTER TABLE ONLY "public"."boards"
    ADD CONSTRAINT "boards_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."boards"
    ADD CONSTRAINT "boards_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_comments"
    ADD CONSTRAINT "event_comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_staff"
    ADD CONSTRAINT "event_staff_pkey" PRIMARY KEY ("event_id", "player_id");



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "one_instance_per_day" UNIQUE ("recurring_id", "occurrence_date");



ALTER TABLE ONLY "public"."player_payment"
    ADD CONSTRAINT "player_payment_pkey" PRIMARY KEY ("player_id");



ALTER TABLE ONLY "public"."player_permissions"
    ADD CONSTRAINT "player_permissions_pkey" PRIMARY KEY ("player_id", "permission");



ALTER TABLE ONLY "public"."player_pools"
    ADD CONSTRAINT "player_pools_pkey" PRIMARY KEY ("player_id", "pool_id");



ALTER TABLE ONLY "public"."player_presence"
    ADD CONSTRAINT "player_presence_pkey" PRIMARY KEY ("player_id");



ALTER TABLE ONLY "public"."players"
    ADD CONSTRAINT "players_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."players"
    ADD CONSTRAINT "players_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pools"
    ADD CONSTRAINT "pools_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."push_keys"
    ADD CONSTRAINT "push_keys_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."push_subscriptions"
    ADD CONSTRAINT "push_subscriptions_pkey" PRIMARY KEY ("endpoint");



ALTER TABLE ONLY "public"."recurring_tasks"
    ADD CONSTRAINT "recurring_tasks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."replacement_messages"
    ADD CONSTRAINT "replacement_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sessions"
    ADD CONSTRAINT "sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sessions"
    ADD CONSTRAINT "sessions_team_id_starts_at_key" UNIQUE ("team_id", "starts_at");



ALTER TABLE ONLY "public"."shift_months"
    ADD CONSTRAINT "shift_months_pkey" PRIMARY KEY ("month");



ALTER TABLE ONLY "public"."shift_task_templates"
    ADD CONSTRAINT "shift_task_templates_pkey" PRIMARY KEY ("kind");



ALTER TABLE ONLY "public"."shifts"
    ADD CONSTRAINT "shifts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sick_reports"
    ADD CONSTRAINT "sick_reports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."slots"
    ADD CONSTRAINT "slots_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."suggestions"
    ADD CONSTRAINT "suggestions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_categories"
    ADD CONSTRAINT "task_categories_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."task_categories"
    ADD CONSTRAINT "task_categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_checklist"
    ADD CONSTRAINT "task_checklist_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_comments"
    ADD CONSTRAINT "task_comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_history"
    ADD CONSTRAINT "task_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_participants"
    ADD CONSTRAINT "task_participants_pkey" PRIMARY KEY ("task_id", "player_id");



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."team_pools"
    ADD CONSTRAINT "team_pools_pkey" PRIMARY KEY ("team_id", "pool_id");



ALTER TABLE ONLY "public"."team_watches"
    ADD CONSTRAINT "team_watches_pkey" PRIMARY KEY ("player_id", "team_id");



ALTER TABLE ONLY "public"."teams"
    ADD CONSTRAINT "teams_pkey" PRIMARY KEY ("id");



CREATE UNIQUE INDEX "notifications_dedupe" ON "public"."notifications" USING "btree" ("recipient_id", "dedupe_key") WHERE ("dedupe_key" IS NOT NULL);



CREATE INDEX "notifications_recipient" ON "public"."notifications" USING "btree" ("recipient_id", "created_at" DESC);



CREATE INDEX "replacement_messages_asg" ON "public"."replacement_messages" USING "btree" ("assignment_id", "created_at");



CREATE INDEX "sessions_starts_at_idx" ON "public"."sessions" USING "btree" ("starts_at");



CREATE INDEX "shifts_day_idx" ON "public"."shifts" USING "btree" ("day");



CREATE UNIQUE INDEX "shifts_one_standard" ON "public"."shifts" USING "btree" ("day", "kind") WHERE ("kind" = ANY (ARRAY['frueh'::"text", 'spaet'::"text"]));



CREATE INDEX "shifts_player_idx" ON "public"."shifts" USING "btree" ("player_id");



CREATE INDEX "tasks_board_idx" ON "public"."tasks" USING "btree" ("board_id");



CREATE INDEX "tasks_event_idx" ON "public"."tasks" USING "btree" ("event_id");



CREATE UNIQUE INDEX "tasks_one_per_shift" ON "public"."tasks" USING "btree" ("shift_id") WHERE ("shift_id" IS NOT NULL);



CREATE INDEX "tasks_owner_idx" ON "public"."tasks" USING "btree" ("owner_id");



CREATE INDEX "tasks_status_idx" ON "public"."tasks" USING "btree" ("status", "due_at");



CREATE INDEX "tasks_tags_idx" ON "public"."tasks" USING "gin" ("tags");



CREATE OR REPLACE TRIGGER "absences_watch" AFTER INSERT ON "public"."absences" FOR EACH ROW EXECUTE FUNCTION "public"."absences_watch"();



CREATE OR REPLACE TRIGGER "applications_notify" AFTER INSERT ON "public"."applications" FOR EACH ROW EXECUTE FUNCTION "public"."applications_notify"();



CREATE OR REPLACE TRIGGER "assignments_notify" AFTER INSERT OR DELETE ON "public"."assignments" FOR EACH ROW EXECUTE FUNCTION "public"."assignments_notify"();



CREATE OR REPLACE TRIGGER "assignments_payment_notify" AFTER INSERT ON "public"."assignments" FOR EACH ROW EXECUTE FUNCTION "public"."assignments_payment_notify"();



CREATE OR REPLACE TRIGGER "assignments_watch" AFTER DELETE ON "public"."assignments" FOR EACH ROW EXECUTE FUNCTION "public"."assignments_watch"();



CREATE OR REPLACE TRIGGER "checklist_guard" BEFORE UPDATE ON "public"."task_checklist" FOR EACH ROW EXECUTE FUNCTION "public"."checklist_guard"();



CREATE OR REPLACE TRIGGER "comments_notify" AFTER INSERT ON "public"."task_comments" FOR EACH ROW EXECUTE FUNCTION "public"."comments_notify"();



CREATE OR REPLACE TRIGGER "event_staff_notify" AFTER INSERT ON "public"."event_staff" FOR EACH ROW EXECUTE FUNCTION "public"."event_staff_notify"();



CREATE OR REPLACE TRIGGER "events_guard" BEFORE INSERT OR UPDATE ON "public"."events" FOR EACH ROW EXECUTE FUNCTION "public"."events_guard"();



CREATE OR REPLACE TRIGGER "events_notify" AFTER INSERT OR UPDATE ON "public"."events" FOR EACH ROW EXECUTE FUNCTION "public"."events_notify"();



CREATE OR REPLACE TRIGGER "notifications_push" AFTER INSERT ON "public"."notifications" FOR EACH ROW EXECUTE FUNCTION "public"."notifications_push"();



CREATE OR REPLACE TRIGGER "participants_notify" AFTER INSERT ON "public"."task_participants" FOR EACH ROW EXECUTE FUNCTION "public"."participants_notify"();



CREATE OR REPLACE TRIGGER "players_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."players" FOR EACH ROW EXECUTE FUNCTION "public"."players_guard"();



CREATE OR REPLACE TRIGGER "replacement_messages_notify" AFTER INSERT ON "public"."replacement_messages" FOR EACH ROW EXECUTE FUNCTION "public"."replacement_messages_notify"();



CREATE OR REPLACE TRIGGER "sessions_notify" AFTER UPDATE ON "public"."sessions" FOR EACH ROW EXECUTE FUNCTION "public"."sessions_notify"();



CREATE OR REPLACE TRIGGER "shifts_after" AFTER INSERT OR UPDATE ON "public"."shifts" FOR EACH ROW EXECUTE FUNCTION "public"."shifts_after"();



CREATE OR REPLACE TRIGGER "shifts_guard" BEFORE INSERT OR UPDATE ON "public"."shifts" FOR EACH ROW EXECUTE FUNCTION "public"."shifts_guard"();



CREATE OR REPLACE TRIGGER "suggestions_guard" BEFORE INSERT OR UPDATE ON "public"."suggestions" FOR EACH ROW EXECUTE FUNCTION "public"."suggestions_guard"();



CREATE OR REPLACE TRIGGER "suggestions_notify" AFTER INSERT OR UPDATE ON "public"."suggestions" FOR EACH ROW EXECUTE FUNCTION "public"."suggestions_notify"();



CREATE OR REPLACE TRIGGER "tasks_board_sync" BEFORE INSERT OR UPDATE ON "public"."tasks" FOR EACH ROW EXECUTE FUNCTION "public"."tasks_board_sync"();



CREATE OR REPLACE TRIGGER "tasks_guard" BEFORE INSERT OR UPDATE ON "public"."tasks" FOR EACH ROW EXECUTE FUNCTION "public"."tasks_guard"();



CREATE OR REPLACE TRIGGER "tasks_log" AFTER INSERT OR UPDATE ON "public"."tasks" FOR EACH ROW EXECUTE FUNCTION "public"."tasks_log"();



CREATE OR REPLACE TRIGGER "tasks_notify" AFTER INSERT OR UPDATE ON "public"."tasks" FOR EACH ROW EXECUTE FUNCTION "public"."tasks_notify"();



ALTER TABLE ONLY "public"."absence_reasons"
    ADD CONSTRAINT "absence_reasons_absence_id_fkey" FOREIGN KEY ("absence_id") REFERENCES "public"."absences"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."absences"
    ADD CONSTRAINT "absences_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."players"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."absences"
    ADD CONSTRAINT "absences_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."applications"
    ADD CONSTRAINT "applications_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."players"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."applications"
    ADD CONSTRAINT "applications_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."assignments"
    ADD CONSTRAINT "assignments_absence_id_fkey" FOREIGN KEY ("absence_id") REFERENCES "public"."absences"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."assignments"
    ADD CONSTRAINT "assignments_assigned_by_fkey" FOREIGN KEY ("assigned_by") REFERENCES "public"."players"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."assignments"
    ADD CONSTRAINT "assignments_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."players"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."assignments"
    ADD CONSTRAINT "assignments_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."boards"
    ADD CONSTRAINT "boards_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."players"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."event_comments"
    ADD CONSTRAINT "event_comments_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "public"."players"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."event_comments"
    ADD CONSTRAINT "event_comments_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_staff"
    ADD CONSTRAINT "event_staff_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_staff"
    ADD CONSTRAINT "event_staff_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."players"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."players"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_manager_id_fkey" FOREIGN KEY ("manager_id") REFERENCES "public"."players"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_recipient_id_fkey" FOREIGN KEY ("recipient_id") REFERENCES "public"."players"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."player_payment"
    ADD CONSTRAINT "player_payment_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."players"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."player_permissions"
    ADD CONSTRAINT "player_permissions_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."players"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."player_pools"
    ADD CONSTRAINT "player_pools_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."players"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."player_pools"
    ADD CONSTRAINT "player_pools_pool_id_fkey" FOREIGN KEY ("pool_id") REFERENCES "public"."pools"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."player_presence"
    ADD CONSTRAINT "player_presence_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."players"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."players"
    ADD CONSTRAINT "players_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."push_subscriptions"
    ADD CONSTRAINT "push_subscriptions_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."players"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."recurring_tasks"
    ADD CONSTRAINT "recurring_tasks_assignee_id_fkey" FOREIGN KEY ("assignee_id") REFERENCES "public"."players"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."recurring_tasks"
    ADD CONSTRAINT "recurring_tasks_board_id_fkey" FOREIGN KEY ("board_id") REFERENCES "public"."boards"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."recurring_tasks"
    ADD CONSTRAINT "recurring_tasks_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."task_categories"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."recurring_tasks"
    ADD CONSTRAINT "recurring_tasks_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."players"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."replacement_messages"
    ADD CONSTRAINT "replacement_messages_assignment_id_fkey" FOREIGN KEY ("assignment_id") REFERENCES "public"."assignments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."replacement_messages"
    ADD CONSTRAINT "replacement_messages_sender_id_fkey" FOREIGN KEY ("sender_id") REFERENCES "public"."players"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sessions"
    ADD CONSTRAINT "sessions_slot_id_fkey" FOREIGN KEY ("slot_id") REFERENCES "public"."slots"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sessions"
    ADD CONSTRAINT "sessions_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."shift_months"
    ADD CONSTRAINT "shift_months_published_by_fkey" FOREIGN KEY ("published_by") REFERENCES "public"."players"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."shifts"
    ADD CONSTRAINT "shifts_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "public"."players"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."shifts"
    ADD CONSTRAINT "shifts_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."players"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sick_reports"
    ADD CONSTRAINT "sick_reports_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."players"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sick_reports"
    ADD CONSTRAINT "sick_reports_shift_id_fkey" FOREIGN KEY ("shift_id") REFERENCES "public"."shifts"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."slots"
    ADD CONSTRAINT "slots_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."suggestions"
    ADD CONSTRAINT "suggestions_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "public"."players"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."suggestions"
    ADD CONSTRAINT "suggestions_decided_by_fkey" FOREIGN KEY ("decided_by") REFERENCES "public"."players"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."suggestions"
    ADD CONSTRAINT "suggestions_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."task_checklist"
    ADD CONSTRAINT "task_checklist_done_by_fkey" FOREIGN KEY ("done_by") REFERENCES "public"."players"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."task_checklist"
    ADD CONSTRAINT "task_checklist_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_comments"
    ADD CONSTRAINT "task_comments_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "public"."players"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."task_comments"
    ADD CONSTRAINT "task_comments_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_history"
    ADD CONSTRAINT "task_history_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "public"."players"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."task_history"
    ADD CONSTRAINT "task_history_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_participants"
    ADD CONSTRAINT "task_participants_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."players"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_participants"
    ADD CONSTRAINT "task_participants_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_board_id_fkey" FOREIGN KEY ("board_id") REFERENCES "public"."boards"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."task_categories"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_completed_by_fkey" FOREIGN KEY ("completed_by") REFERENCES "public"."players"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."players"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."players"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_recurring_id_fkey" FOREIGN KEY ("recurring_id") REFERENCES "public"."recurring_tasks"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_shift_id_fkey" FOREIGN KEY ("shift_id") REFERENCES "public"."shifts"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."team_pools"
    ADD CONSTRAINT "team_pools_pool_id_fkey" FOREIGN KEY ("pool_id") REFERENCES "public"."pools"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."team_pools"
    ADD CONSTRAINT "team_pools_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."team_watches"
    ADD CONSTRAINT "team_watches_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."players"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."team_watches"
    ADD CONSTRAINT "team_watches_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE CASCADE;



CREATE POLICY "absence_delete" ON "public"."absences" FOR DELETE TO "authenticated" USING (("public"."is_coach_or_admin"() OR (("player_id" = "public"."me"()) AND (NOT (EXISTS ( SELECT 1
   FROM "public"."assignments" "x"
  WHERE ("x"."absence_id" = "absences"."id")))) AND (EXISTS ( SELECT 1
   FROM "public"."sessions" "s"
  WHERE (("s"."id" = "absences"."session_id") AND ("s"."starts_at" > "now"())))))));



CREATE POLICY "absence_insert" ON "public"."absences" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_coach_or_admin"() OR (("player_id" = "public"."me"()) AND (EXISTS ( SELECT 1
   FROM "public"."sessions" "s"
  WHERE (("s"."id" = "absences"."session_id") AND ("s"."team_id" = "public"."my_team"()) AND (NOT "s"."cancelled") AND ("s"."starts_at" > "now"())))))));



ALTER TABLE "public"."absence_reasons" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."absences" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "admin_write" ON "public"."player_pools" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_write" ON "public"."players" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_write" ON "public"."pools" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_write" ON "public"."sessions" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_write" ON "public"."slots" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_write" ON "public"."team_pools" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin_write" ON "public"."teams" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "application_delete" ON "public"."applications" FOR DELETE TO "authenticated" USING (("public"."is_admin"() OR (("player_id" = "public"."me"()) AND (NOT (EXISTS ( SELECT 1
   FROM "public"."assignments" "x"
  WHERE (("x"."session_id" = "applications"."session_id") AND ("x"."player_id" = "applications"."player_id"))))))));



CREATE POLICY "application_insert" ON "public"."applications" FOR INSERT TO "authenticated" WITH CHECK ((("player_id" = "public"."me"()) AND "public"."can_apply"("session_id")));



ALTER TABLE "public"."applications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "assignment_delete" ON "public"."assignments" FOR DELETE TO "authenticated" USING ("public"."is_coach_or_admin"());



CREATE POLICY "assignment_insert" ON "public"."assignments" FOR INSERT TO "authenticated" WITH CHECK (((NOT (EXISTS ( SELECT 1
   FROM ("public"."sessions" "s"
     JOIN "public"."players" "p" ON (("p"."team_id" = "s"."team_id")))
  WHERE (("s"."id" = "assignments"."session_id") AND ("p"."id" = "assignments"."player_id"))))) AND (("public"."is_coach_or_admin"() AND (("absence_id" IS NULL) OR (EXISTS ( SELECT 1
   FROM "public"."absences" "a"
  WHERE (("a"."id" = "assignments"."absence_id") AND ("a"."session_id" = "assignments"."session_id")))))) OR (("absence_id" IS NOT NULL) AND ("assigned_by" = "public"."me"()) AND (EXISTS ( SELECT 1
   FROM ("public"."absences" "a"
     JOIN "public"."sessions" "s" ON (("s"."id" = "a"."session_id")))
  WHERE (("a"."id" = "assignments"."absence_id") AND ("a"."session_id" = "assignments"."session_id") AND ("a"."player_id" = "public"."me"()) AND ("s"."starts_at" > "now"()) AND (NOT "s"."cancelled")))) AND (EXISTS ( SELECT 1
   FROM "public"."applications" "ap"
  WHERE (("ap"."session_id" = "assignments"."session_id") AND ("ap"."player_id" = "assignments"."player_id"))))))));



ALTER TABLE "public"."assignments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."boards" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_comments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_staff" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "p_delete" ON "public"."event_comments" FOR DELETE TO "authenticated" USING ("public"."is_manager"());



CREATE POLICY "p_delete" ON "public"."notifications" FOR DELETE TO "authenticated" USING (("recipient_id" = "public"."me"()));



CREATE POLICY "p_delete" ON "public"."push_subscriptions" FOR DELETE TO "authenticated" USING (("player_id" = "public"."me"()));



CREATE POLICY "p_delete" ON "public"."suggestions" FOR DELETE TO "authenticated" USING ("public"."is_manager"());



CREATE POLICY "p_delete" ON "public"."task_checklist" FOR DELETE TO "authenticated" USING ("public"."is_manager"());



CREATE POLICY "p_delete" ON "public"."task_comments" FOR DELETE TO "authenticated" USING ("public"."is_manager"());



CREATE POLICY "p_delete" ON "public"."tasks" FOR DELETE TO "authenticated" USING (("public"."board_visible"("board_id") AND ("public"."is_manager"() OR (("board_id" IS NOT NULL) AND ("created_by" = "public"."me"())))));



CREATE POLICY "p_delete" ON "public"."team_watches" FOR DELETE TO "authenticated" USING (("player_id" = "public"."me"()));



CREATE POLICY "p_insert" ON "public"."event_comments" FOR INSERT TO "authenticated" WITH CHECK (("public"."can_see_event"("event_id") AND ("author_id" = "public"."me"())));



CREATE POLICY "p_insert" ON "public"."push_subscriptions" FOR INSERT TO "authenticated" WITH CHECK (("player_id" = "public"."me"()));



CREATE POLICY "p_insert" ON "public"."replacement_messages" FOR INSERT TO "authenticated" WITH CHECK ((("sender_id" = "public"."me"()) AND ("read_at" IS NULL) AND "public"."chat_member"("assignment_id")));



CREATE POLICY "p_insert" ON "public"."suggestions" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_staff"() AND ("author_id" = "public"."me"()) AND ("status" = 'neu'::"text")));



CREATE POLICY "p_insert" ON "public"."task_checklist" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_manager"() OR (EXISTS ( SELECT 1
   FROM "public"."tasks" "t"
  WHERE (("t"."id" = "task_checklist"."task_id") AND ((("t"."owner_id" = "public"."me"()) AND ("t"."created_by" = "public"."me"())) OR (("t"."board_id" IS NOT NULL) AND "public"."is_staff"())))))));



CREATE POLICY "p_insert" ON "public"."task_comments" FOR INSERT TO "authenticated" WITH CHECK (("public"."can_see_task"("task_id") AND ("author_id" = "public"."me"())));



CREATE POLICY "p_insert" ON "public"."tasks" FOR INSERT TO "authenticated" WITH CHECK (("public"."board_visible"("board_id") AND ("public"."is_manager"() OR ("public"."is_staff"() AND ("recurring_id" IS NULL) AND (("owner_id" = "public"."me"()) OR (("board_id" IS NOT NULL) AND ("owner_id" IS NULL)))))));



CREATE POLICY "p_insert" ON "public"."team_watches" FOR INSERT TO "authenticated" WITH CHECK (("player_id" = "public"."me"()));



CREATE POLICY "p_own" ON "public"."player_payment" TO "authenticated" USING (("player_id" = "public"."me"())) WITH CHECK (("player_id" = "public"."me"()));



CREATE POLICY "p_read" ON "public"."boards" FOR SELECT TO "authenticated" USING (("public"."is_staff"() AND ((NOT "confidential") OR "public"."is_super_admin"())));



CREATE POLICY "p_read" ON "public"."event_comments" FOR SELECT TO "authenticated" USING ("public"."can_see_event"("event_id"));



CREATE POLICY "p_read" ON "public"."event_staff" FOR SELECT TO "authenticated" USING ("public"."can_see_event"("event_id"));



CREATE POLICY "p_read" ON "public"."events" FOR SELECT TO "authenticated" USING ("public"."can_see_event"("id"));



CREATE POLICY "p_read" ON "public"."notifications" FOR SELECT TO "authenticated" USING (("recipient_id" = "public"."me"()));



CREATE POLICY "p_read" ON "public"."player_permissions" FOR SELECT TO "authenticated" USING ((("player_id" = "public"."me"()) OR "public"."is_admin"()));



CREATE POLICY "p_read" ON "public"."push_subscriptions" FOR SELECT TO "authenticated" USING (("player_id" = "public"."me"()));



CREATE POLICY "p_read" ON "public"."recurring_tasks" FOR SELECT TO "authenticated" USING (("public"."is_manager"() OR ("public"."is_staff"() AND (("assignee_id" IS NULL) OR ("assignee_id" = "public"."me"())))));



CREATE POLICY "p_read" ON "public"."replacement_messages" FOR SELECT TO "authenticated" USING ("public"."chat_member"("assignment_id"));



CREATE POLICY "p_read" ON "public"."shift_months" FOR SELECT TO "authenticated" USING (("public"."is_staff"() OR "public"."is_planner"()));



CREATE POLICY "p_read" ON "public"."shift_task_templates" FOR SELECT TO "authenticated" USING (("public"."is_staff"() OR "public"."is_planner"()));



CREATE POLICY "p_read" ON "public"."shifts" FOR SELECT TO "authenticated" USING (("public"."is_staff"() OR "public"."is_planner"()));



CREATE POLICY "p_read" ON "public"."sick_reports" FOR SELECT TO "authenticated" USING ((("player_id" = "public"."me"()) OR "public"."is_planner"()));



CREATE POLICY "p_read" ON "public"."suggestions" FOR SELECT TO "authenticated" USING ((("author_id" = "public"."me"()) OR "public"."is_manager"()));



CREATE POLICY "p_read" ON "public"."task_categories" FOR SELECT TO "authenticated" USING ("public"."is_staff"());



CREATE POLICY "p_read" ON "public"."task_checklist" FOR SELECT TO "authenticated" USING ("public"."can_see_task"("task_id"));



CREATE POLICY "p_read" ON "public"."task_comments" FOR SELECT TO "authenticated" USING ("public"."can_see_task"("task_id"));



CREATE POLICY "p_read" ON "public"."task_history" FOR SELECT TO "authenticated" USING ("public"."can_see_task"("task_id"));



CREATE POLICY "p_read" ON "public"."task_participants" FOR SELECT TO "authenticated" USING ("public"."can_see_task"("task_id"));



CREATE POLICY "p_read" ON "public"."tasks" FOR SELECT TO "authenticated" USING (("public"."board_visible"("board_id") AND ("public"."is_manager"() OR ("public"."is_staff"() AND (("owner_id" = "public"."me"()) OR ("owner_id" IS NULL) OR ("created_by" = "public"."me"()) OR ("board_id" IS NOT NULL) OR (EXISTS ( SELECT 1
   FROM "public"."task_participants" "p"
  WHERE (("p"."task_id" = "tasks"."id") AND ("p"."player_id" = "public"."me"())))))))));



CREATE POLICY "p_read" ON "public"."team_watches" FOR SELECT TO "authenticated" USING (("player_id" = "public"."me"()));



CREATE POLICY "p_update" ON "public"."notifications" FOR UPDATE TO "authenticated" USING (("recipient_id" = "public"."me"())) WITH CHECK (("recipient_id" = "public"."me"()));



CREATE POLICY "p_update" ON "public"."push_subscriptions" FOR UPDATE TO "authenticated" USING (("player_id" = "public"."me"())) WITH CHECK (("player_id" = "public"."me"()));



CREATE POLICY "p_update" ON "public"."suggestions" FOR UPDATE TO "authenticated" USING ("public"."is_manager"()) WITH CHECK ("public"."is_manager"());



CREATE POLICY "p_update" ON "public"."task_checklist" FOR UPDATE TO "authenticated" USING ("public"."can_see_task"("task_id")) WITH CHECK ("public"."can_see_task"("task_id"));



CREATE POLICY "p_update" ON "public"."tasks" FOR UPDATE TO "authenticated" USING (("public"."board_visible"("board_id") AND ("public"."is_manager"() OR ("public"."is_staff"() AND (("owner_id" = "public"."me"()) OR ("owner_id" IS NULL) OR ("created_by" = "public"."me"()) OR ("board_id" IS NOT NULL) OR (EXISTS ( SELECT 1
   FROM "public"."task_participants" "p"
  WHERE (("p"."task_id" = "tasks"."id") AND ("p"."player_id" = "public"."me"()))))))))) WITH CHECK (("public"."board_visible"("board_id") AND ("public"."is_manager"() OR ("public"."is_staff"() AND (("owner_id" = "public"."me"()) OR ("owner_id" IS NULL) OR ("created_by" = "public"."me"()) OR ("board_id" IS NOT NULL) OR (EXISTS ( SELECT 1
   FROM "public"."task_participants" "p"
  WHERE (("p"."task_id" = "tasks"."id") AND ("p"."player_id" = "public"."me"())))))))));



CREATE POLICY "p_write" ON "public"."boards" TO "authenticated" USING (("public"."is_manager"() AND ((NOT "confidential") OR "public"."is_super_admin"()))) WITH CHECK (("public"."is_manager"() AND ((NOT "confidential") OR "public"."is_super_admin"())));



CREATE POLICY "p_write" ON "public"."event_staff" TO "authenticated" USING ("public"."is_manager"()) WITH CHECK ("public"."is_manager"());



CREATE POLICY "p_write" ON "public"."events" TO "authenticated" USING ("public"."is_manager"()) WITH CHECK ("public"."is_manager"());



CREATE POLICY "p_write" ON "public"."player_permissions" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "p_write" ON "public"."recurring_tasks" TO "authenticated" USING ("public"."is_manager"()) WITH CHECK ("public"."is_manager"());



CREATE POLICY "p_write" ON "public"."shift_months" TO "authenticated" USING ("public"."is_planner"()) WITH CHECK ("public"."is_planner"());



CREATE POLICY "p_write" ON "public"."shift_task_templates" TO "authenticated" USING ("public"."is_planner"()) WITH CHECK ("public"."is_planner"());



CREATE POLICY "p_write" ON "public"."shifts" TO "authenticated" USING ("public"."is_planner"()) WITH CHECK ("public"."is_planner"());



CREATE POLICY "p_write" ON "public"."task_categories" TO "authenticated" USING ("public"."is_manager"()) WITH CHECK ("public"."is_manager"());



CREATE POLICY "p_write" ON "public"."task_participants" TO "authenticated" USING ("public"."is_manager"()) WITH CHECK ("public"."is_manager"());



ALTER TABLE "public"."player_payment" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."player_permissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."player_pools" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."player_presence" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."players" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pools" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."push_keys" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."push_subscriptions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "read_members" ON "public"."absences" FOR SELECT TO "authenticated" USING (("public"."me"() IS NOT NULL));



CREATE POLICY "read_members" ON "public"."applications" FOR SELECT TO "authenticated" USING (("public"."me"() IS NOT NULL));



CREATE POLICY "read_members" ON "public"."assignments" FOR SELECT TO "authenticated" USING (("public"."me"() IS NOT NULL));



CREATE POLICY "read_members" ON "public"."player_pools" FOR SELECT TO "authenticated" USING (("public"."me"() IS NOT NULL));



CREATE POLICY "read_members" ON "public"."players" FOR SELECT TO "authenticated" USING (("public"."me"() IS NOT NULL));



CREATE POLICY "read_members" ON "public"."pools" FOR SELECT TO "authenticated" USING (("public"."me"() IS NOT NULL));



CREATE POLICY "read_members" ON "public"."sessions" FOR SELECT TO "authenticated" USING (("public"."me"() IS NOT NULL));



CREATE POLICY "read_members" ON "public"."slots" FOR SELECT TO "authenticated" USING (("public"."me"() IS NOT NULL));



CREATE POLICY "read_members" ON "public"."team_pools" FOR SELECT TO "authenticated" USING (("public"."me"() IS NOT NULL));



CREATE POLICY "read_members" ON "public"."teams" FOR SELECT TO "authenticated" USING (("public"."me"() IS NOT NULL));



CREATE POLICY "reason_select" ON "public"."absence_reasons" FOR SELECT TO "authenticated" USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."absences" "a"
  WHERE (("a"."id" = "absence_reasons"."absence_id") AND ("a"."player_id" = "public"."me"()))))));



CREATE POLICY "reason_write" ON "public"."absence_reasons" TO "authenticated" USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."absences" "a"
  WHERE (("a"."id" = "absence_reasons"."absence_id") AND ("a"."player_id" = "public"."me"())))))) WITH CHECK (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."absences" "a"
  WHERE (("a"."id" = "absence_reasons"."absence_id") AND ("a"."player_id" = "public"."me"()))))));



ALTER TABLE "public"."recurring_tasks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."replacement_messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sessions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."shift_months" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."shift_task_templates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."shifts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sick_reports" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."slots" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."suggestions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."task_categories" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."task_checklist" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."task_comments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."task_history" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."task_participants" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tasks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."team_pools" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."team_watches" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."teams" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."absences";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."applications";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."assignments";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."boards";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."event_comments";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."event_staff";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."events";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."notifications";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."replacement_messages";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."sessions";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."shifts";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."suggestions";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."task_checklist";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."task_comments";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."tasks";






GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";














































































































































































GRANT ALL ON FUNCTION "public"."absences_watch"() TO "anon";
GRANT ALL ON FUNCTION "public"."absences_watch"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."absences_watch"() TO "service_role";



GRANT ALL ON FUNCTION "public"."actor_name"() TO "anon";
GRANT ALL ON FUNCTION "public"."actor_name"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."actor_name"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."add_session_guest"("p_session" "uuid", "p_player" "uuid", "p_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."add_session_guest"("p_session" "uuid", "p_player" "uuid", "p_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_session_guest"("p_session" "uuid", "p_player" "uuid", "p_name" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_login_status"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_login_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_login_status"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_players"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_players"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_players"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."agree_shift"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."agree_shift"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."agree_shift"("p_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."applications_notify"() TO "anon";
GRANT ALL ON FUNCTION "public"."applications_notify"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."applications_notify"() TO "service_role";



GRANT ALL ON FUNCTION "public"."assignments_notify"() TO "anon";
GRANT ALL ON FUNCTION "public"."assignments_notify"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."assignments_notify"() TO "service_role";



GRANT ALL ON FUNCTION "public"."assignments_payment_notify"() TO "anon";
GRANT ALL ON FUNCTION "public"."assignments_payment_notify"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."assignments_payment_notify"() TO "service_role";



GRANT ALL ON FUNCTION "public"."assignments_watch"() TO "anon";
GRANT ALL ON FUNCTION "public"."assignments_watch"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."assignments_watch"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."board_visible"("bid" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."board_visible"("bid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."board_visible"("bid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."can_apply"("sid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_apply"("sid" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."can_see_event"("eid" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."can_see_event"("eid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_see_event"("eid" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."can_see_task"("tid" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."can_see_task"("tid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_see_task"("tid" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."cancel_my_replacement"("sid" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cancel_my_replacement"("sid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cancel_my_replacement"("sid" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."chat_member"("p_assignment" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."chat_member"("p_assignment" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."chat_member"("p_assignment" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."chat_peer"("p_assignment" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."chat_peer"("p_assignment" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."chat_peer"("p_assignment" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."checklist_guard"() TO "anon";
GRANT ALL ON FUNCTION "public"."checklist_guard"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."checklist_guard"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."coach_add_player"("p_team" "text", "p_name" "text", "p_email" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."coach_add_player"("p_team" "text", "p_name" "text", "p_email" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."coach_add_player"("p_team" "text", "p_name" "text", "p_email" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."comments_notify"() TO "anon";
GRANT ALL ON FUNCTION "public"."comments_notify"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."comments_notify"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_shift_month"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_shift_month"("p_month" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_shift_month"("p_month" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."ensure_daily_tasks"("p_day" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ensure_daily_tasks"("p_day" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ensure_daily_tasks"("p_day" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."event_label"("eid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."event_label"("eid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."event_label"("eid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."event_staff_notify"() TO "anon";
GRANT ALL ON FUNCTION "public"."event_staff_notify"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."event_staff_notify"() TO "service_role";



GRANT ALL ON FUNCTION "public"."events_guard"() TO "anon";
GRANT ALL ON FUNCTION "public"."events_guard"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."events_guard"() TO "service_role";



GRANT ALL ON FUNCTION "public"."events_notify"() TO "anon";
GRANT ALL ON FUNCTION "public"."events_notify"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."events_notify"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."has_permission"("p" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."has_permission"("p" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_permission"("p" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_coach"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_coach"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_coach"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_coach_or_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_coach_or_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_coach_or_admin"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_manager"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_manager"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_manager"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_planner"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_planner"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_planner"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_staff"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_staff"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_staff"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_super_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_super_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_super_admin"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."mark_chat_read"("p_assignment" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."mark_chat_read"("p_assignment" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."mark_chat_read"("p_assignment" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."me"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."me"() TO "service_role";



GRANT ALL ON FUNCTION "public"."me_profile"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."me_profile"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."my_chat_unread"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."my_chat_unread"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."my_chat_unread"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."my_payment_targets"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."my_payment_targets"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."my_payment_targets"() TO "service_role";



GRANT ALL ON FUNCTION "public"."my_team"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."my_team"() TO "service_role";



GRANT ALL ON FUNCTION "public"."notifications_push"() TO "anon";
GRANT ALL ON FUNCTION "public"."notifications_push"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notifications_push"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."notify"("p_recipient" "uuid", "p_kind" "text", "p_title" "text", "p_body" "text", "p_ref_type" "text", "p_ref_id" "uuid", "p_dedupe" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notify"("p_recipient" "uuid", "p_kind" "text", "p_title" "text", "p_body" "text", "p_ref_type" "text", "p_ref_id" "uuid", "p_dedupe" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."notify_due_tasks"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notify_due_tasks"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_due_tasks"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."notify_watchers"("sid" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notify_watchers"("sid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."participants_notify"() TO "anon";
GRANT ALL ON FUNCTION "public"."participants_notify"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."participants_notify"() TO "service_role";



GRANT ALL ON FUNCTION "public"."players_guard"() TO "anon";
GRANT ALL ON FUNCTION "public"."players_guard"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."players_guard"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."pool_options"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."pool_options"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."pool_options"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."publish_shift_month"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."publish_shift_month"("p_month" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."publish_shift_month"("p_month" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."purge_old_chats"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."purge_old_chats"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."purge_old_chats"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."push_public_key"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."push_public_key"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."push_public_key"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."push_test"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."push_test"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."push_test"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."register_self"("p_name" "text", "p_pools" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."register_self"("p_name" "text", "p_pools" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."register_self"("p_name" "text", "p_pools" "text"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."remind_shift_agreements"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."remind_shift_agreements"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."remind_shift_agreements"() TO "service_role";



GRANT ALL ON FUNCTION "public"."replacement_messages_notify"() TO "anon";
GRANT ALL ON FUNCTION "public"."replacement_messages_notify"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."replacement_messages_notify"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."report_absence"("p_session" "uuid", "p_player" "uuid", "p_replacement" "uuid", "p_replacement_name" "text", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."report_absence"("p_session" "uuid", "p_player" "uuid", "p_replacement" "uuid", "p_replacement_name" "text", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."report_absence"("p_session" "uuid", "p_player" "uuid", "p_replacement" "uuid", "p_replacement_name" "text", "p_reason" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."report_sick"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."report_sick"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."report_sick"("p_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."save_push_subscription"("p_endpoint" "text", "p_p256dh" "text", "p_auth" "text", "p_user_agent" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."save_push_subscription"("p_endpoint" "text", "p_p256dh" "text", "p_auth" "text", "p_user_agent" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."save_push_subscription"("p_endpoint" "text", "p_p256dh" "text", "p_auth" "text", "p_user_agent" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."session_label"("sid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."session_label"("sid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."session_label"("sid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."session_open"("sid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."session_open"("sid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."sessions_notify"() TO "anon";
GRANT ALL ON FUNCTION "public"."sessions_notify"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sessions_notify"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_avatar"("p_player" "uuid", "p_url" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_avatar"("p_player" "uuid", "p_url" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_avatar"("p_player" "uuid", "p_url" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_my_language"("p_lang" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_my_language"("p_lang" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_my_language"("p_lang" "text") TO "service_role";



GRANT ALL ON TABLE "public"."shifts" TO "authenticated";
GRANT ALL ON TABLE "public"."shifts" TO "service_role";



GRANT ALL ON FUNCTION "public"."shift_label"("s" "public"."shifts") TO "anon";
GRANT ALL ON FUNCTION "public"."shift_label"("s" "public"."shifts") TO "authenticated";
GRANT ALL ON FUNCTION "public"."shift_label"("s" "public"."shifts") TO "service_role";



GRANT ALL ON FUNCTION "public"."shifts_after"() TO "anon";
GRANT ALL ON FUNCTION "public"."shifts_after"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."shifts_after"() TO "service_role";



GRANT ALL ON FUNCTION "public"."shifts_guard"() TO "anon";
GRANT ALL ON FUNCTION "public"."shifts_guard"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."shifts_guard"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."suggestion_to_task"("p_id" "uuid", "p_board" "uuid", "p_owner" "uuid", "p_priority" "text", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."suggestion_to_task"("p_id" "uuid", "p_board" "uuid", "p_owner" "uuid", "p_priority" "text", "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."suggestion_to_task"("p_id" "uuid", "p_board" "uuid", "p_owner" "uuid", "p_priority" "text", "p_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."suggestions_guard"() TO "anon";
GRANT ALL ON FUNCTION "public"."suggestions_guard"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."suggestions_guard"() TO "service_role";



GRANT ALL ON FUNCTION "public"."suggestions_notify"() TO "anon";
GRANT ALL ON FUNCTION "public"."suggestions_notify"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."suggestions_notify"() TO "service_role";



GRANT ALL ON FUNCTION "public"."tags_ok"("x" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."tags_ok"("x" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."tags_ok"("x" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."tasks_board_sync"() TO "anon";
GRANT ALL ON FUNCTION "public"."tasks_board_sync"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tasks_board_sync"() TO "service_role";



GRANT ALL ON FUNCTION "public"."tasks_guard"() TO "anon";
GRANT ALL ON FUNCTION "public"."tasks_guard"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tasks_guard"() TO "service_role";



GRANT ALL ON FUNCTION "public"."tasks_log"() TO "anon";
GRANT ALL ON FUNCTION "public"."tasks_log"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tasks_log"() TO "service_role";



GRANT ALL ON FUNCTION "public"."tasks_notify"() TO "anon";
GRANT ALL ON FUNCTION "public"."tasks_notify"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tasks_notify"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."touch_presence"("p_installed" boolean, "p_platform" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."touch_presence"("p_installed" boolean, "p_platform" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_presence"("p_installed" boolean, "p_platform" "text") TO "service_role";
























GRANT ALL ON TABLE "public"."absence_reasons" TO "authenticated";
GRANT ALL ON TABLE "public"."absence_reasons" TO "service_role";



GRANT ALL ON TABLE "public"."absences" TO "authenticated";
GRANT ALL ON TABLE "public"."absences" TO "service_role";



GRANT ALL ON TABLE "public"."applications" TO "authenticated";
GRANT ALL ON TABLE "public"."applications" TO "service_role";



GRANT ALL ON TABLE "public"."assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."assignments" TO "service_role";



GRANT ALL ON TABLE "public"."boards" TO "authenticated";
GRANT ALL ON TABLE "public"."boards" TO "service_role";



GRANT ALL ON TABLE "public"."event_comments" TO "authenticated";
GRANT ALL ON TABLE "public"."event_comments" TO "service_role";



GRANT ALL ON TABLE "public"."event_staff" TO "authenticated";
GRANT ALL ON TABLE "public"."event_staff" TO "service_role";



GRANT ALL ON TABLE "public"."events" TO "authenticated";
GRANT ALL ON TABLE "public"."events" TO "service_role";



GRANT ALL ON TABLE "public"."notifications" TO "service_role";
GRANT SELECT,DELETE ON TABLE "public"."notifications" TO "authenticated";



GRANT UPDATE("read_at") ON TABLE "public"."notifications" TO "authenticated";



GRANT ALL ON TABLE "public"."player_payment" TO "authenticated";
GRANT ALL ON TABLE "public"."player_payment" TO "service_role";



GRANT ALL ON TABLE "public"."player_permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."player_permissions" TO "service_role";



GRANT ALL ON TABLE "public"."player_pools" TO "authenticated";
GRANT ALL ON TABLE "public"."player_pools" TO "service_role";



GRANT ALL ON TABLE "public"."player_presence" TO "service_role";



GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."players" TO "authenticated";
GRANT ALL ON TABLE "public"."players" TO "service_role";



GRANT SELECT("id") ON TABLE "public"."players" TO "authenticated";



GRANT SELECT("name") ON TABLE "public"."players" TO "authenticated";



GRANT SELECT("team_id") ON TABLE "public"."players" TO "authenticated";



GRANT SELECT("is_admin") ON TABLE "public"."players" TO "authenticated";



GRANT SELECT("active") ON TABLE "public"."players" TO "authenticated";



GRANT SELECT("created_at") ON TABLE "public"."players" TO "authenticated";



GRANT SELECT("is_staff") ON TABLE "public"."players" TO "authenticated";



GRANT SELECT("is_manager") ON TABLE "public"."players" TO "authenticated";



GRANT SELECT("is_guest") ON TABLE "public"."players" TO "authenticated";



GRANT SELECT("is_coach") ON TABLE "public"."players" TO "authenticated";



GRANT SELECT("is_super_admin") ON TABLE "public"."players" TO "authenticated";



GRANT SELECT("avatar_url") ON TABLE "public"."players" TO "authenticated";



GRANT SELECT("is_shift_planner") ON TABLE "public"."players" TO "authenticated";



GRANT ALL ON TABLE "public"."pools" TO "authenticated";
GRANT ALL ON TABLE "public"."pools" TO "service_role";



GRANT ALL ON TABLE "public"."push_keys" TO "service_role";



GRANT ALL ON TABLE "public"."push_subscriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."push_subscriptions" TO "service_role";



GRANT ALL ON TABLE "public"."recurring_tasks" TO "authenticated";
GRANT ALL ON TABLE "public"."recurring_tasks" TO "service_role";



GRANT ALL ON TABLE "public"."replacement_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."replacement_messages" TO "service_role";



GRANT ALL ON TABLE "public"."sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."sessions" TO "service_role";



GRANT ALL ON TABLE "public"."shift_months" TO "anon";
GRANT ALL ON TABLE "public"."shift_months" TO "authenticated";
GRANT ALL ON TABLE "public"."shift_months" TO "service_role";



GRANT ALL ON TABLE "public"."shift_task_templates" TO "anon";
GRANT ALL ON TABLE "public"."shift_task_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."shift_task_templates" TO "service_role";



GRANT ALL ON TABLE "public"."sick_reports" TO "authenticated";
GRANT ALL ON TABLE "public"."sick_reports" TO "service_role";



GRANT ALL ON TABLE "public"."slots" TO "authenticated";
GRANT ALL ON TABLE "public"."slots" TO "service_role";



GRANT ALL ON SEQUENCE "public"."slots_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."slots_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."slots_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."suggestions" TO "authenticated";
GRANT ALL ON TABLE "public"."suggestions" TO "service_role";



GRANT ALL ON TABLE "public"."task_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."task_categories" TO "service_role";



GRANT ALL ON SEQUENCE "public"."task_categories_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."task_categories_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."task_categories_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."task_checklist" TO "authenticated";
GRANT ALL ON TABLE "public"."task_checklist" TO "service_role";



GRANT ALL ON TABLE "public"."task_comments" TO "authenticated";
GRANT ALL ON TABLE "public"."task_comments" TO "service_role";



GRANT ALL ON TABLE "public"."task_history" TO "authenticated";
GRANT ALL ON TABLE "public"."task_history" TO "service_role";



GRANT ALL ON SEQUENCE "public"."task_history_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."task_history_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."task_history_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."task_participants" TO "authenticated";
GRANT ALL ON TABLE "public"."task_participants" TO "service_role";



GRANT ALL ON TABLE "public"."tasks" TO "authenticated";
GRANT ALL ON TABLE "public"."tasks" TO "service_role";



GRANT ALL ON TABLE "public"."team_pools" TO "authenticated";
GRANT ALL ON TABLE "public"."team_pools" TO "service_role";



GRANT ALL ON TABLE "public"."team_watches" TO "authenticated";
GRANT ALL ON TABLE "public"."team_watches" TO "service_role";



GRANT ALL ON TABLE "public"."teams" TO "authenticated";
GRANT ALL ON TABLE "public"."teams" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";



































