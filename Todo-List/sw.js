/* =====================================================================
   sw.js — Service Worker
   ---------------------------------------------------------------------
   Strategy:
     - App shell (local files) is precached on install for offline use.
     - CDN libraries are cached at runtime (stale-while-revalidate-ish:
       cache-first with background update) so the app still works offline
       after the first online load.
     - All paths are RELATIVE so the app works at the site root OR in a
       subfolder (e.g. example.com/todo/). The SW is registered with
       { scope: './' } from app.js.
   Notes:
     - Background push / scheduled notifications when the app is fully
       closed are NOT reliably possible without a server. The 'notification'
       handlers below only help while the browser/SW is alive.
   ===================================================================== */

const VERSION = 'tasked-v1';
const SHELL_CACHE = `${VERSION}-shell`;
const RUNTIME_CACHE = `${VERSION}-runtime`;

// Local app-shell files (relative to the SW scope).
const SHELL_ASSETS = [
  './',
  './index.html',
  './style.css',
  './app.js',
  './manifest.json',
  './icons/icon-192.png',
  './icons/icon-512.png'
];

// ----- Install: precache the app shell -----
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(SHELL_CACHE).then((cache) => {
      // addAll fails the whole install if any file 404s; add individually
      // so a missing icon doesn't break offline support for everything else.
      return Promise.all(
        SHELL_ASSETS.map((url) =>
          cache.add(url).catch((err) => console.warn('[sw] precache skip', url, err))
        )
      );
    })
  );
  self.skipWaiting();
});

// ----- Activate: clean up old caches -----
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys
          .filter((k) => !k.startsWith(VERSION))
          .map((k) => caches.delete(k))
      )
    ).then(() => self.clients.claim())
  );
});

// ----- Fetch: serve shell from cache, runtime-cache the rest -----
self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);
  const isSameOrigin = url.origin === self.location.origin;

  // For navigations, serve cached index.html when offline (SPA fallback).
  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req).catch(() => caches.match('./index.html'))
    );
    return;
  }

  if (isSameOrigin) {
    // Cache-first for local assets.
    event.respondWith(
      caches.match(req).then((cached) => cached || fetchAndCache(req, SHELL_CACHE))
    );
  } else {
    // Cross-origin (CDN libs): cache-first with background refresh.
    event.respondWith(
      caches.match(req).then((cached) => {
        const network = fetchAndCache(req, RUNTIME_CACHE);
        return cached || network;
      })
    );
  }
});

function fetchAndCache(req, cacheName) {
  return fetch(req)
    .then((res) => {
      // Only cache valid responses (opaque responses are fine for CDNs).
      if (res && (res.ok || res.type === 'opaque')) {
        const copy = res.clone();
        caches.open(cacheName).then((cache) => cache.put(req, copy));
      }
      return res;
    })
    .catch(() => caches.match(req));
}

// ----- Messages from the page (e.g. show a notification) -----
self.addEventListener('message', (event) => {
  const data = event.data || {};
  if (data.type === 'SKIP_WAITING') self.skipWaiting();

  if (data.type === 'SHOW_NOTIFICATION' && self.registration.showNotification) {
    const { title, options } = data;
    self.registration.showNotification(title || 'Reminder', options || {});
  }
});

// ----- Notification click: focus or open the app -----
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clients) => {
      for (const client of clients) {
        if ('focus' in client) return client.focus();
      }
      if (self.clients.openWindow) return self.clients.openWindow('./');
    })
  );
});
