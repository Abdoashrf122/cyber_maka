-- ═══════════════════════════════════════════════════════════════════════════
-- سيبر مكة — قاعدة البيانات (Supabase مفتوح المصدر على VPS، منفصلة تمامًا عن ليلتنا)
--
-- • كل الجداول في schema "private" — مفيش وصول مباشر لأي جدول من برا.
-- • الموقع (من غير حساب): دوال web_* بس، عن طريق Caddy (/api/<fn>) وبحد طلبات لكل IP.
-- • تطبيق الأدمن (ويندوز/أندرويد): دوال admin_* بعد تسجيل الدخول (private.admins).
-- • خدمة الأندرويد في الخلفية (رنة + قراءة إشعارات التحويل/SMS): دوال device_* بتوكن جهاز.
--
-- دورة الحجز:
--   pending (مستني رد المحل) → awaiting_payment (اتقبل — مستني الـ deposit)
--     → payment_claimed (العميل قال حوّلت) → confirmed (الفلوس وصلت: يدوي / إشعار / SMS)
--   أو: rejected / expired / cancelled — وبعد الميعاد: completed / no_show
--
-- الملف ده بيتشغّل أكتر من مرة عادي (IF NOT EXISTS / CREATE OR REPLACE).
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;

-- ═════════ الجداول ═════════

CREATE TABLE IF NOT EXISTS private.settings (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  booking_enabled boolean NOT NULL DEFAULT true,
  closed_message text NOT NULL DEFAULT 'الحجز من الموقع واقف مؤقتًا — كلّمنا على الواتساب.',
  deposit_policy text NOT NULL DEFAULT 'الـ deposit بيتخصم من حسابك في المحل. لو ماجيتش في ميعادك من غير ما تبلغنا، الـ deposit مش بيرجع.',
  approve_minutes int NOT NULL DEFAULT 15 CHECK (approve_minutes BETWEEN 3 AND 240),
  pay_minutes int NOT NULL DEFAULT 15 CHECK (pay_minutes BETWEEN 5 AND 240),
  -- الـ deposit بيزيد جنيه/اتنين لو فيه حجز تاني مستني نفس المبلغ → التأكيد التلقائي يعرف التحويل بتاع مين
  unique_amount boolean NOT NULL DEFAULT true,
  min_lead_minutes int NOT NULL DEFAULT 30 CHECK (min_lead_minutes BETWEEN 0 AND 1440),
  max_days_ahead int NOT NULL DEFAULT 7 CHECK (max_days_ahead BETWEEN 0 AND 60),
  slot_minutes int NOT NULL DEFAULT 30 CHECK (slot_minutes IN (15, 30, 60)),
  min_duration_min int NOT NULL DEFAULT 60 CHECK (min_duration_min BETWEEN 15 AND 1440),
  max_duration_min int NOT NULL DEFAULT 360 CHECK (max_duration_min BETWEEN 15 AND 1440),
  instapay_address text,
  instapay_phone text,
  telda_handle text,
  wallet_phone text,
  pay_note text,
  auto_confirm_notifications boolean NOT NULL DEFAULT true,
  auto_confirm_sms boolean NOT NULL DEFAULT true,
  -- إشعارات التحويل بتتقري من التطبيقات دي بس (اسم الباكدج — مايتزوّرش)
  notif_packages text[] NOT NULL DEFAULT ARRAY['com.egyptianbanks.instapay', 'com.telda.app'],
  -- رسايل SMS بتتقري من الأسماء دي بس (اسم شركة — أي رقم موبايل بيتجاهل)
  sms_senders text[] NOT NULL DEFAULT ARRAY['InstaPay', 'IPN', 'Telda', 'CIB', 'NBE', 'BanqueMisr', 'BM', 'QNB', 'AAIB', 'HSBC', 'ADIB', 'Alexbank', 'EGBANK', 'FAB', 'Mashreq'],
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (max_duration_min >= min_duration_min)
);
INSERT INTO private.settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
-- إخفاء الأسعار من الموقع خالص (الكتالوج مابيرجعهاش أصلًا)
ALTER TABLE private.settings ADD COLUMN IF NOT EXISTS show_prices boolean NOT NULL DEFAULT true;

CREATE TABLE IF NOT EXISTS private.admins (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS private.branches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9-]{2,30}$'),
  name text NOT NULL CHECK (length(name) BETWEEN 2 AND 60),
  address text,
  maps_url text,
  phone text,
  whatsapp text,
  hours_text text,
  open_24h boolean NOT NULL DEFAULT true,
  open_time time,
  close_time time,
  is_active boolean NOT NULL DEFAULT true,
  sort int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (open_24h OR (open_time IS NOT NULL AND close_time IS NOT NULL AND open_time <> close_time))
);

CREATE TABLE IF NOT EXISTS private.branch_photos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES private.branches(id) ON DELETE CASCADE,
  path text NOT NULL CHECK (path ~ '^[A-Za-z0-9/_.-]{3,200}$'),
  caption text,
  sort int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE private.branch_photos
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

-- اللي بيتحجز: أجهزة PC (عدد أجهزة) أو غرف بلايستيشن (غرفة كاملة)
CREATE TABLE IF NOT EXISTS private.offerings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES private.branches(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('pc', 'ps_room')),
  name text NOT NULL CHECK (length(name) BETWEEN 2 AND 60),
  details text,
  units int NOT NULL DEFAULT 1 CHECK (units BETWEEN 0 AND 200),
  max_per_booking int NOT NULL DEFAULT 1 CHECK (max_per_booking BETWEEN 1 AND 50),
  price_per_hour numeric(10,2) NOT NULL CHECK (price_per_hour >= 0),
  deposit numeric(10,2) NOT NULL DEFAULT 50 CHECK (deposit >= 0),
  is_active boolean NOT NULL DEFAULT true,
  sort int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS private.devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  token_hash text NOT NULL UNIQUE,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_seen timestamptz,
  revoked_at timestamptz
);

CREATE TABLE IF NOT EXISTS private.bookings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  token_hash text NOT NULL UNIQUE,
  branch_id uuid NOT NULL REFERENCES private.branches(id),
  offering_id uuid NOT NULL REFERENCES private.offerings(id),
  units int NOT NULL DEFAULT 1 CHECK (units >= 1),
  start_at timestamptz NOT NULL,
  end_at timestamptz NOT NULL,
  duration_min int NOT NULL CHECK (duration_min > 0),
  customer_name text,
  customer_phone text,
  note text,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN
    ('pending', 'awaiting_payment', 'payment_claimed', 'confirmed', 'rejected', 'expired', 'cancelled', 'completed', 'no_show')),
  price_total numeric(10,2) NOT NULL,
  deposit_base numeric(10,2) NOT NULL,
  deposit_amount numeric(10,2),
  approve_deadline timestamptz NOT NULL,
  pay_deadline timestamptz,
  payer_name text,
  claimed_at timestamptz,
  paid_via text CHECK (paid_via IN ('manual', 'notification', 'sms', 'none')),
  payment_event_id bigint,
  confirmed_at timestamptz,
  decided_at timestamptz,
  decided_by uuid,
  reason text,
  ip text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (end_at > start_at)
);
-- المتصفح اللي اتحجز منه (hash لرقم عشوائي محفوظ فيه) — عشان البلوك يمسك اللي بيغيّر رقمه
ALTER TABLE private.bookings ADD COLUMN IF NOT EXISTS device_hash text;

-- البلوك: رقم موبايل / متصفح / شبكة (IP — مؤقت بس، لأن شبكة واحدة ممكن يبقى عليها ناس كتير)
CREATE TABLE IF NOT EXISTS private.blocks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL CHECK (kind IN ('phone', 'device', 'ip')),
  value text NOT NULL,
  reason text,
  booking_code text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz
);
CREATE INDEX IF NOT EXISTS blocks_lookup_idx ON private.blocks (kind, value);
CREATE INDEX IF NOT EXISTS bookings_offering_time_idx ON private.bookings (offering_id, start_at);
CREATE INDEX IF NOT EXISTS bookings_status_idx ON private.bookings (status);
CREATE INDEX IF NOT EXISTS bookings_phone_idx ON private.bookings (customer_phone, created_at);
CREATE INDEX IF NOT EXISTS bookings_created_idx ON private.bookings (created_at);

