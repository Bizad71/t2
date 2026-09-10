# BIZA MARKET

نسخه پایه واقعی و Mobile First بر اساس مشخصات فایل پروژه شما ساخته شده است. این ZIP شامل Frontend، CSS، JavaScript، Migration امن Supabase و مستندات Binary Eye است.

## مهم
این پروژه به Supabase موجود شما وصل می‌شود؛ کلید Service Role هرگز داخل Frontend قرار نمی‌گیرد. چون من به پروژه Supabase شما دسترسی مستقیم ندارم، نمی‌توانم Migration را روی دیتابیس واقعی اجرا یا تست شبکه‌ای انجام دهم.

## اجرا
1. `config.example.js` را به `js/config.js` کپی کنید.
2. `SUPABASE_URL` و Anon/Publishable Key را وارد کنید.
3. فایل‌ها را روی یک وب‌سرور HTTPS یا localhost اجرا کنید. برای استفاده روزمره، HTTPS توصیه می‌شود.
4. `supabase/migrations/001_biza_market_safe.sql` را در SQL Editor پروژه Supabase اجرا کنید.
5. یک کاربر Auth بسازید و برای او در `public.profiles` نقش `admin` یا `store_user` و در حالت فروشگاهی `store_id` قرار دهید.
6. برای Store User مجوزهای لازم را در `public.user_permissions` بدهید.

## چرا Migration امن است؟
طبق Snapshot ارائه‌شده، جدول‌های اصلی از قبل وجود دارند: products، profiles، stores، inventory_batches، inventory_transactions، sales، sale_items، invoices، store_counters، store_settings و audit_logs. Migration آن‌ها را DROP نمی‌کند؛ فقط index/function/RLS لازم را ارتقا می‌دهد. Snapshot همچنین نشان می‌دهد Functionهای قدیمی با نام‌های جدیدتر و legacy مانند `create_product_with_stock`/`receive_stock`/`register_sale` هم‌زمان وجود داشته‌اند؛ این نسخه از مسیر `products` + `inventory_batches` + `create_sale` استفاده می‌کند.

## منطق Batch
هر ورود موجودی یک Batch جدید می‌سازد. در فروش، اگر یک Batch فعال باشد انتخاب خودکار است؛ اگر چند Batch فعال باشد فروشنده باید Batch/قیمت را انتخاب کند. فروش بیش از موجودی Fail می‌شود. لغو فروش دقیقاً موجودی Batchهای همان فروش را برمی‌گرداند.

## Session
Supabase Auth با `persistSession` و `autoRefreshToken` استفاده می‌شود و در شروع برنامه `getSession()` بررسی می‌شود. رمز عبور در localStorage ذخیره نمی‌شود.

## Binary Eye
Binary Eye طبق مستندات رسمی خود Deep Link زیر را پشتیبانی می‌کند:
`binaryeye://scan?ret=<encoded-return-uri>`
و مقدار اسکن‌شده با `{RESULT}` در URI برگشت قرار می‌گیرد. همچنین Intent اندرویدی `com.google.zxing.client.android.SCAN` را پشتیبانی می‌کند.

در این Web App از Deep Link استفاده شده است:
1. کاربر Scan را می‌زند.
2. `binaryeye://scan?...` باز می‌شود.
3. Binary Eye فقط Raw Barcode را می‌خواند.
4. بعد از Scan، URI برگشت، Barcode را به سایت برمی‌گرداند.
5. سایت Barcode را فقط در دیتابیس خودش جستجو می‌کند.

محدودیت: مرورگر وب به تنهایی کنترل کامل lifecycle یک Popup واقعی هنگام خروج به اپ خارجی را ندارد؛ در این نسخه state بارکد در `sessionStorage` نگهداری می‌شود. اگر پروژه داخل Android WebView/Wrapper قرار گیرد، می‌توان Intent را در لایه Native دقیق‌تر کنترل کرد.

## امنیت
- RLS بر اساس `private.current_user_store_id()` و نقش Admin اعمال شده است.
- Functionهای حساس `SECURITY DEFINER` هستند و Store/Permission را داخل DB بررسی می‌کنند.
- Service Role Key فقط باید در محیط سرور/Edge Function باشد.
- Barcode به‌تنهایی مجوز دسترسی نیست.

## تست ضروری قبل از استفاده عملی
- Login → Refresh → Logout → Login
- ایجاد کالا → Refresh → Login مجدد → مشاهده کالا
- دو Store و عدم مشاهده اطلاعات متقابل
- دو Batch با قیمت متفاوت و فروش از هر دو
- فروش بیشتر از موجودی باید Fail شود
- Cancel باید موجودی همان Batchها را برگرداند
- گزارش‌ها فقط داده واقعی DB را نشان دهند

## Binary Eye منابع
مستندات رسمی Binary Eye: https://github.com/markusfisch/BinaryEye
نسخه‌های F-Droid: https://f-droid.org/packages/de.markusfisch.android.binaryeye/

## ساختار
- `index.html`
- `config.example.js`
- `js/app.js`
- `js/config.js`
- `css/style.css`
- `supabase/migrations/001_biza_market_safe.sql`


## اتصال تستی آماده است
`js/config.js` با Project URL و Publishable Key تستی تنظیم شده است.
کلید Publishable برای کد مرورگر قابل استفاده است؛ امنیت داده‌ها باید با RLS و مجوزهای دیتابیس کنترل شود.
قبل از تست کامل، migration موجود در `supabase/migrations/001_biza_market_safe.sql` را در SQL Editor پروژه اجرا کنید.


## نسخه اصلاح‌شده
- خطای اتصال `config.js`/`app.js` اصلاح شده است.
- ورود با `profiles.email` انجام می‌شود و به RPC اضافی `get_login_email` وابسته نیست.
- وضعیت اتصال دیتابیس از نتیجه واقعی RPCها نمایش داده می‌شود.
