/* =========================================================================
   月班表管理系統 —— Service Worker（背景小幫手）
   把它想成 App 的「倉管」：
     - 平常：先去 GitHub 拿最新的網頁，拿不到（離線）才用倉庫裡的備份
     - 程式庫（PDF、Excel、Firebase）：先用倉庫裡的，同時背景補貨
     - 雲端資料（Firestore 讀寫）：一律直接連線，不經過倉庫，確保資料是最新的
   發布新版時：把下面的 VERSION 改掉（並同步改 index.html 的 APP_VERSION），
   使用者的 App 就會偵測到「有新版本」並出現更新提示。
   ========================================================================= */

const VERSION = '2026.10.31.2';
const CACHE = 'rcw-month-' + VERSION;

// App 本體：安裝時先放進倉庫，離線也能開啟
const CORE_FILES = [
  './',
  './index.html',
  './manifest.webmanifest',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/icon-maskable-512.png',
  './icons/apple-touch-icon.png'
];

// 外部程式庫與字型的網域：先用快取，背景更新
const LIBRARY_HOSTS = [
  'cdnjs.cloudflare.com',
  'www.gstatic.com',
  'fonts.googleapis.com',
  'fonts.gstatic.com'
];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(CORE_FILES)));
  // 不自動 skipWaiting：等使用者在畫面上按「立即更新」才切換，避免編輯到一半被換版
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter((k) => k.startsWith('rcw-month-') && k !== CACHE).map((k) => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('message', (event) => {
  const data = event.data || {};
  if (data.type === 'SKIP_WAITING') self.skipWaiting();
  if (data.type === 'GET_VERSION' && event.ports[0]) event.ports[0].postMessage({ version: VERSION });
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  // 1. 網頁本體：網路優先（拿最新版），離線時才用快取
  if (req.mode === 'navigate' || (url.origin === self.location.origin && url.pathname.endsWith('.html'))) {
    event.respondWith((async () => {
      try {
        const fresh = await fetch(req, { cache: 'no-cache' });
        if (fresh.ok) {
          const cache = await caches.open(CACHE);
          cache.put('./index.html', fresh.clone());
        }
        return fresh;
      } catch (err) {
        return (await caches.match(req)) || (await caches.match('./index.html'));
      }
    })());
    return;
  }

  // 2. 同網域的其他檔案（圖示、manifest）：快取優先
  if (url.origin === self.location.origin) {
    event.respondWith(caches.match(req).then((hit) => hit || fetch(req)));
    return;
  }

  // 3. 外部程式庫：先用快取，背景補貨（stale-while-revalidate）
  if (LIBRARY_HOSTS.includes(url.hostname)) {
    event.respondWith((async () => {
      const cache = await caches.open(CACHE);
      const hit = await cache.match(req);
      const refresh = fetch(req).then((res) => {
        if (res && (res.ok || res.type === 'opaque')) cache.put(req, res.clone());
        return res;
      }).catch(() => hit);
      return hit || refresh;
    })());
    return;
  }

  // 4. 其他（Firebase 登入、Firestore 雲端資料）：不攔截，直接連線
});
