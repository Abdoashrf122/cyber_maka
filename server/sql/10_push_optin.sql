BEGIN;

CREATE TABLE IF NOT EXISTS private.admin_push_preferences (
  user_id uuid PRIMARY KEY REFERENCES private.admins(user_id) ON DELETE CASCADE,
  receive_orders boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON private.admin_push_preferences FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_push_enabled() RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = private, pg_temp AS $$
BEGIN
  PERFORM private._require_admin();
  RETURN COALESCE((
    SELECT receive_orders
    FROM private.admin_push_preferences
    WHERE user_id = auth.uid()
  ), false);
END $$;

CREATE OR REPLACE FUNCTION public.admin_set_push_enabled(p_enabled boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
BEGIN
  PERFORM private._require_admin();
  IF p_enabled IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_value');
  END IF;
  IF p_enabled AND NOT EXISTS (
    SELECT 1 FROM private.push_config
    WHERE id = 1 AND app_id IS NOT NULL AND api_key IS NOT NULL
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'push_not_configured');
  END IF;
  INSERT INTO private.admin_push_preferences (user_id, receive_orders, updated_at)
  VALUES (auth.uid(), p_enabled, now())
  ON CONFLICT (user_id) DO UPDATE
  SET receive_orders = EXCLUDED.receive_orders, updated_at = EXCLUDED.updated_at;
  RETURN jsonb_build_object('ok', true, 'receive_orders', p_enabled);
END $$;

CREATE OR REPLACE FUNCTION private._push(
  p_kind text, p_title text, p_body text, p_data jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, extensions, pg_temp AS $$
DECLARE
  c private.push_config;
  v_ids text[];
  v_silent boolean := p_kind = 'clear';
BEGIN
  SELECT * INTO c FROM private.push_config WHERE id = 1;
  IF c.app_id IS NULL OR c.api_key IS NULL THEN RETURN; END IF;
  SELECT array_agg(a.user_id::text) INTO v_ids
  FROM private.admins a
  JOIN private.admin_push_preferences p ON p.user_id = a.user_id
  WHERE p.receive_orders;
  IF v_ids IS NULL THEN RETURN; END IF;
  PERFORM net.http_post(
    url := 'https://api.onesignal.com/notifications?c=push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', CASE WHEN c.api_key LIKE 'os_v2_%' THEN 'Key ' ELSE 'Basic ' END || c.api_key),
    body := jsonb_build_object(
      'app_id', c.app_id,
      'target_channel', 'push',
      'include_aliases', jsonb_build_object('external_id', to_jsonb(v_ids)),
      'headings', jsonb_build_object('en', p_title, 'ar', p_title),
      'contents', jsonb_build_object('en', p_body, 'ar', p_body),
      'data', p_data || jsonb_build_object('kind', p_kind),
      'priority', 10,
      'ttl', CASE WHEN v_silent THEN 120 ELSE 3600 END),
    timeout_milliseconds := 5000);
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'push failed: %', SQLERRM;
END $$;

CREATE OR REPLACE FUNCTION public.device_pulse(p_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE
  v_dev uuid;
  v_receive_orders boolean;
  s private.settings;
BEGIN
  IF NOT private._ip_rate_ok('device', 3000, interval '1 hour') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rate_limited');
  END IF;
  v_dev := private._device(p_token);
  IF v_dev IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_device'); END IF;
  SELECT COALESCE(p.receive_orders, false) INTO v_receive_orders
  FROM private.devices d
  LEFT JOIN private.admin_push_preferences p ON p.user_id = d.created_by
  WHERE d.id = v_dev;
  PERFORM private._expire();
  SELECT * INTO s FROM private.settings WHERE id = 1;
  RETURN jsonb_build_object(
    'ok', true, 'server_time', now(), 'receive_orders', COALESCE(v_receive_orders, false),
    'pending', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', id, 'code', code) ORDER BY created_at)
                           FROM private.bookings WHERE status = 'pending'), '[]'::jsonb),
    'claimed', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', id, 'code', code) ORDER BY claimed_at)
                           FROM private.bookings WHERE status = 'payment_claimed'), '[]'::jsonb),
    'notif_packages', to_jsonb(s.notif_packages), 'sms_senders', to_jsonb(s.sms_senders),
    'auto_notifications', s.auto_confirm_notifications, 'auto_sms', s.auto_confirm_sms,
    'new_ring_path', s.new_ring_path, 'new_ring_mode', s.new_ring_mode, 'new_ring_seconds', s.new_ring_seconds,
    'claim_ring_path', s.claim_ring_path, 'claim_ring_mode', s.claim_ring_mode, 'claim_ring_seconds', s.claim_ring_seconds);
END $$;

REVOKE ALL ON FUNCTION public.admin_push_enabled() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_push_enabled() TO authenticated;
REVOKE ALL ON FUNCTION public.admin_set_push_enabled(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_push_enabled(boolean) TO authenticated;

COMMIT;
