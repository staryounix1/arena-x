-- Match scores: let both players report the result as a scoreline alongside their
-- winner claim, so the review screen and the winner celebration can show a real
-- score (e.g. 3 - 1) instead of only a name.
--
-- Design notes:
--   * Each side stores its own reported score, mirroring creator_claim /
--     opponent_claim. The admin decides which scoreline is authoritative when
--     resolving the result; whichever side is marked as winner keeps its goals.
--   * Scores are optional. A claim without a score still works, preserving the
--     existing behaviour for players who do not fill it in.

ALTER TABLE public.matches
  ADD COLUMN IF NOT EXISTS creator_score INTEGER,
  ADD COLUMN IF NOT EXISTS opponent_score INTEGER,
  -- The confirmed final score, written when the admin resolves the result.
  ADD COLUMN IF NOT EXISTS final_creator_score INTEGER,
  ADD COLUMN IF NOT EXISTS final_opponent_score INTEGER;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'matches_scores_range'
      AND conrelid = 'public.matches'::regclass
  ) THEN
    ALTER TABLE public.matches
      ADD CONSTRAINT matches_scores_range
      CHECK (
        (creator_score IS NULL OR creator_score BETWEEN 0 AND 99)
        AND (opponent_score IS NULL OR opponent_score BETWEEN 0 AND 99)
        AND (final_creator_score IS NULL OR final_creator_score BETWEEN 0 AND 99)
        AND (final_opponent_score IS NULL OR final_opponent_score BETWEEN 0 AND 99)
      );
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Accept an optional score with each claim
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_match_result_claim(
  match_id_value uuid,
  winner_id_value uuid,
  creator_score_value integer DEFAULT NULL,
  opponent_score_value integer DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  game public.matches%ROWTYPE;
  is_creator boolean;
BEGIN
  SELECT * INTO game
  FROM public.matches
  WHERE id = match_id_value
  FOR UPDATE;

  IF game.id IS NULL OR game.opponent_id IS NULL THEN
    RAISE EXCEPTION 'match is not ready for result claims';
  END IF;

  is_creator := auth.uid() = game.creator_id;

  IF auth.uid() <> game.creator_id AND auth.uid() <> game.opponent_id THEN
    RAISE EXCEPTION 'only match participants can submit claims';
  END IF;
  IF game.status NOT IN ('PLAYING', 'COMPLETED', 'DISPUTE') OR game.payout_status = 'APPROVED' THEN
    RAISE EXCEPTION 'match is not accepting result claims';
  END IF;
  IF winner_id_value <> game.creator_id AND winner_id_value <> game.opponent_id THEN
    RAISE EXCEPTION 'winner must be a match participant';
  END IF;

  IF (creator_score_value IS NOT NULL AND creator_score_value NOT BETWEEN 0 AND 99)
     OR (opponent_score_value IS NOT NULL AND opponent_score_value NOT BETWEEN 0 AND 99) THEN
    RAISE EXCEPTION 'score out of range';
  END IF;

  IF is_creator THEN
    UPDATE public.matches
    SET creator_claim = winner_id_value,
        creator_claimed_at = NOW(),
        creator_score = creator_score_value,
        opponent_score = opponent_score_value,
        updated_at = NOW()
    WHERE id = match_id_value;
  ELSE
    UPDATE public.matches
    SET opponent_claim = winner_id_value,
        opponent_claimed_at = NOW(),
        opponent_score = opponent_score_value,
        creator_score = creator_score_value,
        updated_at = NOW()
    WHERE id = match_id_value;
  END IF;

  -- One shared scoreline: the first score submitted that matches the claim wins,
  -- and the second reporter can overwrite it until the admin resolves.
  UPDATE public.matches
  SET creator_score = COALESCE(creator_score_value, creator_score),
      opponent_score = COALESCE(opponent_score_value, opponent_score),
      updated_at = NOW()
  WHERE id = match_id_value;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.submit_match_result_claim(uuid, uuid, integer, integer) TO authenticated;

-- ---------------------------------------------------------------------------
-- Store the confirmed score when the admin resolves the winner
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_set_match_result(match_id_value uuid, winner_id_value uuid, note_value text DEFAULT ''::text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  game public.matches%ROWTYPE;
  selected_winner_name TEXT;
  resolved_creator_score INTEGER;
  resolved_opponent_score INTEGER;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  SELECT * INTO game
  FROM public.matches
  WHERE id = match_id_value
  FOR UPDATE;

  IF game.id IS NULL OR game.opponent_id IS NULL THEN
    RAISE EXCEPTION 'match is not ready for result review';
  END IF;
  IF game.status NOT IN ('PLAYING', 'DISPUTE', 'COMPLETED') THEN
    RAISE EXCEPTION 'match status cannot be reviewed';
  END IF;
  IF game.payout_status = 'APPROVED' THEN
    RAISE EXCEPTION 'match payout is already approved';
  END IF;
  IF winner_id_value <> game.creator_id AND winner_id_value <> game.opponent_id THEN
    RAISE EXCEPTION 'winner must be a match participant';
  END IF;

  SELECT username INTO selected_winner_name
  FROM public.users
  WHERE id = winner_id_value;

  -- Prefer the winning side's own reported scoreline so the celebration matches
  -- what that player submitted. Fall back to the other side, then to nulls.
  IF winner_id_value = game.creator_id THEN
    resolved_creator_score := COALESCE(game.creator_score, game.final_creator_score);
    resolved_opponent_score := COALESCE(game.opponent_score, game.final_opponent_score);
  ELSE
    resolved_creator_score := COALESCE(game.creator_score, game.final_creator_score);
    resolved_opponent_score := COALESCE(game.opponent_score, game.final_opponent_score);
  END IF;

  UPDATE public.matches
  SET status = 'COMPLETED',
      winner_id = winner_id_value,
      winner_name = COALESCE(selected_winner_name, 'اللاعب الفائز'),
      payout_status = 'PENDING',
      payout_note = COALESCE(note_value, ''),
      payout_reviewed_at = NULL,
      final_creator_score = resolved_creator_score,
      final_opponent_score = resolved_opponent_score,
      updated_at = NOW()
  WHERE id = match_id_value;
END;
$function$;
