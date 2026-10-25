/* VaultMind - il lavoratore di fondo dell'estensione.
 *
 * Fa una cosa sola: decide che cosa si apre toccando l'icona.
 *
 * Il PANNELLO LATERALE (Chrome 114 e successivi) resta aperto accanto alla
 * pagina mentre la si compila. La finestrella a comparsa si chiude al primo
 * clic fuori: per copiare utente e password in un modulo bisognava riaprirla
 * per ogni campo, ed e' il motivo per cui il pannello e' nato (25/10/2026).
 * La finestrella resta per chi la preferisce (Impostazioni dell'estensione)
 * e per i browser che il pannello non lo hanno: nel manifest c'e' ancora
 * `default_popup`, ed e' QUI che si toglie quando il pannello e' acceso.
 * Se questo file non partisse, l'estensione funzionerebbe come prima.
 *
 * Qui non passa nessun dato del vault: non chiama l'app e non tiene niente
 * in memoria. Un service worker lo sveglia e lo spegne Chrome quando vuole,
 * e un dato tenuto qui sopravviverebbe al pannello che lo ha chiesto.
 */

async function applica() {
  const { vm_pannello } = await chrome.storage.local.get("vm_pannello");
  // Assente = acceso: e' quello che chi installa oggi si aspetta.
  const pannello = !!chrome.sidePanel && vm_pannello !== false;
  if (chrome.sidePanel) {
    await chrome.sidePanel
      .setPanelBehavior({ openPanelOnActionClick: pannello })
      .catch(() => {});
  }
  // Una finestrella impostata vince sul pannello: va tolta, non solo
  // affiancata.
  await chrome.action.setPopup({ popup: pannello ? "" : "popup.html" });
}

chrome.runtime.onInstalled.addListener(applica);
chrome.runtime.onStartup.addListener(applica);
chrome.storage.onChanged.addListener((cambi, area) => {
  if (area === "local" && "vm_pannello" in cambi) applica();
});
applica();
