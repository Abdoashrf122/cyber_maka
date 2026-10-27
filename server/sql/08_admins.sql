-- الفريق: إضافة أدمن جديد / إعادة كلمة سر / مسح حساب — من داخل التطبيق نفسه.
-- • أي أدمن يقدر يضيف أدمن تاني (اختيار صاحب المشروع)، ويعيد كلمة سر واحد تاني، أو يمسحه.
-- • آخر أدمن مينفعش يتمسح — عشان محدش يقفل الباب على الكل.
-- • الحساب الجديد بيتعمل في auth.users على طول (نفس اللي create_admin.sh بيعمله)،
--   وكلمة السر المؤقتة لازم تتغيّر أول دخول (must_change_password = true).
-- • الأسماء الداخلية <username>@users.makka.io — ماحدش بيبعتلها إيميل.
--
-- ملاحظة مهمة لو GoTrue اتحدّث يوم من الأيام: الإنشاء بيكتب في auth.users/auth.identities
-- بنفس شكل gotrue v2.186 (instance_id = صفر، aud = authenticated، provider_id = user_id).
BEGIN;

-- مين اللي عمل الحساب (للعرض في شاشة «الفريق» بس)
ALTER TABLE private.admins ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

-- كلمة السر مطلوبة، وحد bcrypt الأقصى 72 بايت.
CREATE OR REPLACE FUNCTION private._password_error(p text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog AS $$
BEGIN
  IF p IS NULL OR p = '' OR octet_length(p) > 72 THEN RETURN 'bad_password'; END IF;
  RETURN NULL;
END $$;

-- ═════════ قايمة الفريق ═════════

CREATE OR REPLACE FUNCTION public.admin_team() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = private, pg_temp AS $$
BEGIN
  PERFORM private._require_admin();
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'user_id', a.user_id,
             'username', private._username(u.email),
             'name', a.name,
             'phone', a.phone,
             'must_change_password', a.must_change_password,
             'created_at', a.created_at,
             'created_by_name', c.name,
             'is_me', a.user_id = auth.uid()) ORDER BY a.created_at, a.name)
      FROM private.admins a
      JOIN auth.users u ON u.id = a.user_id
      LEFT JOIN private.admins c ON c.user_id = a.created_by), '[]'::jsonb);
END $$;

-- ═════════ إضافة أدمن ═════════

