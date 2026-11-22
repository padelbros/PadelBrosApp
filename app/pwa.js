// PadelBros App – Installation und Service Worker
(function () {
  if ("serviceWorker" in navigator) window.addEventListener("load", () => navigator.serviceWorker.register("sw.js").catch(console.error));
  const installed = matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;
  if (installed) return;
  let later = false; try { later = localStorage.getItem("pb-install-later") === "1"; } catch (e) {}
  if (later) return;
  const ios = /iphone|ipad|ipod/i.test(navigator.userAgent) && !/crios|fxios/i.test(navigator.userAgent);
  let prompt = null;
  const css = document.createElement("style");
  css.textContent = `#pb-install{position:fixed;left:12px;right:12px;bottom:calc(12px + env(safe-area-inset-bottom,0px));z-index:2147482000;
    background:#111;color:#fff;border-radius:18px;padding:14px 16px;display:flex;gap:12px;align-items:center;font:500 15px/1.35 Barlow,system-ui,sans-serif;box-shadow:0 10px 30px rgba(0,0,0,.25)}
    #pb-install img{width:44px;height:44px;border-radius:10px;flex:none;background:#fff}
    #pb-install b{display:block;font-size:16px}
    #pb-install button{appearance:none;border:0;border-radius:999px;padding:9px 14px;font:700 15px Barlow,system-ui,sans-serif;cursor:pointer}
    #pb-install .go{background:#C6693A;color:#fff}#pb-install .x{background:transparent;color:#bbb;padding:9px 6px}`;
  document.head.appendChild(css);
  function show(text, withButton) {
    if (document.getElementById("pb-install")) return;
    const d = document.createElement("div"); d.id = "pb-install"; d.setAttribute("role", "dialog"); d.setAttribute("aria-label", "App installieren");
    d.innerHTML = `<img src="icons/icon-192.png" alt=""><div style="flex:1"><b>PadelBros als App</b>${text}</div>
      ${withButton ? '<button class="go" type="button">Installieren</button>' : ""}<button class="x" type="button" aria-label="Später">✕</button>`;
    document.body.appendChild(d);
    d.querySelector(".x").onclick = () => { d.remove(); try { localStorage.setItem("pb-install-later", "1"); } catch (e) {} };
    const go = d.querySelector(".go");
    if (go) go.onclick = async () => { d.remove(); prompt.prompt(); await prompt.userChoice; prompt = null; };
  }
  window.addEventListener("beforeinstallprompt", e => { e.preventDefault(); prompt = e; show("Aufs Handy legen – öffnet wie eine App.", true); });
  if (ios) setTimeout(() => show('Tippe unten auf <b style="display:inline">Teilen</b> und dann auf <b style="display:inline">„Zum Home-Bildschirm“</b>.', false), 1500);
})();