CREATE TABLE IF NOT EXISTS private.payment_events (
  id bigserial PRIMARY KEY,
  device_id uuid REFERENCES private.devices(id) ON DELETE SET NULL,
  source text NOT NULL CHECK (source IN ('notification', 'sms')),
  origin text NOT NULL,
  title text,
  body text NOT NULL,
  amount numeric(10,2),
  payer text,
  received_at timestamptz NOT NULL,
  dedupe_key text NOT NULL UNIQUE,
  result text NOT NULL CHECK (result IN ('matched', 'unmatched', 'ambiguous', 'no_amount', 'auto_off', 'linked')),
  booking_id uuid REFERENCES private.bookings(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS payment_events_created_idx ON private.payment_events (created_at);

CREATE TABLE IF NOT EXISTS private.ip_rate_log (
  id bigserial PRIMARY KEY,
  bucket text NOT NULL,
  ip text NOT NULL,
  at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ip_rate_log_idx ON private.ip_rate_log (bucket, ip, at);

REVOKE ALL ON ALL TABLES IN SCHEMA private FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA private FROM PUBLIC, anon, authenticated;

-- ═════════ أدوات داخلية ═════════

-- IP الزائر: Caddy بيحط الـ IP الحقيقي في X-Forwarded-For (وبيشيل أي قيمة جاية من المتصفح)
CREATE OR REPLACE FUNCTION private._client_ip() RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT NULLIF(btrim(split_part(COALESCE(
           NULLIF(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for',
           NULLIF(current_setting('request.headers', true), '')::json ->> 'x-real-ip', ''), ',', 1)), '')
$$;

CREATE OR REPLACE FUNCTION private._ip_rate_ok(p_bucket text, p_limit int, p_window interval) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE v_ip text := private._client_ip();
BEGIN
  IF v_ip IS NULL THEN RETURN true; END IF; -- من جوه السيرفر (مش طلب API)
  IF (SELECT count(*) FROM private.ip_rate_log WHERE bucket = p_bucket AND ip = v_ip AND at > now() - p_window) >= p_limit THEN
    RETURN false;
  END IF;
  INSERT INTO private.ip_rate_log (bucket, ip) VALUES (p_bucket, v_ip);
  RETURN true;
END $$;

CREATE OR REPLACE FUNCTION private._token_hash(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT encode(extensions.digest(COALESCE(p, ''), 'sha256'), 'hex')
$$;

CREATE OR REPLACE FUNCTION private._new_token() RETURNS text
LANGUAGE sql VOLATILE SET search_path = pg_catalog AS $$
  SELECT translate(encode(extensions.gen_random_bytes(24), 'base64'), '+/', '-_')
$$;

CREATE OR REPLACE FUNCTION private._digits(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT regexp_replace(translate(COALESCE(p, ''), '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789'), '[^0-9]', '', 'g')
$$;

-- موبايل مصري: 01xxxxxxxxx (بيقبل +20 / 0020 / أرقام عربي)
CREATE OR REPLACE FUNCTION private._clean_phone(p text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog AS $$
DECLARE d text := private._digits(p);
BEGIN
  IF d LIKE '0020%' THEN d := '0' || substr(d, 5);
  ELSIF d LIKE '20%' AND length(d) = 12 THEN d := '0' || substr(d, 3);
  ELSIF d LIKE '1%' AND length(d) = 10 THEN d := '0' || d;
  END IF;
  RETURN CASE WHEN d ~ '^01[0125][0-9]{8}$' THEN d END;
END $$;

-- رقم تليفون/واتساب للفرع (أرضي أو موبايل) — أرقام بس
CREATE OR REPLACE FUNCTION private._clean_any_phone(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT CASE WHEN length(private._digits(p)) BETWEEN 6 AND 15 THEN private._digits(p) END
$$;

CREATE OR REPLACE FUNCTION private._clean_text(p text, p_max int) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT NULLIF(btrim(left(regexp_replace(COALESCE(p, ''), '[[:cntrl:]]+', ' ', 'g'), p_max)), '')
$$;

CREATE OR REPLACE FUNCTION private._clean_url(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT CASE WHEN btrim(COALESCE(p, '')) ~ '^https://[^[:space:]<>"'']{3,}$' AND length(btrim(p)) <= 500 THEN btrim(p) END
$$;

CREATE OR REPLACE FUNCTION public.is_admin() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = private, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM private.admins WHERE user_id = auth.uid())
$$;

CREATE OR REPLACE FUNCTION private._require_admin() RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = private, pg_temp AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not_admin' USING ERRCODE = '42501'; END IF;
END $$;

CREATE OR REPLACE FUNCTION private._device(p_token text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
  UPDATE private.devices SET last_seen = now()
   WHERE token_hash = private._token_hash(p_token) AND revoked_at IS NULL
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- الحجز جوه مواعيد الفرع؟ (المواعيد بتوقيت القاهرة؛ الفرع ممكن يقفل بعد نص الليل)
CREATE OR REPLACE FUNCTION private._fits_hours(p_branch uuid, p_start timestamptz, p_end timestamptz) RETURNS boolean
LANGUAGE plpgsql STABLE SET search_path = private, pg_temp AS $$
DECLARE
  b private.branches;
  ls timestamp := p_start AT TIME ZONE 'Africa/Cairo';
  le timestamp := p_end AT TIME ZONE 'Africa/Cairo';
  d date;
  o timestamp;
  c timestamp;
BEGIN
  SELECT * INTO b FROM private.branches WHERE id = p_branch;
  IF NOT FOUND THEN RETURN false; END IF;
  IF b.open_24h THEN RETURN true; END IF;
  FOREACH d IN ARRAY ARRAY[ls::date - 1, ls::date] LOOP
    o := d + b.open_time;
    c := CASE WHEN b.close_time > b.open_time THEN d + b.close_time ELSE (d + 1) + b.close_time END;
    IF ls >= o AND le <= c THEN RETURN true; END IF;
  END LOOP;
  RETURN false;
END $$;

-- أقصى عدد وحدات (أجهزة/غرف) مستخدمة في نفس اللحظة جوه الفترة دي
CREATE OR REPLACE FUNCTION private._peak_units(p_offering uuid, p_start timestamptz, p_end timestamptz, p_exclude uuid DEFAULT NULL)
RETURNS int LANGUAGE sql STABLE SET search_path = private, pg_temp AS $$
  WITH act AS (
    SELECT start_at, end_at, units FROM private.bookings
     WHERE offering_id = p_offering
       AND status IN ('pending', 'awaiting_payment', 'payment_claimed', 'confirmed')
       AND start_at < p_end AND end_at > p_start
       AND id IS DISTINCT FROM p_exclude
  ), pts AS (
    SELECT p_start AS t UNION SELECT start_at FROM act WHERE start_at > p_start
  )
  SELECT COALESCE(max((SELECT COALESCE(sum(a.units), 0) FROM act a WHERE a.start_at <= pts.t AND a.end_at > pts.t)), 0)::int
    FROM pts
$$;

-- الطلبات اللي عدّى ميعادها (بيتنادى من كل دالة + cron كل دقيقة)
CREATE OR REPLACE FUNCTION private._expire() RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = private, pg_temp AS $$
  UPDATE private.bookings SET status = 'expired', reason = 'المحل مالحقش يرد على الطلب في الوقت المحدد', updated_at = now()
   WHERE status = 'pending' AND approve_deadline < now();
  UPDATE private.bookings SET status = 'expired', reason = 'انتهت مهلة تحويل الـ deposit', updated_at = now()
   WHERE status = 'awaiting_payment' AND pay_deadline < now();
$$;

-- خصوصية: بيانات العميل ورسايل التحويل بتتمسح بعد 90 يوم
CREATE OR REPLACE FUNCTION private._purge() RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = private, pg_temp AS $$
  UPDATE private.bookings SET customer_name = NULL, customer_phone = NULL, note = NULL, payer_name = NULL, ip = NULL, device_hash = NULL
   WHERE end_at < now() - interval '90 days' AND (customer_phone IS NOT NULL OR customer_name IS NOT NULL);
  DELETE FROM private.payment_events WHERE created_at < now() - interval '90 days';
  DELETE FROM private.ip_rate_log WHERE at < now() - interval '2 days';
$$;

CREATE OR REPLACE FUNCTION private._local_date(t timestamptz) RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$ SELECT to_char(t AT TIME ZONE 'Africa/Cairo', 'YYYY-MM-DD') $$;
CREATE OR REPLACE FUNCTION private._local_time(t timestamptz) RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$ SELECT to_char(t AT TIME ZONE 'Africa/Cairo', 'HH24:MI') $$;

-- تأكيد حجز بتحويل (من إشعار/SMS) — الحجز لازم يكون مقفول FOR UPDATE قبلها
CREATE OR REPLACE FUNCTION private._confirm_by_event(p_booking uuid, p_event bigint, p_source text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = private, pg_temp AS $$
  UPDATE private.bookings
     SET status = 'confirmed', paid_via = p_source, payment_event_id = p_event, confirmed_at = now(),
         reason = NULL, updated_at = now()
   WHERE id = p_booking;
$$;

-- مطابقة تحويل بحجز: نفس المبلغ بالظبط + الحجز اتقبل قبل التحويل.
-- لو أكتر من حجز بنفس المبلغ → نجرب اسم المحوِّل؛ لو لسه مش واضح → يدوي (ambiguous).
CREATE OR REPLACE FUNCTION private._match_event(p_event bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE
  e private.payment_events;
  v_ids uuid[];
  v_named uuid[];
  v_first text;
  v_code text;
BEGIN
  SELECT * INTO e FROM private.payment_events WHERE id = p_event FOR UPDATE;
  IF e.amount IS NULL OR e.amount <= 0 THEN RETURN jsonb_build_object('result', 'no_amount'); END IF;

  SELECT array_agg(id ORDER BY decided_at) INTO v_ids FROM private.bookings
   WHERE status IN ('awaiting_payment', 'payment_claimed')
     AND deposit_amount = e.amount
     AND decided_at <= e.received_at + interval '5 minutes';

  IF COALESCE(array_length(v_ids, 1), 0) > 1 AND e.payer IS NOT NULL THEN
    v_first := lower(split_part(btrim(e.payer), ' ', 1));
    SELECT array_agg(id) INTO v_named FROM private.bookings
     WHERE id = ANY(v_ids) AND payer_name IS NOT NULL AND length(v_first) >= 2
       AND (lower(payer_name) LIKE '%' || v_first || '%'
            OR lower(e.payer) LIKE '%' || lower(split_part(btrim(payer_name), ' ', 1)) || '%');
    IF COALESCE(array_length(v_named, 1), 0) = 1 THEN v_ids := v_named; END IF;
  END IF;

  IF COALESCE(array_length(v_ids, 1), 0) = 1 THEN
    PERFORM 1 FROM private.bookings WHERE id = v_ids[1] FOR UPDATE;
    PERFORM private._confirm_by_event(v_ids[1], e.id, e.source);
    UPDATE private.payment_events SET result = 'matched', booking_id = v_ids[1] WHERE id = e.id;
    SELECT code INTO v_code FROM private.bookings WHERE id = v_ids[1];
    RETURN jsonb_build_object('result', 'matched', 'booking_code', v_code);
  ELSIF COALESCE(array_length(v_ids, 1), 0) > 1 THEN
    UPDATE private.payment_events SET result = 'ambiguous' WHERE id = e.id;
    RETURN jsonb_build_object('result', 'ambiguous');
  END IF;
  UPDATE private.payment_events SET result = 'unmatched' WHERE id = e.id;
  RETURN jsonb_build_object('result', 'unmatched');
END $$;

-- إشعار/SMS تحويل جاي من موبايل المحل
CREATE OR REPLACE FUNCTION private._ingest(p_device uuid, p_source text, p_origin text, p_title text, p_body text,
                                           p_amount numeric, p_payer text, p_received_at timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE
  s private.settings;
  v_origin text := private._clean_text(p_origin, 100);
  v_body text := private._clean_text(p_body, 1000);
  v_at timestamptz := LEAST(COALESCE(p_received_at, now()), now());
  v_key text;
  v_id bigint;
  v_amount numeric(10,2) := CASE WHEN p_amount > 0 AND p_amount < 1000000 THEN round(p_amount, 2) END;
  v_auto boolean;
BEGIN
  IF p_source NOT IN ('notification', 'sms') OR v_origin IS NULL OR v_body IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_input');
  END IF;
  SELECT * INTO s FROM private.settings WHERE id = 1;
  IF p_source = 'notification' AND NOT (v_origin = ANY(s.notif_packages)) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'origin_not_allowed');
  END IF;
  -- SMS: لازم اسم شركة (فيه حروف) ومن القايمة — أي رقم موبايل بيتجاهل (ضد النصب)
  IF p_source = 'sms' AND (v_origin !~ '[A-Za-z]'
       OR NOT EXISTS (SELECT 1 FROM unnest(s.sms_senders) x WHERE lower(x) = lower(v_origin))) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'origin_not_allowed');
  END IF;
  IF v_at < now() - interval '2 days' THEN RETURN jsonb_build_object('ok', false, 'error', 'too_old'); END IF;

  v_key := md5(p_source || '|' || v_origin || '|' || v_body || '|' || date_trunc('minute', v_at)::text);
  v_auto := CASE p_source WHEN 'sms' THEN s.auto_confirm_sms ELSE s.auto_confirm_notifications END;

  INSERT INTO private.payment_events (device_id, source, origin, title, body, amount, payer, received_at, dedupe_key, result)
  VALUES (p_device, p_source, v_origin, private._clean_text(p_title, 200), v_body, v_amount,
          private._clean_text(p_payer, 80), v_at, v_key,
          CASE WHEN v_amount IS NULL THEN 'no_amount' WHEN NOT v_auto THEN 'auto_off' ELSE 'unmatched' END)
  ON CONFLICT (dedupe_key) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN RETURN jsonb_build_object('ok', true, 'duplicate', true); END IF;
  IF v_amount IS NULL OR NOT v_auto THEN
    RETURN jsonb_build_object('ok', true, 'result', CASE WHEN v_amount IS NULL THEN 'no_amount' ELSE 'auto_off' END);
  END IF;
  RETURN jsonb_build_object('ok', true) || private._match_event(v_id);
END $$;

CREATE OR REPLACE FUNCTION private._booking_json(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = private, pg_temp AS $$
  SELECT jsonb_build_object(
    'id', k.id, 'code', k.code, 'status', k.status, 'reason', k.reason,
    'branch_id', k.branch_id, 'branch_name', b.name, 'offering_id', k.offering_id, 'offering_name', o.name, 'kind', o.kind,
    'units', k.units, 'start_at', k.start_at, 'end_at', k.end_at, 'duration_min', k.duration_min,
    'date', private._local_date(k.start_at), 'time', private._local_time(k.start_at), 'end_time', private._local_time(k.end_at),
    'customer_name', k.customer_name, 'customer_phone', k.customer_phone, 'note', k.note,
    'price_total', k.price_total, 'deposit_base', k.deposit_base, 'deposit_amount', k.deposit_amount,
    'approve_deadline', k.approve_deadline, 'pay_deadline', k.pay_deadline,
    'payer_name', k.payer_name, 'claimed_at', k.claimed_at, 'paid_via', k.paid_via, 'confirmed_at', k.confirmed_at,
    'decided_at', k.decided_at, 'created_at', k.created_at, 'updated_at', k.updated_at,
    'payment_event', (SELECT jsonb_build_object('id', e.id, 'source', e.source, 'origin', e.origin, 'body', e.body,
                                                'amount', e.amount, 'payer', e.payer, 'received_at', e.received_at)
                        FROM private.payment_events e WHERE e.id = k.payment_event_id))
  FROM private.bookings k
  JOIN private.branches b ON b.id = k.branch_id
  JOIN private.offerings o ON o.id = k.offering_id
  WHERE k.id = p_id
$$;

-- ═════════ الموقع (من غير حساب) ═════════

CREATE OR REPLACE FUNCTION public.health() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = private, pg_temp AS $$
  SELECT jsonb_build_object('ok', EXISTS (SELECT 1 FROM private.settings), 'time', now())
$$;

CREATE OR REPLACE FUNCTION public.web_catalog() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE s private.settings;
BEGIN
  IF NOT private._ip_rate_ok('catalog', 600, interval '1 hour') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rate_limited');
  END IF;
  SELECT * INTO s FROM private.settings WHERE id = 1;
  RETURN jsonb_build_object(
    'ok', true,
    'booking_enabled', s.booking_enabled, 'closed_message', s.closed_message, 'deposit_policy', s.deposit_policy,
    'show_prices', s.show_prices,
    'approve_minutes', s.approve_minutes, 'pay_minutes', s.pay_minutes, 'slot_minutes', s.slot_minutes,
    'min_duration_min', s.min_duration_min, 'max_duration_min', s.max_duration_min,
    'max_days_ahead', s.max_days_ahead, 'min_lead_minutes', s.min_lead_minutes,
    'today', private._local_date(now()),
    'branches', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', b.id, 'slug', b.slug, 'name', b.name, 'address', b.address, 'maps_url', b.maps_url,
        'phone', b.phone, 'whatsapp', b.whatsapp, 'hours_text', b.hours_text, 'open_24h', b.open_24h,
        'open_time', to_char(b.open_time, 'HH24:MI'), 'close_time', to_char(b.close_time, 'HH24:MI'),
        'photos', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                              'path', p.path, 'caption', p.caption,
                              'version', floor(extract(epoch FROM p.updated_at) * 1000)::bigint)
                              ORDER BY p.sort, p.created_at)
                              FROM private.branch_photos p WHERE p.branch_id = b.id), '[]'::jsonb),
        'offerings', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                  'id', o.id, 'kind', o.kind, 'name', o.name, 'details', o.details, 'units', o.units,
                                  'max_per_booking', LEAST(o.max_per_booking, o.units),
                                  'price_per_hour', CASE WHEN s.show_prices THEN o.price_per_hour END,
                                  'deposit', o.deposit) ORDER BY o.sort, o.created_at)
                                 FROM private.offerings o WHERE o.branch_id = b.id AND o.is_active AND o.units > 0), '[]'::jsonb)
      ) ORDER BY b.sort, b.created_at)
      FROM private.branches b WHERE b.is_active), '[]'::jsonb));
