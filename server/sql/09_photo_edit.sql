BEGIN;

ALTER TABLE private.branch_photos
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

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

COMMIT;
