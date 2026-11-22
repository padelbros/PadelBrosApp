// PadelBros App – Service Worker
// Speichert nur die App-Hülle (Seite, Icons, Bibliothek) für schnelles Öffnen.
// Daten aus Supabase (Spieler, Aufgaben, Mitteilungen) werden NIE zwischengespeichert.
const CACHE = "pb-app-v23";
const SHELL = ["./", "./index.html", "./config.js", "./pwa.js", "./manifest.webmanifest", "./icons/icon-192.png", "./icons/icon-512.png"];
self.addEventListener("install", e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL))); self.skipWaiting(); });
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(k => Promise.all(k.filter(x => x !== CACHE).map(x => caches.delete(x)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", e => {
  const u = new URL(e.request.url);
  if (e.request.method !== "GET") return;
  const shell = u.origin === location.origin || (u.hostname === "cdn.jsdelivr.net" && u.pathname.includes("supabase-js"));
  if (!shell) return;                                   // alles andere, v. a. Supabase-Daten: direkt aus dem Netz
  e.respondWith(fetch(e.request).then(r => {             // erst Netz (immer aktuell), sonst Zwischenspeicher
    if (r.ok) { const copy = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); }
    return r;
  }).catch(() => caches.match(e.request).then(r => r
    || (e.request.mode === "navigate" ? caches.match("./index.html") : Response.error()))));   // Startseite nur für Seitenaufrufe
});
// Push-Nachrichten (werden im nächsten Schritt angeschlossen)
self.addEventListener("push", e => {
  const d = e.data ? e.data.json() : {};
  e.waitUntil(self.registration.showNotification(d.title || "PadelBros", {
    body: d.body || "", icon: "icons/icon-192.png", badge: "icons/badge-96.png", tag: d.tag, data: { url: d.url || "./" } }));
});
self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = new URL(e.notification.data?.url || "./", self.registration.scope).href;
  e.waitUntil(clients.matchAll({ type: "window", includeUncontrolled: true }).then(async ws => {
    for (const w of ws) if ("focus" in w) { try { await w.navigate(url); } catch (_) {} return w.focus(); }
    return clients.openWindow(url);
  }));
});
