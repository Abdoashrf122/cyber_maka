-- إشعارات OneSignal (تطبيق منفصل عن ليلتنا) — بتوصل حتى والتطبيق مقفول خالص:
-- • طلب حجز جديد            → kind=new   (إشعار عادي بصوت مرة واحدة)
-- • العميل قال حوّل الـ deposit → kind=claim (رنة طويلة لحد ما حد يأكد/يرفض أو يسكّت)
-- • الطلب اتعامل معاه        → kind=clear (بيشيل الإشعار/يوقّف الرنة على كل الموبايلات — مابيظهرش)
-- بتروح للأدمنز بس (external_id = user_id بتاع الأدمن، التطبيق بيعمل OneSignal.login بعد الدخول).
-- المفتاح بيتحط من السيرفر بس: sh server/scripts/set_onesignal.sh
-- من غير مفتاح: مفيش حاجة بتتبعت والحجز شغال عادي (خدمة الموبايل بتسأل السيرفر كل 8 ثواني زي ما هي).
BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

CREATE TABLE IF NOT EXISTS private.push_config (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  app_id text,
  api_key text,
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO private.push_config (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
REVOKE ALL ON private.push_config FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private._push(p_kind text, p_title text, p_body text, p_data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, extensions, pg_temp AS $$
DECLARE
  c private.push_config;
  v_ids text[];
  v_silent boolean := p_kind = 'clear';
BEGIN
  SELECT * INTO c FROM private.push_config WHERE id = 1;
  IF c.app_id IS NULL OR c.api_key IS NULL THEN RETURN; END IF;
  SELECT array_agg(user_id::text) INTO v_ids FROM private.admins;
  IF v_ids IS NULL THEN RETURN; END IF;
  PERFORM net.http_post(
    url := 'https://api.onesignal.com/notifications?c=push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      -- مفاتيح os_v2 الجديدة → "Key"، القديمة → "Basic"
      'Authorization', CASE WHEN c.api_key LIKE 'os_v2_%' THEN 'Key ' ELSE 'Basic ' END || c.api_key),
    body := jsonb_build_object(
      'app_id', c.app_id,
      'target_channel', 'push',
      'include_aliases', jsonb_build_object('external_id', to_jsonb(v_ids)),
      'headings', jsonb_build_object('en', p_title, 'ar', p_title),
      'contents', jsonb_build_object('en', p_body, 'ar', p_body),
      'data', p_data || jsonb_build_object('kind', p_kind),
      'priority', 10,
      -- "clear" مالوش لازمة بعد دقيقتين؛ الباقي ساعة
      'ttl', CASE WHEN v_silent THEN 120 ELSE 3600 END),
    timeout_milliseconds := 5000);
EXCEPTION WHEN OTHERS THEN
  -- الإشعار مايوقّفش الحجز أبدًا
  RAISE WARNING 'push failed: %', SQLERRM;
END $$;

CREATE OR REPLACE FUNCTION private._booking_push() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE v_what text;
BEGIN
  SELECT o.name INTO v_what FROM private.offerings o WHERE o.id = NEW.offering_id;
  IF TG_OP = 'INSERT' AND NEW.status = 'pending' THEN
    PERFORM private._push('new', 'طلب حجز جديد',
      '#' || NEW.code || ' — ' || COALESCE(v_what, '') || ' · ' || private._local_time(NEW.start_at) || ' — افتح واقبل أو ارفض',
      jsonb_build_object('id', NEW.id, 'code', NEW.code));
  ELSIF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
    IF NEW.status = 'payment_claimed' THEN
      PERFORM private._push('claim', 'العميل حوّل الـ deposit 💰',
        '#' || NEW.code || ' — ' || COALESCE(NEW.deposit_amount::text, '') || ' ج — اتأكد إن الفلوس وصلت وأكّد',
        jsonb_build_object('id', NEW.id, 'code', NEW.code));
    ELSIF OLD.status IN ('pending', 'payment_claimed') THEN
      PERFORM private._push('clear', 'تحديث', 'تحديث', jsonb_build_object('id', NEW.id, 'code', NEW.code));
    END IF;
  END IF;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS bookings_push ON private.bookings;
CREATE TRIGGER bookings_push AFTER INSERT OR UPDATE OF status ON private.bookings
  FOR EACH ROW EXECUTE FUNCTION private._booking_push();

-- التطبيق محتاج الـ App ID (عام) عشان يعمل initialize — المفتاح مابيطلعش أبدًا
CREATE OR REPLACE FUNCTION public.admin_push_app_id() RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = private, pg_temp AS $$
BEGIN
  PERFORM private._require_admin();
  RETURN (SELECT app_id FROM private.push_config WHERE id = 1);
END $$;

REVOKE ALL ON FUNCTION private._push(text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private._booking_push() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_push_app_id() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_push_app_id() TO authenticated;

COMMIT;
