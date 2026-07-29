/* VaultMind — popup dell'estensione.
 *
 * Principi (gli stessi dell'app, non negoziabili):
 * - Il vault non si muove: qui non esiste una seconda copia. Le voci vivono
 *   in memoria SOLO finché il popup è aperto; chiuso il popup, il processo
 *   muore e con lui i dati. In chrome.storage sta un'unica cosa: il token di
 *   abbinamento — che non è una chiave del vault, è il permesso di chiedere
 *   all'app sbloccata, ed è revocabile dalle impostazioni dell'app.
 * - App chiusa o vault bloccato = estensione cieca.
 * - La master password non passa MAI di qui.
 */

const BASE = "http://127.0.0.1:8731";
let TOKEN = null;
let ENTRIES = [];      // solo in RAM del popup

const $ = (s) => document.querySelector(s);

/* ---------- API ---------- */
async function apiFetch(path, body) {
  const opts = { headers: { "X-VaultMind-Token": TOKEN || "" } };
  if (body !== undefined) {
    opts.method = "POST";
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  const r = await fetch(BASE + path, opts);
  return { ok: r.ok, status: r.status, j: await r.json().catch(() => ({})) };
}

/* ---------- viste ---------- */
function show(id) {
  ["viewOff", "viewLocked", "viewPair", "viewMain"].forEach(v =>
    $("#" + v).classList.toggle("hidden", v !== id));
}

function toast(msg) {
  const t = $("#toast");
  t.textContent = msg;
  t.classList.remove("hidden");
  setTimeout(() => t.classList.add("hidden"), 1400);
}

async function copia(v, label) {
  try {
    await navigator.clipboard.writeText(v);
    toast((label || "Valore") + " copiato");
  } catch (e) {
    toast("Copia non riuscita");
  }
}

/* ---------- avvio ---------- */
async function init() {
  TOKEN = (await chrome.storage.local.get("vm_token")).vm_token || null;
  $("#stato").textContent = "";
  if (!TOKEN) { show("viewPair"); return; }

  let st;
  try {
    st = await apiFetch("/api/status");
  } catch (e) {
    show("viewOff"); return;                      // porta chiusa: app non aperta
  }
  if (st.status === 401 || st.status === 403) {
    // token revocato dall'app (o abbinamento rifatto): si torna al codice
    await chrome.storage.local.remove("vm_token");
    TOKEN = null;
    show("viewPair");
    $("#pairMsg").textContent = "L'abbinamento non è più valido: rifallo dall'app.";
    return;
  }
  if (!st.j.unlocked) { show("viewLocked"); return; }

  show("viewMain");
  await caricaVoci();
  $("#q").focus();
}

async function caricaVoci() {
  const r = await apiFetch("/api/list");
  if (!r.ok) { ENTRIES = []; return; }
  ENTRIES = r.j.entries || [];
  $("#stato").textContent = ENTRIES.length + " voci";
  await mostraSito();
  render(ENTRIES, $("#results"), "Tutte le voci");
}

/* ---------- voci del sito corrente ----------
 * L'abbinamento è al DOMINIO del campo URL salvato nella voce, mai al solo
 * titolo: è la base (voluta) su cui poggerà anche il futuro autofill. */
function hostDi(v) {
  try { return new URL(/^https?:\/\//i.test(v) ? v : "https://" + v).hostname.toLowerCase().replace(/^www\./, ""); }
  catch (e) { return null; }
}
function campiUrl(e) {
  return (e.fields || []).filter(f =>
    /^(url|sito|link|indirizzo|website|web)$/i.test((f.label || "").trim()) ||
    /^https?:\/\//i.test((f.value || "").trim()));
}
async function mostraSito() {
  const box = $("#site");
  box.innerHTML = "";
  let tab;
  try { [tab] = await chrome.tabs.query({ active: true, currentWindow: true }); } catch (e) { return; }
  if (!tab || !tab.url || !/^https?:/i.test(tab.url)) return;
  const host = hostDi(tab.url);
  if (!host) return;
  const del_sito = ENTRIES.filter(e => campiUrl(e).some(f => hostDi(f.value) === host));
  if (del_sito.length) render(del_sito, box, "Per questo sito · " + host);
}

/* ---------- rendering ---------- */
const SEGRETO = /pass|pin|secret|chiave|key|token|codice/i;
const OTP = /otp|2fa|totp|autenticat/i;

function esc(s) { return String(s == null ? "" : s).replace(/[&<>"]/g, m => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[m])); }

function render(list, box, titolo) {
  box.innerHTML = "";
  if (!list.length) return;
  const h = document.createElement("div");
  h.className = "sez"; h.textContent = titolo;
  box.appendChild(h);
  list.slice(0, 60).forEach(e => box.appendChild(cardVoce(e)));
}

function cardVoce(e) {
  const c = document.createElement("div");
  c.className = "card";
  c.innerHTML = `<div class="tit">${e.critical ? '<span class="star">★</span>' : ""}${esc(e.title)}</div>`;
  (e.fields || []).forEach(f => {
    if (!(f.value || "").trim()) return;
    const otp = OTP.test(f.label || "");
    const segreto = !otp && SEGRETO.test(f.label || "");
    const row = document.createElement("div");
    row.className = "frow";
    row.innerHTML = `<span class="lab" title="${esc(f.label)}">${esc(f.label)}</span>
                     <span class="val">${segreto || otp ? "••••••••" : esc(f.value)}</span>`;
    const b = document.createElement("button");
    b.className = "cp";
    if (otp) {
      b.textContent = "Codice 2FA";
      b.onclick = async () => {
        const r = await apiFetch("/api/totp", { cred_id: e.id });
        const primo = ((r.j || {}).otp || []).find(o => o.code);
        if (primo) { await copia(primo.code, "Codice 2FA (" + primo.remaining + "s)"); }
        else toast("Secret 2FA non valido");
      };
    } else {
      b.textContent = "Copia";
      b.onclick = () => copia(f.value, f.label);
    }
    row.appendChild(b);
    c.appendChild(row);
  });
  return c;
}

/* ---------- ricerca ----------
 * Mentre scrivi: filtro locale immediato su titoli e tag.
 * Invio: la ricerca vera dell'app — embedding + coseno, deterministica.
 * In entrambi i casi il match è TROVATO, mai generato. */
$("#q").addEventListener("input", () => {
  const q = $("#q").value.trim().toLowerCase();
  if (!q) { render(ENTRIES, $("#results"), "Tutte le voci"); return; }
  const hit = ENTRIES.filter(e =>
    (e.title || "").toLowerCase().includes(q) ||
    (e.tags || []).some(t => String(t).toLowerCase().includes(q)));
  render(hit, $("#results"), "Risultati");
});

$("#q").addEventListener("keydown", async (ev) => {
  if (ev.key !== "Enter") return;
  const q = $("#q").value.trim();
  if (!q) return;
  const box = $("#results");
  box.innerHTML = '<div class="reply">Cerco…</div>';
  const r = await apiFetch("/api/query", { text: q });
  if (!r.ok) { box.innerHTML = '<div class="reply">' + esc(r.j.detail || "Errore.") + "</div>"; return; }
  const j = r.j;
  if (j.kind === "single") {
    render(j.results, box, "Trovata");
  } else if (j.kind === "ambiguous") {
    // le voci ambigue arrivano senza valori: si aprono con /api/reveal
    box.innerHTML = '<div class="reply">' + esc(j.reply || "Quale intendevi?") + "</div>";
    const wrap = document.createElement("div");
    j.results.forEach(v => {
      const b = document.createElement("button");
      b.className = "ghost";
      b.textContent = v.title;
      b.onclick = async () => {
        const rr = await apiFetch("/api/reveal", { text: String(v.id) });
        if (rr.ok) { box.innerHTML = ""; box.appendChild(cardVoce(rr.j)); }
      };
      wrap.appendChild(b);
    });
    box.appendChild(wrap);
  } else {
    box.innerHTML = '<div class="reply">' + esc(j.reply || "Nessuna corrispondenza.") + "</div>";
  }
});

/* ---------- abbinamento ---------- */
function nomeBrowser() {
  const brands = (navigator.userAgentData && navigator.userAgentData.brands || []).map(b => b.brand).join(" ");
  if (/Edge/i.test(brands)) return "VaultMind per Edge";
  if (/Brave/i.test(brands)) return "VaultMind per Brave";
  return "VaultMind per Chrome";
}

$("#pairBtn").onclick = async () => {
  const code = $("#pairCode").value.trim();
  $("#pairMsg").textContent = "";
  if (!/^\d{6}$/.test(code)) { $("#pairMsg").textContent = "Il codice ha 6 cifre."; return; }
  let r;
  try {
    r = await fetch(BASE + "/api/pair/claim", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code, name: nomeBrowser() }),
    }).then(async (x) => ({ ok: x.ok, j: await x.json().catch(() => ({})) }));
  } catch (e) {
    $("#pairMsg").textContent = "VaultMind non risponde: l'app è aperta?";
    return;
  }
  if (!r.ok) { $("#pairMsg").textContent = r.j.detail || "Abbinamento non riuscito."; return; }
  await chrome.storage.local.set({ vm_token: r.j.token });
  init();
};
$("#pairCode").addEventListener("keydown", (e) => { if (e.key === "Enter") $("#pairBtn").click(); });

$("#retryOff").onclick = init;
$("#retryLocked").onclick = init;

init();
