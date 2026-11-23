# محل جديد على مشروع Firebase خاص بيه

> ليه؟ حدود Firebase المجانية (360 ميجا تحميل في اليوم، و100 اتصال في نفس اللحظة) **لكل مشروع لوحده**.
> المحل اللي له مشروع بتاعه مابيقاسمش حد الحدود دي. صفحة منيو العملاء بتفضل واحدة لكل المحلات على المشروع الأساسي `orderly-yvzug`،
> وبتعرف داتابيز المحل من اللينك (`?d=`)، فمش محتاج ترفع الصفحة على مشروع المحل.

## 1. صاحب المحل (أو إنت بجيميله)

1. يفتح https://console.firebase.google.com ويعمل **Add project**. يختار اسم زي `cafe-elnour`، ومالوش لازمة Google Analytics.
2. **Build ← Realtime Database ← Create database**، ويختار المنطقة **Belgium (europe-west1)**، وبعدين "Start in locked mode".
3. **Build ← Authentication ← Get started ← Sign-in method ← Email/Password ← Enable** (الخانة الأولى بس).
4. **Project settings ← General ← Your apps ← Web (`</>`)**: يسجّل تطبيق ويب، بأي اسم ومن غير Hosting. هيظهر `apiKey`.
5. **Project settings ← Users and permissions ← Add member**: يكتب إيميلك، ويختار **Editor**.

**الخطة تفضل Spark (المجانية)، وماتحطش أي كارت.**

## 2. إنت

1. من فولدر `source`، ارفع القواعد:
   ```
   powershell -ExecutionPolicy Bypass -File tool\deploy_shop_firebase.ps1 -Project cafe-elnour
   ```
   في الآخر السكريبت بيتأكد: لازم `pub=200` و`inbox=401`.
2. في **License Maker**، تحت **"مشروع Firebase خاص بالمحل"**، املأ:
   - Project ID: `cafe-elnour`
   - Web API Key: الـ `apiKey` من الخطوة 4 فوق
   - Realtime Database URL: من صفحة Realtime Database، زي `https://cafe-elnour-default-rtdb.europe-west1.firebasedatabase.app`
3. اعمل كود لكل جهاز سيرفر في المحل. **كل الفروع بنفس إعدادات Firebase.**

## 3. عند المحل

- يفعّل الكود: **الإعدادات ← الاشتراك**. البرنامج هيعمل حسابه على المشروع الجديد لوحده، ويرفع المنيو.
- **لو المحل كان شغال قبل كده على مشروع تاني:**
  - كود الكافيه على النت بيتغير.
  - شاشة **الترابيزات** هتقول "اطبع الكروت تاني".
  - ربط الفروع القديم بيتفصل، فلازم الربط يتعمل تاني من شاشة الفروع.

## لو القواعد اتغيرت في نسخة جديدة

ارفعها على كل المحلات مرة واحدة:
```
powershell -ExecutionPolicy Bypass -File tool\deploy_shop_firebase.ps1 -Project cafe-elnour,cafe-elfayrouz
```
وصفحة المنيو بترفعها مرة واحدة على المشروع الأساسي:
```
firebase deploy --only hosting --project orderly-yvzug
```
