# Sky Field Equipment System — HTML + Supabase

النظام يعمل من ملف `index.html` واحد على GitHub Pages، بينما توفر Supabase تسجيل الدخول وقاعدة البيانات وتخزين شهادات المعايرة. لا يحتاج إلى Node.js أو MongoDB أو Google Apps Script.

## الإعداد لأول مرة

1. أنشئ مشروعًا في Supabase.
2. افتح **SQL Editor** وشغّل ملف `supabase-schema.sql` كاملًا مرة واحدة.
3. من **Authentication > Users** أنشئ أول مستخدم بالبريد الإلكتروني وكلمة المرور.
4. انسخ UUID لهذا المستخدم، ثم نفّذ في SQL Editor:

```sql
update public.sf_profiles
set role = 'admin'
where id = 'ضع UUID المستخدم هنا';
```

5. افتح `index.html`، واضغط **إعداد اتصال Supabase**.
6. أدخل **Project URL** و**Publishable/Anon Key** من إعدادات API في Supabase.
7. سجّل الدخول بالبريد وكلمة المرور التي أنشأتها.

إذا كانت النسخة القديمة استُخدمت من المتصفح نفسه وكانت Supabase فارغة، سيعرض النظام نقل الأجهزة والسجلات والمهندسين المحفوظين محليًا إلى Supabase تلقائيًا. احتفظ بنسخة من Google Sheets قبل الانتقال كإجراء احتياطي.

## النشر على GitHub Pages

بعد تنفيذ إعداد Supabase، يكفي رفع `index.html` إلى مستودع GitHub Pages. بيانات الاتصال العامة تُحفظ في المتصفح عند إدخالها من شاشة الإعداد. لتجهيز الاتصال لجميع الأجهزة دون إدخاله يدويًا، يمكن لاحقًا وضع Project URL والمفتاح العام في إعداد ثابت داخل الملف.

## الأدوار والصلاحيات

- `admin`: إدارة كاملة، ويمكنه تغيير أدوار المستخدمين من Supabase.
- `storekeeper`: إضافة وتعديل وحذف الأجهزة والحركات والمهندسين والمواقع.
- `viewer`: عرض البيانات فقط.

أي مستخدم جديد يحصل تلقائيًا على دور `viewer`. لتغيير الدور:

```sql
update public.sf_profiles set role = 'storekeeper' where id = 'USER_UUID';
```

## الأمان

- استخدم داخل HTML مفتاح **Publishable/Anon** فقط.
- لا تضع `service_role key` داخل HTML مطلقًا.
- جميع الجداول والملفات محمية بسياسات Row Level Security.
- شهادات المعايرة محفوظة في bucket خاص، ويتم فتحها بروابط مؤقتة مدتها دقيقتان.