END $$;

CREATE OR REPLACE FUNCTION public.web_slots(p_offering uuid, p_date date, p_duration_min int, p_units int DEFAULT 1) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE
  s private.settings;
  o private.offerings;
  v_today date := (now() AT TIME ZONE 'Africa/Cairo')::date;
  t timestamp;
  v_start timestamptz;
  v_end timestamptz;
  v_slots text[] := '{}';
BEGIN
  IF NOT private._ip_rate_ok('slots', 900, interval '1 hour') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rate_limited');
  END IF;
  PERFORM private._expire();
  SELECT * INTO s FROM private.settings WHERE id = 1;
  SELECT o2.* INTO o FROM private.offerings o2 JOIN private.branches b ON b.id = o2.branch_id
   WHERE o2.id = p_offering AND o2.is_active AND b.is_active;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  IF p_duration_min IS NULL OR p_duration_min < s.min_duration_min OR p_duration_min > s.max_duration_min
     OR p_duration_min % s.slot_minutes <> 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_duration');
  END IF;
  IF p_units IS NULL OR p_units < 1 OR p_units > LEAST(o.max_per_booking, o.units) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_units');
  END IF;
  IF p_date IS NULL OR p_date < v_today OR p_date > v_today + s.max_days_ahead THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_date');
  END IF;

  t := p_date::timestamp;
  WHILE t < p_date::timestamp + interval '1 day' LOOP
    v_start := t AT TIME ZONE 'Africa/Cairo';
    v_end := v_start + make_interval(mins => p_duration_min);
    IF v_start >= now() + make_interval(mins => s.min_lead_minutes)
       AND private._fits_hours(o.branch_id, v_start, v_end)
       AND private._peak_units(o.id, v_start, v_end) + p_units <= o.units THEN
      v_slots := v_slots || to_char(t, 'HH24:MI');
    END IF;
    t := t + make_interval(mins => s.slot_minutes);
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'booking_enabled', s.booking_enabled, 'slots', to_jsonb(v_slots));
END $$;

