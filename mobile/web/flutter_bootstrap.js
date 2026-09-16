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
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('sw.js').catch(function () {});
}
