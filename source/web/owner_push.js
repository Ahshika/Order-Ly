// إشعارات أبلكيشن المالك (Web Push). Dart بيكلّمها من lib/src/owner/owner_push_web.dart.
// الأيفون: الإشعارات للنسخة اللي على الشاشة الرئيسية بس (iOS 16.4+). أندرويد (Chrome): من المتصفح أو الأيقونة.
(function () {
  function isIos() { return /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1); }
  function standalone() { return window.navigator.standalone === true || window.matchMedia('(display-mode: standalone)').matches; }
  function keyBytes(b64) {
    var s = b64.replace(/-/g, '+').replace(/_/g, '/'); while (s.length % 4) s += '=';
    var raw = atob(s), out = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
    return out;
  }
  window.orderlyPush = {
    supported: function () { return 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window; },
    needsHomeScreen: function () { return isIos() && !standalone(); },
    subscribe: async function (vapidPublicKey) {
      var reg = await navigator.serviceWorker.register('push-sw.js', { scope: './' });
      await navigator.serviceWorker.ready;
      var permission = await Notification.requestPermission();
      if (permission !== 'granted') throw new Error('permission ' + permission);
      var sub = await reg.pushManager.getSubscription();
      if (sub) {
        // مفتاح الفرع الرئيسي اتغير: اشتراك جديد
        var old = sub.options && sub.options.applicationServerKey;
        if (old && btoa(String.fromCharCode.apply(null, new Uint8Array(old))) !== btoa(String.fromCharCode.apply(null, keyBytes(vapidPublicKey)))) { await sub.unsubscribe(); sub = null; }
      }
      if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(vapidPublicKey) });
      return JSON.stringify(sub.toJSON());
    },
  };
})();
