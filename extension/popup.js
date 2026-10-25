/* VaultMind — popup dell'estensione.
 *
 * Principi (gli stessi dell'app, non negoziabili):
 * - Il vault non si muove: qui non esiste una seconda copia. Le voci vivono
 *   in memoria SOLO finché il popup è aperto; chiuso il popup, il processo
 *   muore e con lui i dati. In chrome.storage sta il token di abbinamento —
 *   che non è una chiave del vault, è il permesso di chiedere all'app
 *   sbloccata, ed è revocabile dalle impostazioni dell'app — più tre
 *   preferenze (tema, privacy, pannello).
 * - App chiusa o vault bloccato = estensione cieca.
 * - La master password non passa MAI di qui.
 *
 * Lo stesso file fa da finestrella e da PANNELLO LATERALE (servizio.js
 * sceglie quale si apre). Il pannello cambia una cosa sola, ma grossa: non si
 * chiude più da sé, quindi «chiuso il popup, i dati muoiono» da solo non
 * basta più. Vedi `sorveglia()`.
 */

const BASE = "http://127.0.0.1:8731";
let TOKEN = null;
let ENTRIES = [];      // solo in RAM del popup

const $ = (s) => document.querySelector(s);

/* Siamo nel pannello laterale? Una finestrella a comparsa e' fra le viste di
 * tipo "popup"; il pannello no. Si decide qui, prima del primo disegno: la
 * finestrella ha una larghezza fissa, il pannello la prende da Chrome. */
const PANNELLO = !((chrome.extension && chrome.extension.getViews)
  ? chrome.extension.getViews({ type: "popup" }) : []).includes(window);
document.body.classList.toggle("pannello", PANNELLO);

/* Un'icona come stringa. I nomi sono quelli di design/icone.json; lo sprite
 * che li definisce sta in popup.html e lo scrive il generatore. La CSP di
 * MV3 vieta gli script in linea ma non tocca l'SVG. */
function ico(nome, cls) {
  return `<svg class="ic${cls ? " " + cls : ""}" aria-hidden="true"><use href="#i-${nome}"/></svg>`;
}

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
const VISTE = ["viewOff", "viewLocked", "viewPair", "viewMain"];

let VISTA = null;      // quella a schermo, o sotto le impostazioni

function show(id) {
  VISTA = id;
  VISTE.forEach(v => $("#" + v).classList.toggle("hidden", v !== id));
  $("#viewImpostazioni").classList.add("hidden");
}

const impostazioniAperte = () => !$("#viewImpostazioni").classList.contains("hidden");

/* ---------- tema ----------
 * Gli stessi tre dell'app e del telefono, con gli stessi nomi. La scelta sta
 * in chrome.storage insieme al token: e' una preferenza del browser, non un
 * dato del vault, e infatti non esce mai da qui.
 *
 * Le pastiglie di colore sono scritte a mano e non lette dal CSS: servono a
 * far riconoscere il tema PRIMA di sceglierlo, quindi devono mostrare i colori
 * di quel tema mentre sei ancora in un altro. */
const TEMI = [
  { id: "prisma",   nome: "Prisma",      fondo: "#04050E", neon: ["#8C7CFF", "#3CE2FF"] },
  { id: "ghiaccio", nome: "Ghiaccio",    fondo: "#E4E8F5", neon: ["#5440E6", "#006489"] },
  { id: "oro",      nome: "Notte e oro", fondo: "#03050C", neon: ["#E9A93A", "#FFD978"] },
];

/* I nomi di prima del 25/10/2026. Qui un tema si salvava solo scegliendolo,
 * quindi chi ha «night» l'ha voluto: resta Notte e oro, non va al
 * predefinito (sul telefono invece si salvava sempre, e la regola e' un'altra). */
const TEMI_VECCHI = { dark: "prisma", light: "ghiaccio", night: "oro" };

function temaValido(id) { return TEMI.some(t => t.id === id); }

/* ---------- privacy ----------
 * Accesa di default, e la scelta e' voluta: questo popup si apre sopra la
 * pagina che stai guardando, quindi il momento in cui compare e' proprio
 * quello in cui potresti non essere solo davanti allo schermo. Chi vuole i
 * valori in chiaro lo dice una volta, e resta cosi'. */
let PRIVACY = true;

