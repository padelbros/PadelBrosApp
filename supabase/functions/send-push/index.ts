// PadelBros – Versanddienst für Push-Nachrichten (Supabase Edge Function „send-push“)
// Wird von der Datenbank bei jeder neuen Mitteilung angestoßen und schickt sie
// an alle Handys der Person. Die Versandschlüssel erzeugt der Dienst beim ersten
// Aufruf selbst und legt sie in der Datenbank ab (nur für ihn lesbar).
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } });
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type" };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

async function keys() {
  const { data } = await sb.from("push_keys").select("public_key, private_key").eq("id", 1).maybeSingle();
  if (data) return data;
  const k = webpush.generateVAPIDKeys();
  await sb.from("push_keys").insert({ id: 1, public_key: k.publicKey, private_key: k.privateKey });
  const { data: again, error } = await sb.from("push_keys").select("public_key, private_key").eq("id", 1).single();
  if (error) throw error;
  return again;
}

// Push auf Englisch für Personen, die die App auf Englisch nutzen
const EN: Record<string, string> = {"Neue Bewerbung: {}": "New application: {}", "{} möchte für dich einspringen. Du kannst bestätigen.": "{} would like to step in for you. You can confirm.", "Ersatz abgesagt: {}": "Replacement cancelled: {}", "{} hat abgesagt. Der Platz ist wieder frei – du kannst jemand Neues bestätigen.": "{} cancelled. The spot is free again – you can confirm someone new.", "Neuer Vorschlag: {}": "New suggestion: {}", "Blockiert: {}": "Waiting: {}", "Überfällig (Kritisch): {}": "Overdue (critical): {}", "Überfällig (Hoch): {}": "Overdue (high): {}", "{} – fällig war {}.": "{} – was due {}.", "Überfällig: {}": "Overdue: {}", "Dein Vorschlag: {}": "Your suggestion: {}", "Wird geprüft.": "Under review.", "Wird umgesetzt – es gibt jetzt eine Aufgabe dazu.{}": "Being implemented – there's now a task for it.{}", "Wurde vorerst zurückgestellt.{}": "Deferred for now.{}", "Wird nicht umgesetzt.{}": "Won't be implemented.{}", "Erledigt: {}": "Done: {}", "{} hat die Aufgabe erledigt.": "{} completed the task.", "Du leitest: {}": "You're leading: {}", "{} hat dich als Eventmanager eingetragen.": "{} made you the event manager.", "Neue Aufgabe: {}": "New task: {}", "{} hat dir eine Aufgabe zugewiesen.": "{} assigned you a task.", "Geändert: {}": "Changed: {}", "{} hat Titel oder Frist geändert.": "{} changed the title or deadline.", "Event: {}": "Event: {}", "{} hat dich für dieses Event eingeteilt.": "{} assigned you to this event.", "So bezahlst du {} (25 €)": "How to pay {} (€25)", "Bestätigt: {}": "Confirmed: {}", "Du springst für {} ein. Bitte zahl die 25 € direkt an {}.": "You're stepping in for {}. Please pay the €25 directly to {}.", "Du bist für dieses Training eingeteilt.": "You're scheduled for this training.", "Du bist beteiligt: {}": "You're involved: {}", "{} hat dich zu einer Aufgabe hinzugefügt.": "{} added you to a task.", "Zuordnung aufgehoben: {}": "Assignment removed: {}", "Ein Admin hat deine Zuordnung für dieses Training aufgehoben.": "An admin removed your assignment for this training.", "Push-Nachrichten funktionieren 🎾": "Push notifications work 🎾", "So erfährst du künftig sofort von Bewerbungen, Bestätigungen und freien Plätzen.": "From now on you'll hear instantly about applications, confirmations and open spots.", "Abgesagt: {}": "Cancelled: {}", "Das Event findet nicht statt.": "The event won't take place.", "Neuer Termin – bitte prüfen.": "New date – please check.", "Dieses Training findet nicht statt.": "This training won't take place.", "Kommentar: {}": "Comment: {}", "Bald fällig: {}": "Due soon: {}", "Fällig um {}.": "Due at {}.", "War fällig am {}.": "Was due on {}.", "Platz frei: {}": "Spot free: {}", "In einem Team, das du beobachtest, ist ein Platz frei geworden. Jetzt bewerben.": "A spot has opened up in a team you're watching. Apply now.", "Tippe, um den Kommentar zu lesen.": "Tap to read the comment.", "Schicht: {}": "Shift: {}", "Du bist eingeteilt. Bitte im Dienstplan zusagen.": "You're scheduled. Please confirm in the schedule.", "Krankmeldung: {}": "Sick note: {}", "{} fällt aus – die Schicht ist jetzt OFFEN.": "{} is off sick – the shift is now OPEN.", "Dienstplan {} ist da": "Schedule {} is out", "{} Schichten, {} Stunden.": "{} shifts, {} hours.", "{} Schicht, {} Stunden.": "{} shift, {} hours.", "Neue Aufgabe: Spätschicht-Checkliste {}": "New task: Late shift checklist {}", "Neue Aufgabe: Frühschicht-Checkliste {}": "New task: Early shift checklist {}", "Bitte Schicht zusagen": "Please confirm your shift", "Bitte {} Schichten zusagen": "Please confirm {} shifts", "Heute: Schicht noch nicht zugesagt": "Today: shift not confirmed yet", "Heute: {} Schichten noch nicht zugesagt": "Today: {} shifts not confirmed yet", "Nachricht von {}": "Message from {}", "Dienstplan KW {} ist da": "Schedule CW {} is out", "Keine kommenden Schichten.": "No upcoming shifts.", "Schicht in 7 Tagen: {}": "Shift in 7 days: {}", "Schicht morgen: {}": "Shift tomorrow: {}", "Schicht in 2 Stunden: {}": "Shift in 2 hours: {}", "Du bist eingeteilt.": "You're scheduled.", "Erinnerung: deine Schicht in 24 Stunden.": "Reminder: your shift in 24 hours.", "Bis gleich in der Halle!": "See you at the hall soon!", "1 Schicht in den nächsten 10 Tagen ist noch offen": "1 shift in the next 10 days is still open", "{} Schichten in den nächsten 10 Tagen sind noch offen": "{} shifts in the next 10 days are still open"};
const EN_PATS = Object.entries(EN).filter(([k]) => k.includes("{}")).map(([k, v]) => ({
  re: new RegExp("^" + k.split("{}").map((x) => x.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("([\\s\\S]*?)") + "$"), v, len: k.length,
})).sort((a, b) => b.len - a.len);
function toEnglish(s: string): string {
  if (!s) return s;
  let out = EN[s];
  if (out === undefined) for (const p of EN_PATS) { const m = s.match(p.re); if (m) { let k = 1; out = p.v.replace(/\{\}/g, () => m[k++] ?? ""); break; } }
  const WD: Record<string, string> = { Mo: "Mon", Di: "Tue", Mi: "Wed", Do: "Thu", Fr: "Fri", Sa: "Sat", So: "Sun" };
  return (out ?? s).replace(/(\d{1,2}:\d{2}) Uhr\b/g, "$1").replace(/\b(Mo|Di|Mi|Do|Fr|Sa|So)(?= \d)/g, (w) => WD[w]);
}

// ---------------------------------------------------------------------
// Datenschutz (DSGVO, Datensparsamkeit): Push-Nachrichten laufen über die
// Push-Dienste von Apple/Google/Mozilla und erscheinen auf dem Sperrbildschirm.
// Deshalb enthalten sie KEINE Namen, KEINE frei geschriebenen Texte (Chat,
// Kommentare, Aufgabentitel) und KEINE Gesundheitsdaten (Krankmeldungen).
// Details sieht man erst nach dem Öffnen in der App.
// ---------------------------------------------------------------------
// Titel enthalten nur Training/Schicht mit Datum → dürfen angezeigt werden
const SAFE_TITLE = new Set(["replacement_application", "replacement_cancelled", "replacement_confirmed", "replacement_removed",
  "session_cancelled", "spot_open", "shift_assigned", "shift_reminder", "shift_published", "push_test", "shift_upcoming", "shift_open_alert"]);
// Texte ohne Personendaten → dürfen angezeigt werden
const SAFE_BODY = new Set(["session_cancelled", "spot_open", "shift_assigned", "shift_reminder", "shift_published", "push_test", "shift_upcoming", "shift_open_alert"]);
const NEUTRAL: Record<string, [string, string]> = {
  chat_message: ["Neue Nachricht im Chat", "New chat message"],
  payment_info: ["Zahlungsinfos für dein Training", "Payment details for your training"],
  shift_sick: ["Dienstplan: Eine Schicht ist jetzt offen", "Schedule: a shift is now open"],
  task_assigned: ["Neue Aufgabe für dich", "New task for you"],
  task_participant: ["Du wurdest zu einer Aufgabe hinzugefügt", "You were added to a task"],
  task_comment: ["Neuer Kommentar zu einer Aufgabe", "New comment on a task"],
  task_done: ["Eine Aufgabe wurde erledigt", "A task was completed"],
  task_changed: ["Eine Aufgabe wurde geändert", "A task was changed"],
  task_blocked: ["Eine Aufgabe wartet auf Rückmeldung", "A task is waiting for a reply"],
  task_due_soon: ["Eine Aufgabe ist bald fällig", "A task is due soon"],
  task_overdue: ["Eine Aufgabe ist überfällig", "A task is overdue"],
  task_escalated: ["Wichtige Aufgabe überfällig", "Important task overdue"],
  event_assigned: ["Neues zu einem Event", "Update on an event"],
  event_changed: ["Ein Event wurde geändert", "An event was changed"],
  suggestion_new: ["Neuer Verbesserungsvorschlag", "New suggestion"],
  suggestion_decided: ["Neues zu deinem Vorschlag", "Update on your suggestion"],
};
const DETAILS: [string, string] = ["Tippe für Details.", "Tap for details."];
function pushText(n: { kind: string; title: string; body: string | null }, en: boolean): { title: string; body: string } {
  const k = en ? 1 : 0;
  const title = SAFE_TITLE.has(n.kind) ? (en ? toEnglish(n.title) : n.title) : (NEUTRAL[n.kind]?.[k] ?? (en ? "New notification" : "Neue Mitteilung"));
  const body = SAFE_BODY.has(n.kind) && n.body ? (en ? toEnglish(n.body) : n.body) : DETAILS[k];
  return { title, body };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const body = await req.json().catch(() => ({}));
    const k = await keys();
    if (body.action === "init") return json({ publicKey: k.public_key });

    const id = body.notification_id ?? body.record?.id;
    if (!id) return json({ ok: false, error: "notification_id fehlt" }, 400);
    // Jede Mitteilung genau einmal versenden
    const { data: n } = await sb.from("notifications").update({ pushed_at: new Date().toISOString() })
      .eq("id", id).is("pushed_at", null).select("id, recipient_id, kind, title, body, ref_type, ref_id").maybeSingle();
    if (!n) return json({ ok: true, skipped: true });

    const { data: subs } = await sb.from("push_subscriptions").select("endpoint, p256dh, auth").eq("player_id", n.recipient_id);
    webpush.setVapidDetails("mailto:info@padel-bros.de", k.public_key, k.private_key);
    const { data: who } = await sb.from("players").select("language").eq("id", n.recipient_id).maybeSingle();
    const en = who?.language === "en";
    const { title, body: text } = pushText(n, en);
    const payload = JSON.stringify({ title, body: text, tag: n.kind + ":" + (n.ref_id ?? n.id), url: "./?n=" + n.id });
    let sent = 0, removed = 0;
    for (const s of subs ?? []) {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400, urgency: "high" });
        sent++;
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) { await sb.from("push_subscriptions").delete().eq("endpoint", s.endpoint); removed++; }
        else console.error("Push fehlgeschlagen, Status", code ?? "unbekannt");   // keine Geräte- oder Personendaten im Protokoll
      }
    }
    return json({ ok: true, sent, removed });
  } catch (e) {
    console.error("Versandfehler", (e as Error)?.name ?? "Fehler");   // keine Inhalte im Protokoll
    return json({ ok: false }, 500);
  }
});
