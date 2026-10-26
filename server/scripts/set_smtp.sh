#!/bin/sh
# إيميل إرسال الأكواد (نسيت كلمة السر / تغيير الإيميل) لتطبيق الأدمن:
#   sh server/scripts/set_smtp.sh                      (no-reply@makka.io على smtp.hostinger.com:465)
#   SMTP_USER=x@y.com sh server/scripts/set_smtp.sh     (إيميل تاني)
# كلمة سر الإيميل بتتكتب مخفية وبتتحفظ في /opt/maka/.env بس.
set -e
MAKA_DIR="${MAKA_DIR:-/opt/maka}"
SMTP_USER="${SMTP_USER:-no-reply@makka.io}"
SMTP_HOST="${SMTP_HOST:-smtp.hostinger.com}"
SMTP_PORT="${SMTP_PORT:-465}"

printf 'Mailbox password for %s: ' "$SMTP_USER"
stty -echo; read -r PASS; stty echo; echo
[ -n "$PASS" ] || { echo "empty password" >&2; exit 1; }
# بيتحفظ بين '...' في .env (docker compose بيقراه حرفيًا) — فعلامة ' جوه كلمة السر مش مسموحة
case "$PASS" in *"'"*) echo "password must not contain a single quote (') — change it in hPanel" >&2; exit 1 ;; esac

# بيتكتب من جوه root shell (القيمة بتعدّي من stdin — مش في أوامر ظاهرة)
printf '%s' "$PASS" | sudo MAKA_DIR="$MAKA_DIR" U="$SMTP_USER" H="$SMTP_HOST" P="$SMTP_PORT" sh -c '
  umask 077
  IFS= read -r SECRET || true
  grep -v -E "^SMTP_(USER|PASS|HOST|PORT)=" "$MAKA_DIR/.env" > "$MAKA_DIR/.env.new"
  printf "SMTP_USER=%s\nSMTP_PASS='\''%s'\''\nSMTP_HOST=%s\nSMTP_PORT=%s\n" "$U" "$SECRET" "$H" "$P" >> "$MAKA_DIR/.env.new"
  mv "$MAKA_DIR/.env.new" "$MAKA_DIR/.env"'
unset PASS

cd "$MAKA_DIR" && sudo docker compose up -d auth >/dev/null 2>&1
echo "SMTP saved for $SMTP_USER — auth restarted."
