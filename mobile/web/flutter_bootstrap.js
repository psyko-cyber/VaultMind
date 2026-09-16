{{flutter_js}}
{{flutter_build_config}}

// Avvio di VaultMind nel browser.
//
// fontFallbackBaseUrl: per i caratteri che i nostri font non hanno (emoji,
// alfabeti non latini) Flutter li scaricherebbe da fonts.gstatic.com. Qui
// punta a una cartella nostra che non esiste: il carattere esce come un
// quadratino, ma nessuno fuori sa che VaultMind e' stata aperta. La CSP in
// index.html lo bloccherebbe comunque.
_flutter.loader.load({
  onEntrypointLoaded: async function (motore) {
    const app = await motore.initializeEngine({
      fontFallbackBaseUrl: 'font-mancanti/',
    });
    await app.runApp();
    const carica = document.getElementById('carica');
    if (carica) carica.remove();
  },
});

// Il service worker tiene l'app in memoria: dalla seconda apertura funziona
// senza rete. Vedi sw.js.
//
// Quando una versione nuova prende il posto di quella che gira, questa pagina
// resta la vecchia: non la si ricarica da sola, perche' qualcuno potrebbe star
// scrivendo una password. Si alza una bandiera che l'app legge
// (ponte_web.dart) per offrire "aggiorna" sulla schermata di sblocco.
// Alla primissima installazione non c'e' niente da annunciare: la pagina era
// gia' l'ultima versione.
if ('serviceWorker' in navigator) {
  var eraControllata = !!navigator.serviceWorker.controller;
  navigator.serviceWorker.addEventListener('controllerchange', function () {
    if (!eraControllata) return;
    window.vaultmindAggiornamentoPronto = true;
    window.dispatchEvent(new Event('vaultmind-aggiornamento'));
  });
  navigator.serviceWorker.register('sw.js').catch(function () {});
}
