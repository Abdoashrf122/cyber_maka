#!/bin/sh
# ربط OneSignal (تطبيق «سيبر مكة» المنفصل عن ليلتنا):
#   sh server/scripts/set_onesignal.sh <APP_ID>
# الـ REST API Key بيتكتب مخفي وبيتحفظ في قاعدة البيانات (private.push_config) بس — مابيظهرش في أي أمر.
set -e
APP_ID="${1:?usage: set_onesignal.sh APP_ID}"
case "$APP_ID" in *[!0-9a-fA-F-]*) echo "APP_ID looks wrong (should be like 1234abcd-....)" >&2; exit 1 ;; esac

printf 'OneSignal REST API Key: '
stty -echo; read -r KEY; stty echo; echo
[ ${#KEY} -ge 20 ] || { echo "key looks too short" >&2; exit 1; }

# المفتاح بيعدّي من stdin لملف مؤقت جوه الحاوية، psql بيقراه بـ \set وبعدها بيتمسح
printf '%s' "$KEY" | sudo docker exec -i maka-db sh -c 'umask 077; cat > /tmp/maka_k'
unset KEY
RC=0
sudo docker exec -i maka-db psql -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -v app="$APP_ID" <<'SQL' || RC=1
\set k `cat /tmp/maka_k`
UPDATE private.push_config SET app_id = :'app', api_key = :'k', updated_at = now() WHERE id = 1;
SQL
sudo docker exec maka-db rm -f /tmp/maka_k
[ "$RC" = 0 ] || exit 1
echo "OneSignal saved (app $APP_ID). Test: book from the site — admins get a push."