async function caricaPrivacy() {
  // Assente = accesa: chi installa l'estensione oggi parte coperto.
  PRIVACY = (await chrome.storage.local.get("vm_privacy")).vm_privacy !== false;
}

async function cambiaPrivacy() {
  PRIVACY = !PRIVACY;
  await chrome.storage.local.set({ vm_privacy: PRIVACY });
  renderPrivacy();
  ridisegna();
}

function renderPrivacy() {
  const box = $("#privacy");
  box.innerHTML = "";
  const b = document.createElement("button");
  b.className = "tema" + (PRIVACY ? " sel" : "");
  const t = document.createElement("span");
  t.textContent = PRIVACY ? "Valori coperti" : "Valori in chiaro";
  const s = document.createElement("span");
  s.className = "segno";
  s.textContent = PRIVACY ? "ON" : "OFF";
  b.append(t, s);
  b.addEventListener("click", cambiaPrivacy);
  box.appendChild(b);
}

/* Ridisegna quello che e' gia' a schermo dopo un cambio di privacy: senza,
 * bisognerebbe richiudere e riaprire il popup per vedere l'effetto. */
function ridisegna() {
  ["#results", "#site"].forEach(sel => {
    const box = $(sel);
    if (box && box._ultimo) render(box._ultimo.list, box, box._ultimo.titolo);
  });
}

async function caricaTema() {
  let t = (await chrome.storage.local.get("vm_tema")).vm_tema;
  if (TEMI_VECCHI[t]) {
    t = TEMI_VECCHI[t];
    await chrome.storage.local.set({ vm_tema: t });
  }
  if (temaValido(t)) document.body.dataset.tema = t;
}

async function scegliTema(id) {
  if (!temaValido(id)) return;
  document.body.dataset.tema = id;
  await chrome.storage.local.set({ vm_tema: id });
  renderTemi();
}

function renderTemi() {
  const box = $("#temi");
  box.innerHTML = "";
  const attivo = document.body.dataset.tema;
  TEMI.forEach(t => {
    const b = document.createElement("button");
    b.className = "tema" + (t.id === attivo ? " sel" : "");
    const pall = document.createElement("span");
    pall.className = "pall";
    pall.style.background = t.fondo;
    const i = document.createElement("i");
    i.style.background = `linear-gradient(135deg,${t.neon[0]},${t.neon[1]})`;
    pall.appendChild(i);
    const nome = document.createElement("span");
    nome.textContent = t.nome;
    b.append(pall, nome);
    if (t.id === attivo) {
      const s = document.createElement("span");
      s.className = "segno";
      s.innerHTML = ico("spunta");
      b.appendChild(s);
    }
    b.addEventListener("click", () => scegliTema(t.id));
    box.appendChild(b);
  });
}

/* ---------- apertura ----------
 * Pannello laterale o finestrella: la scelta la applica servizio.js, che la
 * legge da chrome.storage. Senza pannello nel browser la riga non compare:
 * un interruttore che non cambia niente insegna solo a non fidarsi. */
async function renderApertura() {
  $("#sezApertura").classList.toggle("hidden", !chrome.sidePanel);
  if (!chrome.sidePanel) return;
  const acceso = (await chrome.storage.local.get("vm_pannello")).vm_pannello !== false;
  const box = $("#apertura");
  box.innerHTML = "";
  const b = document.createElement("button");
  b.className = "tema" + (acceso ? " sel" : "");
  const t = document.createElement("span");
  t.textContent = acceso ? "Pannello laterale" : "Finestrella a comparsa";
  const s = document.createElement("span");
  s.className = "segno";
  s.textContent = acceso ? "ON" : "OFF";
  b.append(t, s);
  b.addEventListener("click", async () => {
    await chrome.storage.local.set({ vm_pannello: !acceso });
    renderApertura();
  });
  box.appendChild(b);
}

/* Si torna alla vista da cui si e' entrati nelle impostazioni, che `VISTA`
 * ricorda. Senza, chiudendole da "vault bloccato" ci si ritrovava sulla
 * ricerca vuota. */
$("#impBtn").addEventListener("click", () => {
  VISTE.forEach(v => $("#" + v).classList.add("hidden"));
  $("#viewImpostazioni").classList.remove("hidden");
  renderTemi();
  renderPrivacy();
  renderApertura();
});

