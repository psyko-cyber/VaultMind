// VaultMind: il service worker che fa funzionare l'app senza rete.
//
// Scritto a mano e non quello di Flutter, che dalla 3.2x si limita a
// disinstallarsi. Cosa fa, e perche':
//
// - All'installazione mette in cache TUTTI i file dell'app, elencati da
//   pubblica_web.ps1 con l'impronta SHA-256 di ciascuno (vedi IMPRONTE). Da li'
//   in poi l'app si apre anche in aereo.
// - Ogni file scaricato si CONFRONTA con la sua impronta. Il 16/09/2026 la CDN
//   di GitHub Pages ha servito per diversi minuti il main.dart.js vecchio
//   insieme al sw.js nuovo: senza il confronto, la versione nuova avrebbe
//   messo in cache il codice vecchio e ce lo avrebbe tenuto. Se un file non
//   torna, l'installazione fallisce e il browser riprova alla prossima
//   apertura; intanto resta la versione di prima, intera.
// - Una versione verificata si attiva SUBITO (skipWaiting). Fino al 16/09 si
//   aspettava che l'utente chiudesse ogni scheda: Luca ha ricaricato la pagina
//   piu' volte vedendo sempre la vecchia, e su iPhone un'app sulla Home non si
//   chiude mai davvero. La pagina gia' aperta non si ricarica da sola -- ci
//   potrebbe essere una password a meta' -- ma lo dice (flutter_bootstrap.js).
// - Non tocca mai il vault: sta nella memoria del sito (deposito_web.dart),
//   non nella cache. Cancellare la cache non cancella le password.
'use strict';

const VERSIONE = '__VERSIONE__';
const CACHE = 'vaultmind-' + VERSIONE;
const IMPRONTE = __IMPRONTE__;

async function impronta(buffer) {
  const h = await crypto.subtle.digest('SHA-256', buffer);
  return Array.from(new Uint8Array(h), (b) => b.toString(16).padStart(2, '0')).join('');
}

self.addEventListener('install', (evento) => {
  evento.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    try {
      await Promise.all(Object.entries(IMPRONTE).map(async ([file, attesa]) => {
        // ?v= fa chiedere alla CDN un indirizzo che non ha mai visto, e
        // cache: 'reload' salta la cache del browser. Si salva sotto il nome
        // vero, quello che l'app chiedera'.
        const risposta = await fetch(new Request(file + '?v=' + VERSIONE, { cache: 'reload' }));
        if (!risposta.ok) throw new Error(file + ': HTTP ' + risposta.status);
        const corpo = await risposta.arrayBuffer();
        if (await impronta(corpo) !== attesa) {
          throw new Error(file + ': non e\' il file pubblicato con questa versione');
        }
        await cache.put(file, new Response(corpo, {
          headers: { 'Content-Type': risposta.headers.get('Content-Type') || '' },
        }));
      }));
    } catch (errore) {
      // Una cache a meta' non deve restare in giro a sembrare buona.
      await caches.delete(CACHE);
      throw errore;
    }
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (evento) => {
  evento.waitUntil((async () => {
    for (const nome of await caches.keys()) {
      if (nome.startsWith('vaultmind-') && nome !== CACHE) await caches.delete(nome);
    }
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (evento) => {
  const richiesta = evento.request;
  if (richiesta.method !== 'GET') return;
  if (new URL(richiesta.url).origin !== self.location.origin) return;
  evento.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const trovata = await cache.match(richiesta, { ignoreSearch: true });
    if (trovata) return trovata;
    if (richiesta.mode === 'navigate') {
      const pagina = await cache.match('./');
      if (pagina) return pagina;
    }
    return fetch(richiesta);
  })());
});
