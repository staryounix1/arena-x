# ARENA//X 🚀

منصة تنافسية مغربية لـ eFootball للمباريات المدفوعة 1vs1، البطولات، الترتيب، والمحفظة، مع تجربة أسرع وهوية أكثر جرأة.

---

## 🚀 البدء السريع

### المتطلبات:
- Node.js 20+
- pnpm 9+
- حساب Supabase (مجاني)

---

## 📦 التثبيت

```bash
# تثبيت التبعيات
pnpm install
```

---

## 🔧 إعداد قاعدة البيانات (Supabase)

### الخطوة 1: إنشاء مشروع Supabase
1. اذهب إلى [https://supabase.com](https://supabase.com)
2. أنشئ مشروعاً جديداً
3. اذهب إلى **Settings** → **API** وانسخ:
   - Project URL
   - anon public key
   - احتفظ بـ service_role key سرياً؛ لا يحتاجه هذا التطبيق في المتصفح.

### الخطوة 2: إعداد ملف .env
أنشئ ملف `.env` في جذر المشروع:

```env
# Frontend (Vite)
VITE_SUPABASE_URL=https://YOUR-PROJECT.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR-ANON-KEY

```

### الخطوة 3: تطبيق قاعدة البيانات
من **SQL Editor** في Supabase، شغّل الملفين بالترتيب:

1. `supabase/migrations/20260911_arena.sql`
2. `supabase/migrations/20260915_remote_arena.sql`

### الخطوة 4: إنشاء SuperAdmin
أنشئ مستخدماً في **Authentication → Users** بالبريد الإداري الذي تختاره، ثم نفّذ:

```sql
UPDATE public.users
SET role = 'ADMIN', banned = FALSE
 WHERE email = 'YOUR-ADMIN-EMAIL';
```

---

## ▶️ تشغيل التطبيق

### التطبيق:
```bash
pnpm run dev
```
- سيفتح على: `http://localhost:5173`

---

## 📋 الأوامر المتاحة

```bash
# تثبيت التبعيات
pnpm install

# تشغيل التطبيق
pnpm run dev

# بناء التطبيق للإنتاج
pnpm run build

# فحص TypeScript
pnpm run typecheck

```

---

## 📂 هيكل المشروع

```
arena-x/
├── src/                           # التطبيق (React + Vite)
│   ├── App.tsx
│   └── lib/supabase.ts
├── supabase/
│   └── migrations/
│       ├── 20260911_arena.sql
│       └── 20260915_remote_arena.sql
├── .env.example
 
```

---

## 🌐 النشر على Vercel

المشروع جاهز للنشر على Vercel! فقط ارفعه على GitHub واربطه بـ Vercel.

### المتغيرات البيئية في Vercel:
- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_ANON_KEY`

---

## 🔐 SuperAdmin Dashboard

بعد تسجيل الدخول كـ SuperAdmin، يمكنك:
- إدارة المباريات والتحديات
- الموافقة على طلبات الشحن
- إدارة المستخدمين
- إعدادات المنصة
- عرض الإحصائيات

---

## 📊 الجداول في قاعدة البيانات

| الجدول | الوظيفة |
|--------|---------|
| `users` | حسابات اللاعبين والمديرين |
| `matches` | مباريات التحديات 1v1 |
| `match_messages` | رسائل الدردشة |
| `tournaments` | البطولات |
| `tournament_participants` | مشاركة اللاعبين |
| `transactions` | المعاملات المالية |
| `recharges` | طلبات الشحن |
| `withdrawals` | طلبات السحب |
| `disputes` | نزاعات المباريات |
| `dispute_evidence` | ملفات أدلة النزاعات |
| `activity_logs` | سجل النشاطات |
| `settings` | إعدادات المنصة |

---

## 🆘 المساعدة

إذا واجهت مشكلة:
1. تأكد أن متغيري Supabase في `.env` صحيحان
2. تأكد أن Supabase يعمل
3. جرب `pnpm install` ثم أعد التشغيل
4. تحقق من السجلات في الترمينال

---

## 📝 ملاحظات

- ملف `.env` مضاف إلى `.gitignore` (لن يُرفع على GitHub)
- لا تضع مفتاح `service_role` في الواجهة أو في GitHub
- شغّل ملفي قاعدة البيانات بالترتيب
- RLS مفعّل على جميع الجداول
