-- البلوك من تطبيق الأدمن (طلبات مزعجة / هزار):
-- • من كارت الحجز: رقم الموبايل + المتصفح اللي حجز منه (+ الشبكة IP اختياري، أسبوع بالكتير)
-- • الطلب ده وأي طلبات مستنية من نفس الرقم/المتصفح بتترفض فورًا — والطلبات الجاية مابتوصلش (مفيش رنة)
-- • قايمة المحظورين: فك البلوك / إضافة رقم بإيدك
BEGIN;

CREATE OR REPLACE FUNCTION public.admin_block_booking(p_booking uuid, p_reason text, p_days int, p_ip boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE
  k private.bookings;
  v_reason text := COALESCE(private._clean_text(p_reason, 120), 'إزعاج');
  v_exp timestamptz := CASE WHEN p_days IS NULL OR p_days <= 0 THEN NULL ELSE now() + make_interval(days => LEAST(p_days, 3650)) END;
  v_rejected int;
BEGIN
  PERFORM private._require_admin();
  SELECT * INTO k FROM private.bookings WHERE id = p_booking;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;

  IF k.customer_phone IS NOT NULL THEN
    INSERT INTO private.blocks (kind, value, reason, booking_code, created_by, expires_at)
    VALUES ('phone', k.customer_phone, v_reason, k.code, auth.uid(), v_exp);
  END IF;
  IF k.device_hash IS NOT NULL THEN
    INSERT INTO private.blocks (kind, value, reason, booking_code, created_by, expires_at)
    VALUES ('device', k.device_hash, v_reason, k.code, auth.uid(), v_exp);
  END IF;
  -- الشبكة: أسبوع بالكتير (ناس تانية ممكن تبقى على نفس الشبكة)
  IF p_ip AND k.ip IS NOT NULL THEN
    INSERT INTO private.blocks (kind, value, reason, booking_code, created_by, expires_at)
    VALUES ('ip', k.ip, v_reason, k.code, auth.uid(), LEAST(COALESCE(v_exp, 'infinity'), now() + interval '7 days'));
  END IF;

  -- الطلب ده + أي طلبات لسه مااتأكدتش من نفس الرقم/المتصفح → مرفوضة
  UPDATE private.bookings SET status = 'rejected', reason = 'الطلب اترفض', decided_at = COALESCE(decided_at, now()),
         decided_by = COALESCE(decided_by, auth.uid()), updated_at = now()
   WHERE status IN ('pending', 'awaiting_payment', 'payment_claimed')
     AND (id = k.id
          OR (k.customer_phone IS NOT NULL AND customer_phone = k.customer_phone)
          OR (k.device_hash IS NOT NULL AND device_hash = k.device_hash));
  GET DIAGNOSTICS v_rejected = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'rejected', v_rejected);
END $$;

CREATE OR REPLACE FUNCTION public.admin_block_phone(p_phone text, p_reason text, p_days int) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE v_phone text := private._clean_phone(p_phone);
BEGIN
  PERFORM private._require_admin();
  IF v_phone IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_phone'); END IF;
  INSERT INTO private.blocks (kind, value, reason, created_by, expires_at)
  VALUES ('phone', v_phone, COALESCE(private._clean_text(p_reason, 120), 'إزعاج'), auth.uid(),
          CASE WHEN p_days IS NULL OR p_days <= 0 THEN NULL ELSE now() + make_interval(days => LEAST(p_days, 3650)) END);
  UPDATE private.bookings SET status = 'rejected', reason = 'الطلب اترفض', updated_at = now()
   WHERE status = 'pending' AND customer_phone = v_phone;
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION public.admin_blocks() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
BEGIN
  PERFORM private._require_admin();
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'id', b.id, 'kind', b.kind,
             -- المتصفح والشبكة بيظهروا كوصف بس (مش القيمة نفسها)
             'value', CASE b.kind WHEN 'phone' THEN b.value WHEN 'device' THEN 'المتصفح اللي حجز منه' ELSE 'الشبكة (IP)' END,
             'reason', b.reason, 'booking_code', b.booking_code, 'created_at', b.created_at, 'expires_at', b.expires_at)
           ORDER BY b.created_at DESC)
      FROM private.blocks b WHERE b.expires_at IS NULL OR b.expires_at > now()), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION public.admin_unblock(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE v_code text;
BEGIN
  PERFORM private._require_admin();
  SELECT booking_code INTO v_code FROM private.blocks WHERE id = p_id;
  -- فك بلوك من حجز = يفك الرقم والمتصفح والشبكة بتوعه مع بعض
  IF v_code IS NOT NULL THEN
    DELETE FROM private.blocks WHERE booking_code = v_code;
  ELSE
    DELETE FROM private.blocks WHERE id = p_id;
  END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

REVOKE ALL ON FUNCTION private._is_blocked(text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_block_booking(uuid, text, int, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_block_phone(text, text, int) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_blocks() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_unblock(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_block_booking(uuid, text, int, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_block_phone(text, text, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_blocks() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_unblock(uuid) TO authenticated;

COMMIT;
