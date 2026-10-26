-- «اللي ظاهر على الموقع» من التطبيق (show_prices نفسه في 01_schema.sql):
-- • admin_set_show_prices: إخفاء/إظهار الأسعار على الموقع خالص
-- • admin_offering_quick: سويتش ظاهر/مخفي + تغيير السعر أو الـ deposit بلمسة
-- • admin_set_deposit_all: deposit واحد لكل الأجهزة والغرف مرة واحدة
BEGIN;

-- النسخة القديمة (من غير الـ deposit) — PostgREST بيلخبط لو الاتنين موجودين؛ النسخ القديمة من التطبيق
-- بتنادي بالأسماء (p_id/p_active/p_price) فبتشتغل على الجديدة عادي
DROP FUNCTION IF EXISTS public.admin_offering_quick(uuid, boolean, numeric);
CREATE OR REPLACE FUNCTION public.admin_offering_quick(p_id uuid, p_active boolean DEFAULT NULL, p_price numeric DEFAULT NULL,
                                                       p_deposit numeric DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
BEGIN
  PERFORM private._require_admin();
  IF p_price IS NOT NULL AND (p_price < 0 OR p_price > 100000) THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_price'); END IF;
  IF p_deposit IS NOT NULL AND (p_deposit < 0 OR p_deposit > 100000) THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_price'); END IF;
  UPDATE private.offerings SET is_active = COALESCE(p_active, is_active), price_per_hour = COALESCE(p_price, price_per_hour),
         deposit = COALESCE(round(p_deposit, 2), deposit)
   WHERE id = p_id;
  RETURN jsonb_build_object('ok', FOUND);
END $$;

-- الـ deposit الجديد بيسري على الطلبات الجديدة بس (اللي اتقبلت بالفعل بتفضل بمبلغها)
CREATE OR REPLACE FUNCTION public.admin_set_deposit_all(p_deposit numeric) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE n int;
BEGIN
  PERFORM private._require_admin();
  IF p_deposit IS NULL OR p_deposit < 0 OR p_deposit > 100000 THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_price'); END IF;
  -- (Supabase بيرفض UPDATE من غير WHERE — safeupdate)
  UPDATE private.offerings SET deposit = round(p_deposit, 2) WHERE id IS NOT NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'updated', n);
END $$;

CREATE OR REPLACE FUNCTION public.admin_set_show_prices(p_show boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
BEGIN
  PERFORM private._require_admin();
  UPDATE private.settings SET show_prices = COALESCE(p_show, true), updated_at = now() WHERE id = 1;
  RETURN jsonb_build_object('ok', true);
END $$;

REVOKE ALL ON FUNCTION public.admin_offering_quick(uuid, boolean, numeric, numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_set_deposit_all(numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_set_show_prices(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_offering_quick(uuid, boolean, numeric, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_deposit_all(numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_show_prices(boolean) TO authenticated;

COMMIT;
