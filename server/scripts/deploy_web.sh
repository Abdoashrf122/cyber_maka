#!/bin/sh
# تحديث ملفات الموقع على السيرفر (بعد أي تعديل في web/):
#   sudo sh server/scripts/deploy_web.sh
set -e
LELETNA_DIR="${LELETNA_DIR:-/opt/supabase}"
SITE="$LELETNA_DIR/volumes/proxy/caddy/maka/site"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$SITE"
# مسح القديم الأول (عشان مايفضلش ملف اتشال) — جوه فولدر الموقع بس
find "$SITE" -mindepth 1 -delete
cp -r "$ROOT/web/." "$SITE/"
find "$SITE" -type d -exec chmod 755 {} +
find "$SITE" -type f -exec chmod 644 {} +
echo "website files → $SITE"
