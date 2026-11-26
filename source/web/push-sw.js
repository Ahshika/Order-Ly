// إشعارات المالك: كمبيوتر الكافيه بيبعتها (lib/src/server/web_push.dart) عن طريق Apple/Google، وده بيعرضها.
// لازم كل رسالة تتعرض (Apple بيوقف الإشعارات لو رسالة وصلت ومااتعرضتش).
self.addEventListener('push', function (event) {
  var d = {};
  try { d = event.data ? event.data.json() : {}; } catch (e) { d = { body: event.data ? event.data.text() : '' }; }
  event.waitUntil(self.registration.showNotification(d.title || 'Order Ly', {
    body: d.body || '',
    icon: 'icons/Icon-192.png',
    badge: 'icons/Icon-192.png',
    tag: d.tag,
    lang: 'ar',
    dir: 'rtl',
    data: { url: d.url || './' },
  }));
});

self.addEventListener('notificationclick', function (event) {
  event.notification.close();
  var url = new URL((event.notification.data && event.notification.data.url) || './', self.registration.scope).href;
  event.waitUntil(clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (windows) {
    for (var i = 0; i < windows.length; i++) {
      if (windows[i].url.indexOf(self.registration.scope) === 0 && 'focus' in windows[i]) { windows[i].navigate(url); return windows[i].focus(); }
    }
    return clients.openWindow(url);
  }));
});
