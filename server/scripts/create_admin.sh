#!/bin/sh
# حساب أدمن لتطبيق سيبر مكة — أو إرجاع كلمة سر حساب موجود (لو اتنسيت):
#   sh server/scripts/create_admin.sh admin "الاسم"
# اسم المستخدم (من غير @) بيتحوّل لإيميل داخلي <user>@users.makka.io (ماحدش بيبعتله حاجة).
# كلمة السر بتتكتب مخفية، والحساب بيضطر يغيّرها أول ما يدخل.
set -e
USER_IN="${1:?usage: create_admin.sh USERNAME [NAME]}"
NAME="${2:-الأدمن}"
MAKA_DIR="${MAKA_DIR:-/opt/maka}"
case "$USER_IN" in *@*) EMAIL="$USER_IN" ;; *) EMAIL="$(printf '%s' "$USER_IN" | tr 'A-Z' 'a-z')@users.makka.io" ;; esac
PSQL="sudo docker exec -i maka-db psql -At -v ON_ERROR_STOP=1 -U supabase_admin -d postgres"

printf 'Password for %s: ' "$USER_IN"
stty -echo; read -r PASS; stty echo; echo
[ -n "$PASS" ] || { echo "password must not be empty" >&2; exit 1; }
PASS_BYTES="$(printf '%s' "$PASS" | wc -c | tr -d ' ')"
[ "$PASS_BYTES" -le 72 ] || { echo "password exceeds bcrypt's 72-byte limit" >&2; exit 1; }

EXISTS="$(printf '%s\n' "SELECT count(*) FROM auth.users WHERE lower(email) = lower(:'e');" | $PSQL -v e="$EMAIL")"

if [ "$EXISTS" = "0" ]; then
  BODY="$(EMAIL="$EMAIL" PASS="$PASS" python3 -c 'import json,os;print(json.dumps({"email":os.environ["EMAIL"],"password":os.environ["PASS"],"email_confirm":True}))')"
  # من جوه حاوية الدخول (المفتاح بيتقري من .env جوه root shell — مش في أوامر ظاهرة)
  printf '%s' "$BODY" | sudo MAKA_DIR="$MAKA_DIR" sh -c '
    KEY="$(grep "^SERVICE_ROLE_KEY=" "$MAKA_DIR/.env" | cut -d= -f2-)"; export KEY
    docker exec -i -e KEY maka-auth sh -c "wget -qO- --header=\"Authorization: Bearer \$KEY\" --header=\"apikey: \$KEY\" \
      --header=\"Content-Type: application/json\" --post-file=/dev/stdin http://localhost:9999/admin/users" >/dev/null'
  unset BODY
else
  # حساب موجود → كلمة سر جديدة (bcrypt زي خدمة الدخول) + خروج من كل الأجهزة.
  # كلمة السر بتعدّي من stdin لملف مؤقت جوه الحاوية، psql بيقراه بـ \set وبعدها بيتمسح.
  echo "  user exists — resetting its password"
  printf '%s' "$PASS" | sudo docker exec -i maka-db sh -c 'umask 077; cat > /tmp/maka_p'
  RC=0
  $PSQL -q -v e="$EMAIL" <<'SQL' || RC=1
\set p `cat /tmp/maka_p`
UPDATE auth.users SET encrypted_password = extensions.crypt(:'p', extensions.gen_salt('bf', 10)), updated_at = now()
 WHERE lower(email) = lower(:'e');
DELETE FROM auth.refresh_tokens WHERE user_id IN (SELECT id::text FROM auth.users WHERE lower(email) = lower(:'e'));
SQL
  sudo docker exec maka-db rm -f /tmp/maka_p
  [ "$RC" = 0 ] || exit 1
fi
unset PASS

printf '%s\n' "INSERT INTO private.admins (user_id, name, must_change_password)
  SELECT id, :'name', true FROM auth.users WHERE lower(email) = lower(:'email')
  ON CONFLICT (user_id) DO UPDATE SET must_change_password = true
  RETURNING 'admin ok: ' || user_id;" | $PSQL -v name="$NAME" -v email="$EMAIL"