CREATE OR REPLACE FUNCTION private._is_blocked(p_phone text, p_device_hash text, p_ip text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = private, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1 FROM private.blocks
     WHERE (expires_at IS NULL OR expires_at > now())
       AND ((kind = 'phone' AND value = p_phone)
         OR (kind = 'device' AND value = p_device_hash)
         OR (kind = 'ip' AND value = p_ip)))
$$;

-- النسخة القديمة (من غير p_device) — PostgREST بيلخبط لو الاتنين موجودين
DROP FUNCTION IF EXISTS public.web_create_booking(uuid, date, text, int, int, text, text, text);
CREATE OR REPLACE FUNCTION public.web_create_booking(p_offering uuid, p_date date, p_time text, p_duration_min int,
                                                     p_units int, p_name text, p_phone text, p_note text DEFAULT NULL,
                                                     p_device text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE
  s private.settings;
  o private.offerings;
  v_today date := (now() AT TIME ZONE 'Africa/Cairo')::date;
  v_name text := private._clean_text(p_name, 40);
  v_phone text := private._clean_phone(p_phone);
  v_note text := private._clean_text(p_note, 200);
  v_start timestamptz;
  v_end timestamptz;
  v_mins int;
  v_code text;
  v_token text;
  v_id uuid;
  i int := 0;
BEGIN
  IF NOT private._ip_rate_ok('create', 6, interval '1 hour') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rate_limited');
  END IF;
  PERFORM private._expire();
  SELECT * INTO s FROM private.settings WHERE id = 1;
  IF NOT s.booking_enabled THEN RETURN jsonb_build_object('ok', false, 'error', 'booking_closed', 'message', s.closed_message); END IF;
  IF v_name IS NULL OR length(v_name) < 2 THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_name'); END IF;
  IF v_phone IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_phone'); END IF;
  IF private._is_blocked(v_phone, CASE WHEN length(p_device) BETWEEN 16 AND 100 THEN private._token_hash(p_device) END,
                         private._client_ip()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'blocked');
  END IF;
  IF COALESCE(p_time, '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_time'); END IF;

  SELECT o2.* INTO o FROM private.offerings o2 JOIN private.branches b ON b.id = o2.branch_id
   WHERE o2.id = p_offering AND o2.is_active AND b.is_active;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  -- حجزين في نفس الوقت على نفس النوع مايعدّوش العدد
  PERFORM pg_advisory_xact_lock(hashtextextended('maka_offering_' || o.id::text, 0));

  IF p_duration_min IS NULL OR p_duration_min < s.min_duration_min OR p_duration_min > s.max_duration_min
     OR p_duration_min % s.slot_minutes <> 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_duration');
  END IF;
  IF p_units IS NULL OR p_units < 1 OR p_units > LEAST(o.max_per_booking, o.units) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_units');
  END IF;
  IF p_date IS NULL OR p_date < v_today OR p_date > v_today + s.max_days_ahead THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_date');
  END IF;
  v_mins := split_part(p_time, ':', 1)::int * 60 + split_part(p_time, ':', 2)::int;
  IF v_mins % s.slot_minutes <> 0 THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_time'); END IF;

  v_start := (p_date + p_time::time) AT TIME ZONE 'Africa/Cairo';
  v_end := v_start + make_interval(mins => p_duration_min);
  IF v_start < now() + make_interval(mins => s.min_lead_minutes) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'too_soon');
  END IF;
  IF NOT private._fits_hours(o.branch_id, v_start, v_end) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'closed_hours');
  END IF;

  -- نفس الموبايل: حجزين شغالين بالكتير + 5 طلبات في اليوم
  IF (SELECT count(*) FROM private.bookings WHERE customer_phone = v_phone
        AND status IN ('pending', 'awaiting_payment', 'payment_claimed', 'confirmed') AND end_at > now()) >= 2 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'phone_active_limit');
  END IF;
  IF (SELECT count(*) FROM private.bookings WHERE customer_phone = v_phone AND created_at > now() - interval '1 day') >= 5 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'phone_daily_limit');
  END IF;

  IF private._peak_units(o.id, v_start, v_end) + p_units > o.units THEN
    RETURN jsonb_build_object('ok', false, 'error', 'full');
  END IF;

  LOOP
    v_code := (100000 + floor(random() * 900000))::int::text;
    EXIT WHEN NOT EXISTS (SELECT 1 FROM private.bookings WHERE code = v_code);
    i := i + 1;
    IF i > 20 THEN RAISE EXCEPTION 'code_generation_failed'; END IF;
  END LOOP;
  v_token := private._new_token();

  INSERT INTO private.bookings (code, token_hash, branch_id, offering_id, units, start_at, end_at, duration_min,
                                customer_name, customer_phone, note, price_total, deposit_base, approve_deadline, ip, device_hash)
  VALUES (v_code, private._token_hash(v_token), o.branch_id, o.id, p_units, v_start, v_end, p_duration_min,
          v_name, v_phone, v_note, round(o.price_per_hour * p_units * p_duration_min / 60.0, 2), o.deposit,
          LEAST(now() + make_interval(mins => s.approve_minutes), v_start), private._client_ip(),
          CASE WHEN length(p_device) BETWEEN 16 AND 100 THEN private._token_hash(p_device) END)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'token', v_token, 'code', v_code);
