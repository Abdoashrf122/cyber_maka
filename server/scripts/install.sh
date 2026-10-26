#!/bin/sh
# سيبر مكة — تركيب السيرفر (أمر واحد) على نفس VPS ليلتنا، بس منفصل تمامًا:
#   • Supabase خفيف في /opt/maka (قاعدة بيانات + مفاتيح جديدة — مالهاش علاقة بليلتنا)
#   • الموقع على الدومين بتاعه + api.<الدومين> لتطبيق الأدمن (Caddy الموجود بيعمل HTTPS)
#
# قبل التشغيل: في DNS الدومين اعمل A record لـ @ و api و www → IP السيرفر.
# التشغيل (من فولدر cyber_maka بعد ما ترفعه للسيرفر):
#   DOMAIN=example.com sh server/scripts/install.sh
# إعادة التشغيل آمنة: المفاتيح والبيانات بتفضل زي ماهي.
set -e
: "${DOMAIN:?set DOMAIN, e.g. DOMAIN=example.com}"
MAKA_DIR="${MAKA_DIR:-/opt/maka}"
LELETNA_DIR="${LELETNA_DIR:-/opt/supabase}"
CADDY_DIR="$LELETNA_DIR/volumes/proxy/caddy"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
say() { printf '\n==> %s\n' "$1"; }
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
jwt() {  # jwt ROLE SECRET
  h=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
  p=$(printf '{"role":"%s","iss":"supabase","iat":%s,"exp":%s}' "$1" "$IAT" "$EXP" | b64url)
  s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "$2" -binary | b64url)
  printf '%s.%s.%s' "$h" "$p" "$s"
}

say "Checking DNS for $DOMAIN, api.$DOMAIN, www.$DOMAIN"
MY_IP="$(curl -fsS https://api.ipify.org || true)"
for h in "$DOMAIN" "api.$DOMAIN" "www.$DOMAIN"; do
  # DNS عام (زي اللي Let's Encrypt بيشوفه) — الـ resolver المحلي ممكن يكون حافظ إجابة قديمة
  ip="$(dig +short A "$h" @8.8.8.8 2>/dev/null | grep -E '^[0-9.]+$' | tail -1)"
  [ -n "$ip" ] || ip="$(getent ahostsv4 "$h" | awk '{print $1}' | head -1)"
  echo "  $h → ${ip:-?}   (server: $MY_IP)"
  if [ -n "$MY_IP" ] && [ "$ip" != "$MY_IP" ]; then
    echo "!! $h does not point to this server yet (A record). Fix DNS, wait a few minutes, run again." >&2
    exit 1
  fi
done

sudo docker network inspect leletna-web-net >/dev/null 2>&1 || {
  echo "!! docker network leletna-web-net not found (Leletna's Caddy network)." >&2; exit 1; }
[ -f "$CADDY_DIR/Caddyfile" ] || { echo "!! $CADDY_DIR/Caddyfile not found" >&2; exit 1; }

say "Preparing $MAKA_DIR"
sudo mkdir -p "$MAKA_DIR/volumes/db/init" "$MAKA_DIR/volumes/storage" "$MAKA_DIR/backups"
if ! sudo test -f "$MAKA_DIR/.env"; then
  say "Generating NEW secrets (separate from Leletna)"
  PG="$(openssl rand -hex 24)"
  SECRET="$(openssl rand -hex 32)"
  IAT="$(date +%s)"; EXP=$((IAT + 315360000))  # 10 سنين
  ANON="$(jwt anon "$SECRET")"
  SERVICE="$(jwt service_role "$SECRET")"
  sudo sh -c "umask 077; cat > '$MAKA_DIR/.env'" <<EOF
POSTGRES_PASSWORD=$PG
JWT_SECRET=$SECRET
JWT_EXPIRY=3600
ANON_KEY=$ANON
SERVICE_ROLE_KEY=$SERVICE
API_EXTERNAL_URL=https://api.$DOMAIN
SITE_URL=https://$DOMAIN
EOF
  unset PG SECRET SERVICE
else
  echo "  .env already exists — keeping its keys"
