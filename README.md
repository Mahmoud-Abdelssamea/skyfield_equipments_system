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

5. افتح `index.html` وسجّل الدخول بالبريد وكلمة المرور التي أنشأتها.

النسخة الحالية مربوطة مسبقًا بمشروع Supabase الخاص بـ Sky Field. زر **Supabase** في أعلى النظام متاح لتغيير الاتصال مستقبلًا عند الحاجة.

إذا كانت النسخة القديمة استُخدمت من المتصفح نفسه وكانت Supabase فارغة، سيعرض النظام نقل الأجهزة والسجلات والمهندسين المحفوظين محليًا إلى Supabase تلقائيًا. احتفظ بنسخة من Google Sheets قبل الانتقال كإجراء احتياطي.

## النشر على GitHub Pages

بعد تنفيذ ملف SQL وإنشاء المستخدم، يكفي رفع `index.html` إلى مستودع GitHub Pages؛ رابط المشروع والمفتاح العام موجودان داخل النسخة الحالية، لذلك لا يحتاج كل جهاز إلى ضبط الاتصال يدويًا.

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