END $$;

CREATE OR REPLACE FUNCTION public.web_booking_status(p_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE
  s private.settings;
  k private.bookings;
  v_branch private.branches;
  v_off private.offerings;
BEGIN
  IF NOT private._ip_rate_ok('status', 1500, interval '1 hour') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rate_limited');
  END IF;
  PERFORM private._expire();
  SELECT * INTO k FROM private.bookings WHERE token_hash = private._token_hash(p_token);
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  SELECT * INTO s FROM private.settings WHERE id = 1;
  SELECT * INTO v_branch FROM private.branches WHERE id = k.branch_id;
  SELECT * INTO v_off FROM private.offerings WHERE id = k.offering_id;
  RETURN jsonb_build_object('ok', true, 'booking', jsonb_build_object(
    'code', k.code, 'status', k.status, 'reason', k.reason,
    'customer_name', split_part(COALESCE(k.customer_name, ''), ' ', 1),
    'branch', jsonb_build_object('name', v_branch.name, 'address', v_branch.address, 'maps_url', v_branch.maps_url,
                                 'phone', v_branch.phone, 'whatsapp', v_branch.whatsapp),
    'offering', jsonb_build_object('name', v_off.name, 'kind', v_off.kind),
    'units', k.units, 'date', private._local_date(k.start_at), 'time', private._local_time(k.start_at),
    'end_time', private._local_time(k.end_at), 'duration_min', k.duration_min,
    'price_total', CASE WHEN s.show_prices THEN k.price_total END, 'deposit', COALESCE(k.deposit_amount, k.deposit_base),
    'deposit_policy', s.deposit_policy,
    'approve_seconds_left', CASE WHEN k.status = 'pending' THEN GREATEST(0, floor(extract(epoch FROM k.approve_deadline - now())))::int END,
    'pay_seconds_left', CASE WHEN k.status = 'awaiting_payment' THEN GREATEST(0, floor(extract(epoch FROM k.pay_deadline - now())))::int END,
    'payer_name', k.payer_name,
    'payment', CASE WHEN k.status IN ('awaiting_payment', 'payment_claimed') THEN jsonb_build_object(
                 'instapay_address', s.instapay_address, 'instapay_phone', s.instapay_phone,
                 'telda_handle', s.telda_handle, 'wallet_phone', s.wallet_phone, 'note', s.pay_note) END
  ));
END $$;

CREATE OR REPLACE FUNCTION public.web_claim_paid(p_token text, p_payer_name text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE
  k private.bookings;
  v_payer text := private._clean_text(p_payer_name, 60);
  e_id bigint;
BEGIN
  IF NOT private._ip_rate_ok('claim', 30, interval '1 hour') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rate_limited');
  END IF;
  PERFORM private._expire();
  SELECT * INTO k FROM private.bookings WHERE token_hash = private._token_hash(p_token) FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  IF k.status = 'confirmed' THEN RETURN jsonb_build_object('ok', true, 'status', 'confirmed'); END IF;
  IF k.status NOT IN ('awaiting_payment', 'payment_claimed') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_state', 'status', k.status);
  END IF;
  IF v_payer IS NULL OR length(v_payer) < 2 THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_payer'); END IF;
  UPDATE private.bookings SET status = 'payment_claimed', payer_name = v_payer,
         claimed_at = COALESCE(claimed_at, now()), updated_at = now()
   WHERE id = k.id;

  -- لو التحويل وصل قبلها ومااتعرفش (مبلغين زي بعض) → نجرب تاني بالاسم
  FOR e_id IN SELECT id FROM private.payment_events
               WHERE result IN ('unmatched', 'ambiguous') AND amount = k.deposit_amount
                 AND received_at >= k.decided_at - interval '5 minutes'
               ORDER BY received_at LOOP
    IF (private._match_event(e_id) ->> 'result') = 'matched'
       AND (SELECT status FROM private.bookings WHERE id = k.id) = 'confirmed' THEN
      RETURN jsonb_build_object('ok', true, 'status', 'confirmed');
    END IF;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'status', (SELECT status FROM private.bookings WHERE id = k.id));
END $$;

CREATE OR REPLACE FUNCTION public.web_cancel_booking(p_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE k private.bookings;
BEGIN
  IF NOT private._ip_rate_ok('cancel', 20, interval '1 hour') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rate_limited');
  END IF;
  SELECT * INTO k FROM private.bookings WHERE token_hash = private._token_hash(p_token) FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  -- بعد ما الفلوس تتحوّل: الإلغاء مع المحل نفسه (تليفون/واتساب)
  IF k.status IN ('payment_claimed', 'confirmed') THEN RETURN jsonb_build_object('ok', false, 'error', 'call_store'); END IF;
  IF k.status NOT IN ('pending', 'awaiting_payment') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_state', 'status', k.status);
  END IF;
  UPDATE private.bookings SET status = 'cancelled', reason = 'العميل لغى الطلب', updated_at = now() WHERE id = k.id;
  RETURN jsonb_build_object('ok', true);
END $$;

-- ═════════ موبايل المحل (خدمة الخلفية — توكن جهاز) ═════════

CREATE OR REPLACE FUNCTION public.device_pulse(p_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE
  v_dev uuid;
  s private.settings;
BEGIN
  IF NOT private._ip_rate_ok('device', 3000, interval '1 hour') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rate_limited');
  END IF;
  v_dev := private._device(p_token);
  IF v_dev IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_device'); END IF;
  PERFORM private._expire();
  SELECT * INTO s FROM private.settings WHERE id = 1;
  RETURN jsonb_build_object(
    'ok', true, 'server_time', now(),
    'pending', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', id, 'code', code) ORDER BY created_at)
                           FROM private.bookings WHERE status = 'pending'), '[]'::jsonb),
    'claimed', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', id, 'code', code) ORDER BY claimed_at)
                           FROM private.bookings WHERE status = 'payment_claimed'), '[]'::jsonb),
    'notif_packages', to_jsonb(s.notif_packages), 'sms_senders', to_jsonb(s.sms_senders),
    'auto_notifications', s.auto_confirm_notifications, 'auto_sms', s.auto_confirm_sms);
END $$;

