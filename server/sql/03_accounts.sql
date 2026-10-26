-- حسابات الأدمن باسم مستخدم (من غير إيميل حقيقي):
-- اسم المستخدم "admin" = إيميل داخلي admin@users.makka.io (ماحدش بيبعتله حاجة).
-- من جوه التطبيق: تغيير كلمة السر / اسم المستخدم / الاسم ورقم الموبايل (من غير تأكيد).
-- أي حساب بيتعمل أو كلمة سره بتترجّع من السيرفر (create_admin.sh) → لازم يغيّرها أول ما يدخل.
BEGIN;

ALTER TABLE private.admins ADD COLUMN IF NOT EXISTS phone text;
ALTER TABLE private.admins ADD COLUMN IF NOT EXISTS must_change_password boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION private._username(p_email text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT CASE WHEN p_email LIKE '%@users.makka.io' THEN split_part(p_email, '@', 1) ELSE p_email END
$$;

CREATE OR REPLACE FUNCTION public.admin_me() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = private, pg_temp AS $$
  SELECT jsonb_build_object(
    'is_admin', a.user_id IS NOT NULL, 'name', a.name, 'phone', a.phone,
    'must_change_password', COALESCE(a.must_change_password, false),
    'username', private._username((SELECT email FROM auth.users WHERE id = auth.uid())),
    'server_time', now())
  FROM (SELECT 1) one LEFT JOIN private.admins a ON a.user_id = auth.uid()
$$;

CREATE OR REPLACE FUNCTION public.admin_password_changed() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
BEGIN
  PERFORM private._require_admin();
  UPDATE private.admins SET must_change_password = false WHERE user_id = auth.uid();
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION public.admin_update_profile(p_name text, p_phone text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE v_name text := private._clean_text(p_name, 40);
BEGIN
  PERFORM private._require_admin();
  IF v_name IS NULL OR length(v_name) < 2 THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_name'); END IF;
  UPDATE private.admins SET name = v_name, phone = private._clean_any_phone(p_phone) WHERE user_id = auth.uid();
  RETURN jsonb_build_object('ok', true);
END $$;

-- تغيير اسم المستخدم = تغيير الإيميل الداخلي (من غير كود تأكيد)
CREATE OR REPLACE FUNCTION public.admin_set_username(p_username text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE
  v_user text := lower(btrim(COALESCE(p_username, '')));
  v_email text;
BEGIN
  PERFORM private._require_admin();
  IF v_user !~ '^[a-z0-9][a-z0-9_.-]{2,29}$' THEN RETURN jsonb_build_object('ok', false, 'error', 'bad_username'); END IF;
  v_email := v_user || '@users.makka.io';
  IF EXISTS (SELECT 1 FROM auth.users WHERE lower(email) = v_email AND id <> auth.uid()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
  END IF;
  UPDATE auth.users SET email = v_email, updated_at = now() WHERE id = auth.uid();
  UPDATE auth.identities SET identity_data = identity_data || jsonb_build_object('email', v_email), updated_at = now()
   WHERE user_id = auth.uid() AND provider = 'email';
  RETURN jsonb_build_object('ok', true, 'username', v_user);
END $$;

REVOKE ALL ON FUNCTION private._username(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_password_changed() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_update_profile(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_set_username(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_me() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_password_changed() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_profile(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_username(text) TO authenticated;

COMMIT;
