-- كلمات سر الأدوار اللي الخدمات بتدخل بيها (نفس ملف Supabase الرسمي من غير supabase_functions_admin:
-- الدور ده بيتعمل في webhooks.sql بتاع النسخة الكاملة، وإحنا مش مشغّلين Edge Functions).
\set pgpass `echo "$POSTGRES_PASSWORD"`

ALTER USER authenticator WITH PASSWORD :'pgpass';
ALTER USER pgbouncer WITH PASSWORD :'pgpass';
ALTER USER supabase_auth_admin WITH PASSWORD :'pgpass';
ALTER USER supabase_storage_admin WITH PASSWORD :'pgpass';