CREATE OR REPLACE FUNCTION public.device_ingest_payment(p_token text, p_source text, p_origin text, p_title text, p_body text,
                                                        p_amount numeric, p_payer text, p_received_at timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE v_dev uuid;
BEGIN
  IF NOT private._ip_rate_ok('device', 3000, interval '1 hour') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rate_limited');
  END IF;
  v_dev := private._device(p_token);
  IF v_dev IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_device'); END IF;
  PERFORM private._expire();
  RETURN private._ingest(v_dev, p_source, p_origin, p_title, p_body, p_amount, p_payer, p_received_at);
END $$;

-- ═════════ تطبيق الأدمن ═════════

CREATE OR REPLACE FUNCTION public.admin_me() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = private, pg_temp AS $$
  SELECT jsonb_build_object('is_admin', a.user_id IS NOT NULL, 'name', a.name, 'server_time', now())
    FROM (SELECT 1) one LEFT JOIN private.admins a ON a.user_id = auth.uid()
$$;

CREATE OR REPLACE FUNCTION public.admin_pulse() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
BEGIN
  PERFORM private._require_admin();
  PERFORM private._expire();
  RETURN jsonb_build_object(
    'server_time', now(),
    'pending', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', id, 'code', code) ORDER BY created_at)
                           FROM private.bookings WHERE status = 'pending'), '[]'::jsonb),
    'claimed', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', id, 'code', code) ORDER BY claimed_at)
                           FROM private.bookings WHERE status = 'payment_claimed'), '[]'::jsonb),
    'awaiting_count', (SELECT count(*) FROM private.bookings WHERE status = 'awaiting_payment'),
    'unmatched_events', (SELECT count(*) FROM private.payment_events
                          WHERE result IN ('unmatched', 'ambiguous') AND created_at > now() - interval '1 day'),
    'last_change', (SELECT max(updated_at) FROM private.bookings));
END $$;

CREATE OR REPLACE FUNCTION public.admin_bookings(p_scope text, p_branch uuid DEFAULT NULL, p_limit int DEFAULT 200) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE v_today date := (now() AT TIME ZONE 'Africa/Cairo')::date;
BEGIN
  PERFORM private._require_admin();
  PERFORM private._expire();
  RETURN COALESCE((
    SELECT jsonb_agg(private._booking_json(x.id) ORDER BY x.ord1, x.ord2)
      FROM (
        SELECT k.id,
               CASE WHEN p_scope = 'action' THEN
                      CASE k.status WHEN 'pending' THEN 0 WHEN 'payment_claimed' THEN 1 ELSE 2 END
                    ELSE 0 END AS ord1,
               CASE WHEN p_scope IN ('history') THEN -extract(epoch FROM k.created_at)
                    WHEN p_scope = 'action' THEN extract(epoch FROM k.created_at)
                    ELSE extract(epoch FROM k.start_at) END AS ord2
          FROM private.bookings k
         WHERE (p_branch IS NULL OR k.branch_id = p_branch)
           AND CASE p_scope
                 WHEN 'action' THEN k.status IN ('pending', 'payment_claimed', 'awaiting_payment')
                 WHEN 'today' THEN (k.start_at AT TIME ZONE 'Africa/Cairo')::date = v_today
                                   AND k.status IN ('confirmed', 'completed', 'no_show', 'payment_claimed', 'awaiting_payment')
                 WHEN 'upcoming' THEN k.status = 'confirmed' AND k.end_at > now()
                 ELSE true
               END
         ORDER BY CASE WHEN p_scope = 'history' THEN k.created_at END DESC NULLS LAST, k.start_at
         LIMIT LEAST(GREATEST(COALESCE(p_limit, 200), 1), 500)
      ) x), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION public.admin_booking(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
BEGIN
  PERFORM private._require_admin();
  RETURN private._booking_json(p_id);
END $$;

CREATE OR REPLACE FUNCTION public.admin_decide(p_id uuid, p_accept boolean, p_reason text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE
  s private.settings;
  k private.bookings;
  o private.offerings;
  v_amount numeric(10,2);
  i int := 0;
BEGIN
  PERFORM private._require_admin();
  PERFORM private._expire();
  SELECT * INTO k FROM private.bookings WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  IF k.status <> 'pending' THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_state', 'status', k.status); END IF;

  IF NOT p_accept THEN
    UPDATE private.bookings SET status = 'rejected', reason = COALESCE(private._clean_text(p_reason, 200), 'الميعاد ده مش متاح'),
           decided_at = now(), decided_by = auth.uid(), updated_at = now()
     WHERE id = k.id;
    RETURN jsonb_build_object('ok', true, 'status', 'rejected');
  END IF;

  SELECT * INTO s FROM private.settings WHERE id = 1;
  SELECT * INTO o FROM private.offerings WHERE id = k.offering_id;
  PERFORM pg_advisory_xact_lock(hashtextextended('maka_offering_' || o.id::text, 0));
  IF private._peak_units(o.id, k.start_at, k.end_at, k.id) + k.units > o.units THEN
    RETURN jsonb_build_object('ok', false, 'error', 'full');
  END IF;

  IF k.deposit_base <= 0 THEN
    UPDATE private.bookings SET status = 'confirmed', paid_via = 'none', confirmed_at = now(),
           decided_at = now(), decided_by = auth.uid(), updated_at = now()
     WHERE id = k.id;
    RETURN jsonb_build_object('ok', true, 'status', 'confirmed');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('maka_deposit_amount', 0));
  v_amount := k.deposit_base;
  IF s.unique_amount THEN
    WHILE i < 50 AND EXISTS (SELECT 1 FROM private.bookings
                              WHERE id <> k.id AND status IN ('awaiting_payment', 'payment_claimed')
                                AND deposit_amount = v_amount) LOOP
      v_amount := v_amount + 1;
      i := i + 1;
    END LOOP;
  END IF;
  UPDATE private.bookings SET status = 'awaiting_payment', deposit_amount = v_amount,
         pay_deadline = now() + make_interval(mins => s.pay_minutes),
         decided_at = now(), decided_by = auth.uid(), reason = NULL, updated_at = now()
   WHERE id = k.id;
  RETURN jsonb_build_object('ok', true, 'status', 'awaiting_payment', 'deposit_amount', v_amount);
END $$;

-- تأكيد يدوي (مفيش شبكة على موبايل المحل / الإشعار ماوصلش) — بعد ما الأدمن يشوف الفلوس بعينه
CREATE OR REPLACE FUNCTION public.admin_confirm_payment(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE k private.bookings; o private.offerings;
BEGIN
  PERFORM private._require_admin();
  PERFORM private._expire();
  SELECT * INTO k FROM private.bookings WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  IF k.status = 'confirmed' THEN RETURN jsonb_build_object('ok', true, 'status', 'confirmed'); END IF;
  IF k.status NOT IN ('awaiting_payment', 'payment_claimed', 'expired') OR k.decided_at IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_state', 'status', k.status);
  END IF;
  IF k.status = 'expired' THEN
    SELECT * INTO o FROM private.offerings WHERE id = k.offering_id;
    PERFORM pg_advisory_xact_lock(hashtextextended('maka_offering_' || o.id::text, 0));
    IF private._peak_units(o.id, k.start_at, k.end_at, k.id) + k.units > o.units THEN
      RETURN jsonb_build_object('ok', false, 'error', 'full');
    END IF;
  END IF;
  UPDATE private.bookings SET status = 'confirmed', paid_via = 'manual', confirmed_at = now(), reason = NULL,
         decided_by = COALESCE(decided_by, auth.uid()), updated_at = now()
   WHERE id = k.id;
  RETURN jsonb_build_object('ok', true, 'status', 'confirmed');
END $$;

CREATE OR REPLACE FUNCTION public.admin_set_status(p_id uuid, p_status text, p_reason text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE k private.bookings;
BEGIN
  PERFORM private._require_admin();
  SELECT * INTO k FROM private.bookings WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  IF NOT (
       (p_status = 'rejected'  AND k.status IN ('awaiting_payment', 'payment_claimed'))
    OR (p_status = 'cancelled' AND k.status IN ('pending', 'awaiting_payment', 'payment_claimed', 'confirmed'))
    OR (p_status IN ('completed', 'no_show') AND k.status = 'confirmed')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_state', 'status', k.status);
  END IF;
  UPDATE private.bookings
     SET status = p_status,
         reason = CASE WHEN p_status IN ('rejected', 'cancelled')
                       THEN COALESCE(private._clean_text(p_reason, 200),
                                     CASE p_status WHEN 'rejected' THEN 'الـ deposit ماوصلش' ELSE 'المحل لغى الحجز' END)
                       ELSE reason END,
         decided_by = COALESCE(decided_by, auth.uid()), updated_at = now()
   WHERE id = k.id;
  RETURN jsonb_build_object('ok', true, 'status', p_status);
END $$;

CREATE OR REPLACE FUNCTION public.admin_extend_payment(p_id uuid, p_minutes int) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE k private.bookings; o private.offerings;
BEGIN
  PERFORM private._require_admin();
  IF p_minutes IS NULL OR p_minutes < 1 OR p_minutes > 240 THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_minutes'); END IF;
  SELECT * INTO k FROM private.bookings WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  IF NOT (k.status = 'awaiting_payment' OR (k.status = 'expired' AND k.decided_at IS NOT NULL AND k.deposit_amount IS NOT NULL)) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_state', 'status', k.status);
  END IF;
  IF k.status = 'expired' THEN
    SELECT * INTO o FROM private.offerings WHERE id = k.offering_id;
    PERFORM pg_advisory_xact_lock(hashtextextended('maka_offering_' || o.id::text, 0));
    IF private._peak_units(o.id, k.start_at, k.end_at, k.id) + k.units > o.units THEN
      RETURN jsonb_build_object('ok', false, 'error', 'full');
    END IF;
  END IF;
  UPDATE private.bookings SET status = 'awaiting_payment', reason = NULL,
         pay_deadline = GREATEST(COALESCE(pay_deadline, now()), now()) + make_interval(mins => p_minutes), updated_at = now()
   WHERE id = k.id;
  RETURN jsonb_build_object('ok', true, 'status', 'awaiting_payment');
END $$;

CREATE OR REPLACE FUNCTION public.admin_payment_events(p_limit int DEFAULT 100) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
BEGIN
  PERFORM private._require_admin();
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'id', e.id, 'source', e.source, 'origin', e.origin, 'title', e.title, 'body', e.body,
             'amount', e.amount, 'payer', e.payer, 'received_at', e.received_at, 'result', e.result,
             'booking_id', e.booking_id, 'booking_code', k.code, 'device', d.name) ORDER BY e.received_at DESC)
      FROM (SELECT * FROM private.payment_events ORDER BY received_at DESC
             LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 300)) e
      LEFT JOIN private.bookings k ON k.id = e.booking_id
      LEFT JOIN private.devices d ON d.id = e.device_id), '[]'::jsonb);
