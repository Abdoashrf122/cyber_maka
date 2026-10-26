BEGIN;

ALTER TABLE private.branch_photos
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE private.branch_photos
  ADD COLUMN IF NOT EXISTS original_path text
  CHECK (original_path IS NULL OR original_path ~ '^original/[A-Za-z0-9-]{2,30}/[0-9]+(-[0-9]+)?\.jpg$');

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'private.branch_photos'::regclass
      AND conname = 'branch_photos_original_path_check'
  ) THEN
    ALTER TABLE private.branch_photos
      ADD CONSTRAINT branch_photos_original_path_check
      CHECK (original_path IS NULL OR original_path ~ '^original/[A-Za-z0-9-]{2,30}/[0-9]+(-[0-9]+)?\.jpg$');
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.admin_add_photo_with_original(
  p_branch uuid, p_path text, p_original_path text, p_caption text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM private._require_admin();
  IF p_path IS NULL OR p_path !~ '^[A-Za-z0-9-]{2,30}/[0-9]+-[0-9]+\.jpg$'
     OR p_original_path IS NULL
     OR p_original_path !~ '^original/[A-Za-z0-9-]{2,30}/[0-9]+-[0-9]+\.jpg$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_photo_path');
  END IF;
  INSERT INTO private.branch_photos (branch_id, path, original_path, caption, sort)
  VALUES (
    p_branch, p_path, p_original_path, private._clean_text(p_caption, 120),
    COALESCE((SELECT max(sort) + 1 FROM private.branch_photos WHERE branch_id = p_branch), 0)
  )
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $$;

CREATE OR REPLACE FUNCTION public.admin_set_photo_original(p_id uuid, p_original_path text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
BEGIN
  PERFORM private._require_admin();
  IF p_original_path IS NULL
     OR p_original_path !~ '^original/[A-Za-z0-9-]{2,30}/[0-9]+(-[0-9]+)?\.jpg$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_photo_path');
  END IF;
  UPDATE private.branch_photos
  SET original_path = COALESCE(original_path, p_original_path)
  WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION public.admin_touch_photo(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, pg_temp AS $$
DECLARE v_updated timestamptz;
BEGIN
  PERFORM private._require_admin();
  UPDATE private.branch_photos
  SET updated_at = clock_timestamp()
  WHERE id = p_id
  RETURNING updated_at INTO v_updated;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  RETURN jsonb_build_object('ok', true, 'updated_at', v_updated);
END $$;

REVOKE ALL ON FUNCTION public.admin_touch_photo(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_touch_photo(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_add_photo_with_original(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_add_photo_with_original(uuid, text, text, text) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_set_photo_original(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_photo_original(uuid, text) TO authenticated;

COMMIT;