fi
sudo cp "$ROOT/server/docker-compose.yml" "$MAKA_DIR/docker-compose.yml"
sudo cp "$ROOT/server/db-init/roles.sql" "$ROOT/server/db-init/jwt.sql" "$MAKA_DIR/volumes/db/init/"

say "Starting the stack (first start downloads images)"
cd "$MAKA_DIR"
sudo docker compose up -d

say "Waiting for auth + storage tables"
i=0
until [ "$(sudo docker exec maka-db psql -U supabase_admin -d postgres -Atc \
  "select to_regclass('auth.users') is not null and exists (select 1 from information_schema.columns
     where table_schema = 'storage' and table_name = 'buckets' and column_name = 'allowed_mime_types')" 2>/dev/null)" = "t" ]; do
  i=$((i+1)); [ $i -gt 72 ] && { echo "timeout waiting for the database" >&2; exit 1; }
  sleep 5
done

say "Applying the database (sql/*.sql)"
for f in "$ROOT"/server/sql/*.sql; do
  echo "  $(basename "$f")"
  sudo docker exec -i maka-db psql -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres < "$f"
done

# PostgREST بيحفظ شكل الدوال في كاش — من غير الإشعار ده الدوال الجديدة (زي الفريق)
# بتفضل «مش موجودة» لحد ما الحاوية تتعاد. الإشعار بيخلّيها تشتغل في نفس الثانية.
say "Reloading PostgREST schema cache"
sudo docker exec maka-db psql -q -U supabase_admin -d postgres -c "NOTIFY pgrst, 'reload schema';" || true

say "Website + Caddy"
sudo mkdir -p "$CADDY_DIR/maka/site"
sed "s/__DOMAIN__/$DOMAIN/g" "$ROOT/server/caddy/maka.caddy" | sudo tee "$CADDY_DIR/maka/maka.caddy" >/dev/null
sudo sh "$ROOT/server/scripts/deploy_web.sh"
if ! sudo grep -q '^import /etc/caddy/maka/maka.caddy' "$CADDY_DIR/Caddyfile"; then
  sudo cp "$CADDY_DIR/Caddyfile" "$CADDY_DIR/Caddyfile.before-maka.$(date +%Y%m%d%H%M%S)"
  printf '\n# سيبر مكة (مشروع منفصل: /opt/maka) — شيل السطر ده يوقف الموقع بتاعه بس\nimport /etc/caddy/maka/maka.caddy\n' \
    | sudo tee -a "$CADDY_DIR/Caddyfile" >/dev/null
fi
sudo docker exec supabase-caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
sudo docker exec supabase-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

say "Daily backup (03:40, keeps 14 days in $MAKA_DIR/backups)"
sudo tee /etc/cron.d/maka-backup >/dev/null <<EOF
40 3 * * * root docker exec maka-db pg_dump -U supabase_admin -d postgres -Fc > $MAKA_DIR/backups/maka_\$(date +\%Y\%m\%d).dump && tar -czf $MAKA_DIR/backups/photos_\$(date +\%Y\%m\%d).tgz -C $MAKA_DIR/volumes storage && find $MAKA_DIR/backups -type f -mtime +14 -delete
EOF

say "Checking HTTPS (the certificate can take a minute the first time)"
sleep 8
curl -fsS -o /dev/null -w "  https://$DOMAIN → HTTP %{http_code}\n" "https://$DOMAIN/" || echo "  site not answering yet — try again in a minute"
curl -fsS -o /dev/null -w "  https://api.$DOMAIN/health → HTTP %{http_code}\n" "https://api.$DOMAIN/health" || echo "  api not answering yet — try again in a minute"

ANON="$(sudo grep '^ANON_KEY=' "$MAKA_DIR/.env" | cut -d= -f2-)"
cat <<EOF

================================================================
 DONE.  Site: https://$DOMAIN     Admin API: https://api.$DOMAIN

 For the admin app (app/lib/config.dart):
   kApiUrl  = 'https://api.$DOMAIN'
   kAnonKey = '$ANON'
 (anon key is public by design — SERVICE_ROLE_KEY stays on the server)

 Next: create the admin login:
   sh server/scripts/create_admin.sh you@example.com "الاسم"
 Keep a copy of $MAKA_DIR/.env in your password manager.
================================================================
EOF