$("#impChiudi").addEventListener("click", () => {
  $("#viewImpostazioni").classList.add("hidden");
  $("#" + (VISTA || "viewMain")).classList.remove("hidden");
  // Nel frattempo il vault puo' essere stato sbloccato: il giro di
  // sorveglianza aspettava che le impostazioni si chiudessero.
  if (PANNELLO) sorveglia();
});

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
let AVVIO = null;   // un avvio alla volta: il pannello lo chiede anche da solo

function init() {
  if (!AVVIO) AVVIO = avvia().finally(() => { AVVIO = null; });
  return AVVIO;
}

async function avvia() {
  await caricaTema();
  await caricaPrivacy();
  TOKEN = (await chrome.storage.local.get("vm_token")).vm_token || null;
  $("#stato").textContent = "";
  if (!TOKEN) { show("viewPair"); return; }

  let st;
  try {
    st = await apiFetch("/api/status");
  } catch (e) {
    cieco("viewOff"); return;                     // porta chiusa: app non aperta
  }
  if (st.status === 401 || st.status === 403) {
    // token revocato dall'app (o abbinamento rifatto): si torna al codice
    await chrome.storage.local.remove("vm_token");
    TOKEN = null;
    show("viewPair");
    $("#pairMsg").textContent = "L'abbinamento non è più valido: rifallo dall'app.";
    return;
  }
  if (!st.j.unlocked) { cieco("viewLocked"); return; }

  show("viewMain");
  await caricaVoci();
  // Il pannello si riapre anche da solo, mentre scrivi in una pagina: li'
  // prendersi il cursore vorrebbe dire rubarti il campo che stai compilando.
  if (!PANNELLO || document.hasFocus()) $("#q").focus();
}

let CARICATE = 0;    // quando sono arrivate le voci, per il pannello

async function caricaVoci() {
  const r = await apiFetch("/api/list");
  if (!r.ok) { ENTRIES = []; return; }
  ENTRIES = r.j.entries || [];
  CARICATE = Date.now();
  $("#stato").textContent = ENTRIES.length + " voci";
  await mostraSito();
  // Una ricerca in corso non si butta via: si aggiorna al prossimo tasto.
  if (!$("#q").value.trim()) render(ENTRIES, $("#results"), "Tutte le voci");
}

/* ---------- il pannello ----------
 * La finestrella si chiude da sola, e con lei le voci. Il pannello no: puo'
 * restare aperto per ore accanto a qualsiasi pagina. Quindi ogni pochi
 * secondi si chiede all'app se il vault e' ancora aperto, e quando non lo e'
 * (bloccato dall'inattivita', a mano, o app chiusa) le voci si cancellano
 * dalla memoria e dallo schermo, come se il pannello fosse stato chiuso.
 *
 * Questa domanda NON tiene sveglio il vault: l'auto-blocco dell'app conta i
 * tocchi nella sua finestra (resetAutolock in index.html), non le chiamate.
 * Altrimenti un pannello aperto avrebbe tenuto il vault aperto per sempre.
 *
 * Al contrario, quando il vault si riapre il pannello se ne accorge e torna
 * da solo: chi l'ha lasciato aperto non deve ricordarsi di ricaricarlo. */
function cieco(vista) {
  ENTRIES = [];
  ["#results", "#site"].forEach(sel => { const b = $(sel); b.innerHTML = ""; b._ultimo = null; });
  $("#q").value = "";
  $("#stato").textContent = "";
  if (impostazioniAperte()) VISTA = vista;   // ci si torna chiudendole
  else show(vista);
}

async function sorveglia() {
  if (AVVIO || !TOKEN) return;   // si sta gia' chiedendo, o manca l'abbinamento
  let st;
  try {
    st = await apiFetch("/api/status");
  } catch (e) {
    if (VISTA !== "viewOff") cieco("viewOff");
    return;
  }
  if (st.status === 401 || st.status === 403) { cieco("viewPair"); init(); return; }
  if (!st.j.unlocked) {
    if (VISTA !== "viewLocked") cieco("viewLocked");
    return;
  }
  if (VISTA !== "viewMain" && !impostazioniAperte()) init();
}

