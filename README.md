# BIZA MARKET

نسخه آماده اجرای BIZA MARKET با Supabase، بدون Secret در Frontend.

## وضعیت فعلی و اصلاح اصلی
ساختار موجود دو مدل قدیمی `shops/shop_id` و مدل جدید `stores/store_id` را هم‌زمان داشت. در خروجی دیتابیس، `profiles` دارای `store_id` است اما چند Function قدیمی مثل `current_shop_id()` از `shop_id` استفاده می‌کردند؛ همین split می‌تواند باعث شود رکورد ثبت شود ولی بعد از Refresh/ورود مجدد در سایت دیده نشود. Migration جدید `current_shop_id()` و `get_my_user_data()` را به `store_id/stores` هماهنگ می‌کند. همچنین فروش جدید باید Batch مشخص داشته باشد؛ RPC `create_sale` این الزام را در خود Database اعمال می‌کند.

## اجرا
1. پوشه را روی یک وب‌سرور ساده یا GitHub Pages/Netlify/Cloudflare Pages قرار دهید. برای تست محلی: `python -m http.server 8080` داخل پوشه.
2. فایل `supabase/migrations/20260910_biza_hardening.sql` را در SQL Editor پروژه Supabase اجرا کنید.
3. Authentication > Email را فعال کنید.
4. یک کاربر Admin بسازید و در جدول `public.profiles` نقش او را `admin` کنید؛ برای اولین Admin می‌توان از SQL Editor و Service Role/داشبورد Supabase استفاده کرد.
5. برای ساخت Store User از Edge Function موجود استفاده کنید. قبل از deploy، Secret `SUPABASE_SERVICE_ROLE_KEY` را فقط در Secrets محیط Supabase Function تنظیم کنید.
6. Edge Function را با نام `admin-create-user` deploy کنید.

## اتصال
URL و Publishable Key در `js/app.js` قرار گرفته‌اند. Publishable/anon key برای Frontend است؛ Service Role Key هرگز در Frontend قرار نگرفته است.

## Auth و Refresh
Supabase client با `persistSession`, `autoRefreshToken` و `detectSessionInUrl` ساخته شده و `onAuthStateChange` وضعیت session را دنبال می‌کند. Password در localStorage ذخیره نمی‌شود.

## Barcode / Binary Eye
دکمه اسکن از deep link رسمی Binary Eye استفاده می‌کند: `binaryeye://scan?ret=...`. Binary Eye امکان باز شدن با URI و برگرداندن مقدار اسکن‌شده با `ret` و placeholder `{RESULT}` را مستند کرده است. بعد از برگشت، مقدار داخل همان input قرار می‌گیرد و state فیلد از طریق `sessionStorage` حفظ می‌شود. این پروژه از getUserMedia یا camera scanner داخلی استفاده نمی‌کند.

## نکته Android/Web
باز کردن custom URI توسط مرورگر به نصب بودن Binary Eye و سیاست مرورگر/Android وابسته است. اگر مرورگر اجازه اجرای URI را ندهد، ورود دستی بارکد همچنان فعال است. برای اجرای کاملاً native و تضمین‌شده، wrapper Android با Intent نیز می‌تواند ساخته شود.

## قابلیت‌ها
- Login و Session persistence
- Multi-tenant با store_id و RLS موجود
- Product و Barcode
- Batch و چند قیمت
- فروش transactional با انتخاب Batch
- Invoice و Cancel Sale موجود در schema
- Dashboard واقعی
- Audit log موجود در schema/RPCهای فعلی
- Admin/Store/User foundation
- Mobile-first UI با Blue/Black و Node/SVG سبک

## محدودیت مهم
این محیط به دیتابیس واقعی شما دسترسی مدیریتی/Service Role ندارد؛ بنابراین migration و Frontend را می‌توان ساخت و syntax/ساختار را بررسی کرد، اما اجرای واقعی روی پروژه Supabase و تست دور کامل Auth/RLS/Transaction نیازمند اجرای migration روی همان پروژه است. هیچ داده‌ای در این بسته Mock نشده است.
