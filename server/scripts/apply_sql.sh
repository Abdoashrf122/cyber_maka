#!/bin/sh
# تطبيق تعديلات قاعدة البيانات (sql/*.sql) + تحديث كاش PostgREST — من غير باقي خطوات install.sh.
# استخدمه بعد أي تحديث للكود:   sh server/scripts/apply_sql.sh
# (PostgREST بيحفظ شكل الدوال في كاش؛ من غير الإشعار في الآخر، الدوال الجديدة بتفضل «مش موجودة».)
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

for f in "$ROOT"/server/sql/*.sql; do
  echo "  applying $(basename "$f")"
  sudo docker exec -i maka-db psql -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres < "$f"
done

echo "  reloading PostgREST schema cache"
sudo docker exec maka-db psql -q -U supabase_admin -d postgres -c "NOTIFY pgrst, 'reload schema';" || true
echo "DONE."