if (PANNELLO) {
  setInterval(sorveglia, 4000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) sorveglia(); });
  // Tornando nel pannello dopo aver lavorato nell'app, le voci nuove ci
  // sono: si ricaricano quando ci si rientra, non a ogni giro.
  window.addEventListener("focus", () => {
    if (VISTA === "viewMain" && !AVVIO && Date.now() - CARICATE > 5000) caricaVoci();
  });
  // «Per questo sito» segue la scheda che hai davanti: cambiandola, o
  // cambiando pagina dentro di lei.
  chrome.tabs.onActivated.addListener(() => { if (VISTA === "viewMain") mostraSito(); });
  chrome.tabs.onUpdated.addListener((id, info, tab) => {
    if (VISTA === "viewMain" && tab.active && (info.url || info.status === "complete")) mostraSito();
  });
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
  box._ultimo = null;
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
  box._ultimo = { list, titolo };   // per ridisegnare al cambio di privacy
  box.innerHTML = "";
  if (!list.length) return;
  const h = document.createElement("div");
  h.className = "sez"; h.textContent = titolo;
  box.appendChild(h);
  list.slice(0, 60).forEach(e => box.appendChild(cardVoce(e)));
}

/* Lunghezza vera fino a 14 pallini, come nell'app: una fila sempre uguale
 * farebbe sembrare identiche due password diverse. */
const pallini = (v) => "•".repeat(Math.min(v.length, 14));

/* L'occhio si richiude da solo dopo 15 secondi, come nell'app. Un valore
 * lasciato scoperto in un popup che resta aperto e' esattamente la cosa che
 * la Privacy doveva evitare. */
function bottoneOcchio(vEl, valore) {
  const b = document.createElement("button");
  b.className = "ico";
  b.setAttribute("aria-label", "Mostra o nascondi");
  b.innerHTML = ico("occhio");
  b.title = "Mostra";
  let visibile = false, timer = null;
  b.addEventListener("click", () => {
    visibile = !visibile;
    vEl.textContent = visibile ? valore : pallini(valore);
    vEl.classList.toggle("visibile", visibile);
    clearTimeout(timer);
    if (visibile) timer = setTimeout(() => {
      visibile = false;
      vEl.textContent = pallini(valore);
      vEl.classList.remove("visibile");
    }, 15000);
  });
  return b;
}

function bottoneCopia(valore, etichetta) {
  const b = document.createElement("button");
  b.className = "ico";
  b.setAttribute("aria-label", "Copia");
  b.innerHTML = ico("copia");
  b.title = "Copia";
  b.addEventListener("click", async () => {
    await copia(valore, etichetta);
    b.innerHTML = ico("spunta");
    b.style.color = "var(--ok)";
    setTimeout(() => { b.innerHTML = ico("copia"); b.style.color = ""; }, 4000);
  });
  return b;
}

function bottoneOtp(voce) {
  const b = document.createElement("button");
  b.className = "cp";
  b.textContent = "Codice 2FA";
  b.addEventListener("click", async () => {
    const r = await apiFetch("/api/totp", { cred_id: voce.id });
    const primo = ((r.j || {}).otp || []).find(o => o.code);
    if (primo) await copia(primo.code, "Codice 2FA (" + primo.remaining + "s)");
    else toast("Secret 2FA non valido");
  });
  return b;
}

function cardVoce(e) {
  const c = document.createElement("div");
  c.className = "card";
  c.innerHTML = `<div class="tit">${e.critical ? '<span class="star" title="Voce critica">'+ico("scudo-ok")+"</span>" : ""}${esc(e.title)}</div>`;
  (e.fields || []).forEach(f => {
    const valore = (f.value || "").trim();
    if (!valore) return;
    const otp = OTP.test(f.label || "");
    // Con la Privacy accesa si copre TUTTO, non solo le password: il popup si
    // apre sopra una pagina qualsiasi, e capita di averlo aperto mentre si
    // condivide lo schermo o con qualcuno alle spalle.
    const coperto = otp || PRIVACY || SEGRETO.test(f.label || "");

    const row = document.createElement("div");
    row.className = "frow";
    const lab = document.createElement("span");
    lab.className = "lab";
    lab.title = f.label || "";
    lab.textContent = f.label || "";
    const v = document.createElement("span");
    v.className = "val";
    v.textContent = coperto ? pallini(valore) : valore;
    row.append(lab, v);

    // Niente occhio sull'OTP: li' il valore coperto e' il SEGRETO, e vederlo
    // non serve a nessuno — il codice si prende col pulsante accanto.
    if (coperto && !otp) row.appendChild(bottoneOcchio(v, valore));
    row.appendChild(otp ? bottoneOtp(e) : bottoneCopia(valore, f.label));
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