CREATE OR REPLACE FUNCTION public.admin_create(p_username text, p_name text, p_phone text, p_password text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE
  v_user text := lower(btrim(COALESCE(p_username, '')));
  v_name text := private._clean_text(p_name, 40);
  v_phone text := private._clean_any_phone(p_phone);
  v_email text;
  v_id uuid := gen_random_uuid();
  v_data jsonb;
BEGIN
  PERFORM private._require_admin();
  IF v_user !~ '^[a-z0-9][a-z0-9_.-]{2,29}$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_username');
  END IF;
  IF v_name IS NULL OR length(v_name) < 2 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_name');
  END IF;
  IF private._password_error(p_password) IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_password');
  END IF;

  v_email := v_user || '@users.makka.io';
  IF EXISTS (SELECT 1 FROM auth.users WHERE lower(email) = v_email) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
  END IF;

  BEGIN
    INSERT INTO auth.users (
      instance_id, id, aud, "role", email, encrypted_password, email_confirmed_at,
      confirmation_token, recovery_token, email_change, email_change_token_new,
      email_change_token_current, email_change_confirm_status, phone_change, phone_change_token,
      reauthentication_token, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (
      '00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', v_email,
      extensions.crypt(p_password, extensions.gen_salt('bf', 10)), now(),
      -- التوكنات لازم '' مش NULL: GoTrue بيقرا الأعمدة دي كـ string
      '', '', '', '',
      '', 0, '', '',
      '',
      jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
      '{}'::jsonb, now(), now());
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'error', 'username_taken');
  END;

  -- الهوية (GoTrue بيدوّر عليها بـ provider_id = user_id) — لو النسخة القديمة
  -- من غير provider_id، بنكتبها بالشكل القديم.
  v_data := jsonb_build_object('sub', v_id::text, 'email', v_email, 'email_verified', true);
  BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'auth' AND table_name = 'identities' AND column_name = 'provider_id') THEN
      INSERT INTO auth.identities (id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
      VALUES (gen_random_uuid(), v_id, v_data, 'email', v_id::text, now(), now(), now());
    ELSE
      INSERT INTO auth.identities (id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
      VALUES (v_id::text, v_id, v_data, 'email', now(), now(), now());
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- الهوية مش شرط للدخول بكلمة السر؛ الحساب يشتغل عادي ونلاحظ المشكلة في اللوج
    RAISE WARNING 'maka: email identity insert failed for %: %', v_email, SQLERRM;
  END;

  INSERT INTO private.admins (user_id, name, phone, must_change_password, created_by)
  VALUES (v_id, v_name, v_phone, true, auth.uid());

  RETURN jsonb_build_object('ok', true, 'user_id', v_id, 'username', v_user);
END $$;

-- ═════════ إعادة كلمة السر (الحساب بيفضل زي ما هو) ═════════

CREATE OR REPLACE FUNCTION public.admin_reset_password(p_user uuid, p_password text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
BEGIN
  PERFORM private._require_admin();
  IF p_user = auth.uid() THEN RETURN jsonb_build_object('ok', false, 'error', 'cannot_self'); END IF;
  IF NOT EXISTS (SELECT 1 FROM private.admins WHERE user_id = p_user) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  IF private._password_error(p_password) IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_password');
  END IF;

  UPDATE auth.users SET encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf', 10)),
         updated_at = now()
   WHERE id = p_user;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found'); END IF;
  -- خروج من كل الأجهزة/الجلسات، وأول دخول بالكلمة المؤقتة يغيّرها
  DELETE FROM auth.refresh_tokens WHERE user_id = p_user::text;
  IF to_regclass('auth.sessions') IS NOT NULL THEN
    DELETE FROM auth.sessions WHERE user_id = p_user;
  END IF;
  UPDATE private.admins SET must_change_password = true WHERE user_id = p_user;
  RETURN jsonb_build_object('ok', true);
END $$;

-- ═════════ مسح الحساب ═════════

CREATE OR REPLACE FUNCTION public.admin_remove(p_user uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE v_count int;
BEGIN
  -- قفل بسيط: لو اتنين أدمنز مسحوا بعض في نفس اللحظة، واحد بس يعدّي (وميوقعوش الاتنين)
  LOCK TABLE private.admins IN SHARE ROW EXCLUSIVE MODE;
  PERFORM private._require_admin();
  IF p_user = auth.uid() THEN RETURN jsonb_build_object('ok', false, 'error', 'cannot_self'); END IF;
  IF NOT EXISTS (SELECT 1 FROM private.admins WHERE user_id = p_user) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  SELECT count(*) INTO v_count FROM private.admins;
  IF v_count <= 1 THEN RETURN jsonb_build_object('ok', false, 'error', 'last_admin'); END IF;

  -- موبايلاته المسجّلة تبطل ترن وتقرا التحويلات بعد ما يخرج (التوكن بتاع الجهاز مش تابع لحسابه)
  UPDATE private.devices SET revoked_at = now() WHERE created_by = p_user AND revoked_at IS NULL;
  DELETE FROM auth.refresh_tokens WHERE user_id = p_user::text;
  IF to_regclass('auth.sessions') IS NOT NULL THEN
    DELETE FROM auth.sessions WHERE user_id = p_user;
  END IF;
  DELETE FROM auth.users WHERE id = p_user;  -- private.admins بتتشال معاه (ON DELETE CASCADE)
  RETURN jsonb_build_object('ok', true);
END $$;

REVOKE ALL ON FUNCTION private._password_error(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_team() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_create(text, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_reset_password(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_remove(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_team() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create(text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reset_password(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_remove(uuid) TO authenticated;

COMMIT;