END $$;

-- ربط تحويل بحجز يدويًا (مبلغين زي بعض / العميل حوّل مبلغ غلط)
CREATE OR REPLACE FUNCTION public.admin_link_payment(p_event bigint, p_booking uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE e private.payment_events; k private.bookings; o private.offerings;
BEGIN
  PERFORM private._require_admin();
  PERFORM private._expire();
  SELECT * INTO e FROM private.payment_events WHERE id = p_event FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  IF e.result IN ('matched', 'linked') THEN RETURN jsonb_build_object('ok', false, 'error', 'already_linked'); END IF;
  SELECT * INTO k FROM private.bookings WHERE id = p_booking FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  IF k.status NOT IN ('awaiting_payment', 'payment_claimed', 'expired') OR k.decided_at IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_state', 'status', k.status);
  END IF;
  IF k.status = 'expired' THEN
    SELECT * INTO o FROM private.offerings WHERE id = k.offering_id;
    PERFORM pg_advisory_xact_lock(hashtextextended('maka_offering_' || o.id::text, 0));
    IF private._peak_units(o.id, k.start_at, k.end_at, k.id) + k.units > o.units THEN
      RETURN jsonb_build_object('ok', false, 'error', 'full');
    END IF;
  END IF;
  PERFORM private._confirm_by_event(k.id, e.id, e.source);
  UPDATE private.payment_events SET result = 'linked', booking_id = k.id WHERE id = e.id;
  RETURN jsonb_build_object('ok', true, 'status', 'confirmed');
END $$;

CREATE OR REPLACE FUNCTION public.admin_get_settings() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
BEGIN
  PERFORM private._require_admin();
  RETURN (SELECT to_jsonb(s) - 'id' FROM private.settings s WHERE id = 1);
END $$;

CREATE OR REPLACE FUNCTION public.admin_update_settings(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
BEGIN
  PERFORM private._require_admin();
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_input'); END IF;
  UPDATE private.settings SET
    booking_enabled = COALESCE((p ->> 'booking_enabled')::boolean, booking_enabled),
    closed_message = COALESCE(private._clean_text(p ->> 'closed_message', 300), closed_message),
    deposit_policy = COALESCE(private._clean_text(p ->> 'deposit_policy', 600), deposit_policy),
    approve_minutes = COALESCE((p ->> 'approve_minutes')::int, approve_minutes),
    pay_minutes = COALESCE((p ->> 'pay_minutes')::int, pay_minutes),
    unique_amount = COALESCE((p ->> 'unique_amount')::boolean, unique_amount),
    min_lead_minutes = COALESCE((p ->> 'min_lead_minutes')::int, min_lead_minutes),
    max_days_ahead = COALESCE((p ->> 'max_days_ahead')::int, max_days_ahead),
    slot_minutes = COALESCE((p ->> 'slot_minutes')::int, slot_minutes),
    min_duration_min = COALESCE((p ->> 'min_duration_min')::int, min_duration_min),
    max_duration_min = COALESCE((p ->> 'max_duration_min')::int, max_duration_min),
    instapay_address = CASE WHEN p ? 'instapay_address' THEN private._clean_text(p ->> 'instapay_address', 80) ELSE instapay_address END,
    instapay_phone = CASE WHEN p ? 'instapay_phone' THEN private._clean_any_phone(p ->> 'instapay_phone') ELSE instapay_phone END,
    telda_handle = CASE WHEN p ? 'telda_handle' THEN private._clean_text(p ->> 'telda_handle', 60) ELSE telda_handle END,
    wallet_phone = CASE WHEN p ? 'wallet_phone' THEN private._clean_any_phone(p ->> 'wallet_phone') ELSE wallet_phone END,
    pay_note = CASE WHEN p ? 'pay_note' THEN private._clean_text(p ->> 'pay_note', 300) ELSE pay_note END,
    auto_confirm_notifications = COALESCE((p ->> 'auto_confirm_notifications')::boolean, auto_confirm_notifications),
    auto_confirm_sms = COALESCE((p ->> 'auto_confirm_sms')::boolean, auto_confirm_sms),
    notif_packages = CASE WHEN jsonb_typeof(p -> 'notif_packages') = 'array' THEN
      ARRAY(SELECT DISTINCT btrim(x) FROM jsonb_array_elements_text(p -> 'notif_packages') x
             WHERE btrim(x) ~ '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$' AND length(btrim(x)) <= 100)
      ELSE notif_packages END,
    sms_senders = CASE WHEN jsonb_typeof(p -> 'sms_senders') = 'array' THEN
      ARRAY(SELECT DISTINCT btrim(x) FROM jsonb_array_elements_text(p -> 'sms_senders') x
             WHERE btrim(x) ~ '[A-Za-z]' AND length(btrim(x)) BETWEEN 2 AND 20)
      ELSE sms_senders END,
    updated_at = now()
  WHERE id = 1;
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION public.admin_branches() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
BEGIN
  PERFORM private._require_admin();
  RETURN COALESCE((
    SELECT jsonb_agg(to_jsonb(b)
      || jsonb_build_object('open_time', to_char(b.open_time, 'HH24:MI'), 'close_time', to_char(b.close_time, 'HH24:MI'))
      || jsonb_build_object(
        'photos', COALESCE((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.sort, p.created_at)
                              FROM private.branch_photos p WHERE p.branch_id = b.id), '[]'::jsonb),
        'offerings', COALESCE((SELECT jsonb_agg(to_jsonb(o) ORDER BY o.sort, o.created_at)
                                 FROM private.offerings o WHERE o.branch_id = b.id), '[]'::jsonb))
      ORDER BY b.sort, b.created_at)
    FROM private.branches b), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION public.admin_save_branch(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE
  v_id uuid := NULLIF(p ->> 'id', '')::uuid;
  v_name text := private._clean_text(p ->> 'name', 60);
  v_24 boolean := COALESCE((p ->> 'open_24h')::boolean, true);
  v_open time := CASE WHEN v_24 THEN NULL ELSE NULLIF(p ->> 'open_time', '')::time END;
  v_close time := CASE WHEN v_24 THEN NULL ELSE NULLIF(p ->> 'close_time', '')::time END;
BEGIN
  PERFORM private._require_admin();
  IF v_name IS NULL OR length(v_name) < 2 THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_name'); END IF;
  IF NOT v_24 AND (v_open IS NULL OR v_close IS NULL OR v_open = v_close) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_hours');
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO private.branches (slug, name, address, maps_url, phone, whatsapp, hours_text, open_24h, open_time, close_time, is_active, sort)
    VALUES (COALESCE(NULLIF(lower(p ->> 'slug'), ''), 'branch-' || substr(md5(random()::text), 1, 6)),
            v_name, private._clean_text(p ->> 'address', 200), private._clean_url(p ->> 'maps_url'),
            private._clean_any_phone(p ->> 'phone'), private._clean_any_phone(p ->> 'whatsapp'),
            private._clean_text(p ->> 'hours_text', 120), v_24, v_open, v_close,
            COALESCE((p ->> 'is_active')::boolean, true), COALESCE((p ->> 'sort')::int, 0))
    RETURNING id INTO v_id;
  ELSE
    UPDATE private.branches SET
      name = v_name, address = private._clean_text(p ->> 'address', 200), maps_url = private._clean_url(p ->> 'maps_url'),
      phone = private._clean_any_phone(p ->> 'phone'), whatsapp = private._clean_any_phone(p ->> 'whatsapp'),
      hours_text = private._clean_text(p ->> 'hours_text', 120), open_24h = v_24, open_time = v_open, close_time = v_close,
      is_active = COALESCE((p ->> 'is_active')::boolean, is_active), sort = COALESCE((p ->> 'sort')::int, sort)
    WHERE id = v_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $$;

CREATE OR REPLACE FUNCTION public.admin_save_offering(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE
  v_id uuid := NULLIF(p ->> 'id', '')::uuid;
  v_name text := private._clean_text(p ->> 'name', 60);
  v_kind text := p ->> 'kind';
BEGIN
  PERFORM private._require_admin();
  IF v_name IS NULL OR length(v_name) < 2 THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_name'); END IF;
  IF v_kind NOT IN ('pc', 'ps_room') THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_kind'); END IF;
  IF v_id IS NULL THEN
    INSERT INTO private.offerings (branch_id, kind, name, details, units, max_per_booking, price_per_hour, deposit, is_active, sort)
    VALUES ((p ->> 'branch_id')::uuid, v_kind, v_name, private._clean_text(p ->> 'details', 300),
            COALESCE((p ->> 'units')::int, 1), COALESCE((p ->> 'max_per_booking')::int, 1),
            COALESCE((p ->> 'price_per_hour')::numeric, 0), COALESCE((p ->> 'deposit')::numeric, 50),
            COALESCE((p ->> 'is_active')::boolean, true), COALESCE((p ->> 'sort')::int, 0))
    RETURNING id INTO v_id;
  ELSE
    UPDATE private.offerings SET
      kind = v_kind, name = v_name, details = private._clean_text(p ->> 'details', 300),
      units = COALESCE((p ->> 'units')::int, units), max_per_booking = COALESCE((p ->> 'max_per_booking')::int, max_per_booking),
      price_per_hour = COALESCE((p ->> 'price_per_hour')::numeric, price_per_hour),
      deposit = COALESCE((p ->> 'deposit')::numeric, deposit),
      is_active = COALESCE((p ->> 'is_active')::boolean, is_active), sort = COALESCE((p ->> 'sort')::int, sort)
    WHERE id = v_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $$;

CREATE OR REPLACE FUNCTION public.admin_add_photo(p_branch uuid, p_path text, p_caption text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM private._require_admin();
  INSERT INTO private.branch_photos (branch_id, path, caption, sort)
  VALUES (p_branch, p_path, private._clean_text(p_caption, 120),
          COALESCE((SELECT max(sort) + 1 FROM private.branch_photos WHERE branch_id = p_branch), 0))
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $$;

CREATE OR REPLACE FUNCTION public.admin_delete_photo(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE v_path text;
BEGIN
  PERFORM private._require_admin();
  DELETE FROM private.branch_photos WHERE id = p_id RETURNING path INTO v_path;
  RETURN jsonb_build_object('ok', v_path IS NOT NULL, 'path', v_path);
END $$;

-- جهاز جديد (موبايل المحل): التوكن بيظهر مرة واحدة بس، والسيرفر بيحفظ الـ hash
CREATE OR REPLACE FUNCTION public.admin_register_device(p_name text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE v_token text := private._new_token(); v_id uuid;
BEGIN
  PERFORM private._require_admin();
  INSERT INTO private.devices (name, token_hash, created_by)
  VALUES (COALESCE(private._clean_text(p_name, 60), 'موبايل المحل'), private._token_hash(v_token), auth.uid())
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'token', v_token);
END $$;

CREATE OR REPLACE FUNCTION public.admin_devices() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
BEGIN
  PERFORM private._require_admin();
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', id, 'name', name, 'created_at', created_at,
                                                       'last_seen', last_seen, 'revoked_at', revoked_at) ORDER BY created_at DESC)
                     FROM private.devices), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION public.admin_revoke_device(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
BEGIN
  PERFORM private._require_admin();
  UPDATE private.devices SET revoked_at = COALESCE(revoked_at, now()) WHERE id = p_id;
  RETURN jsonb_build_object('ok', FOUND);
END $$;

-- ═════════ الصور (Storage) ═════════
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('photos', 'photos', true, 5242880, ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO UPDATE SET public = true, file_size_limit = 5242880,
  allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp'];

DROP POLICY IF EXISTS maka_photos_admin_select ON storage.objects;
DROP POLICY IF EXISTS maka_photos_admin_insert ON storage.objects;
DROP POLICY IF EXISTS maka_photos_admin_update ON storage.objects;
DROP POLICY IF EXISTS maka_photos_admin_delete ON storage.objects;
CREATE POLICY maka_photos_admin_select ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'photos' AND public.is_admin());
CREATE POLICY maka_photos_admin_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'photos' AND public.is_admin());
CREATE POLICY maka_photos_admin_update ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'photos' AND public.is_admin()) WITH CHECK (bucket_id = 'photos' AND public.is_admin());
CREATE POLICY maka_photos_admin_delete ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'photos' AND public.is_admin());

-- ═════════ الصلاحيات ═════════
-- Supabase بيدي EXECUTE لأي دالة جديدة لـ anon/authenticated تلقائيًا → نقفل الكل ونفتح المطلوب بس
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA private REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.health() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.web_catalog() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.web_slots(uuid, date, int, int) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.web_create_booking(uuid, date, text, int, int, text, text, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.web_booking_status(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.web_claim_paid(text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.web_cancel_booking(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.device_pulse(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.device_ingest_payment(text, text, text, text, text, numeric, text, timestamptz) TO anon, authenticated;

GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_me() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_pulse() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_bookings(text, uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_booking(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_decide(uuid, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_confirm_payment(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_status(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_extend_payment(uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_payment_events(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_link_payment(bigint, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_settings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_settings(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_branches() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_save_branch(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_save_offering(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_add_photo(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_photo(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_register_device(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_devices() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_revoke_device(uuid) TO authenticated;

COMMIT;

-- ═════════ مهام دورية (pg_cron) — لو مش متاحة الدوال نفسها بتعمل expire كل مرة ═════════
DO $$
BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_cron;
  PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('maka_expire', 'maka_purge');
  PERFORM cron.schedule('maka_expire', '* * * * *', 'SELECT private._expire()');
  PERFORM cron.schedule('maka_purge', '30 3 * * *', 'SELECT private._purge()');
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron not available (%): expiry still runs on every call', SQLERRM;
END $$;
