-- Match moderation and winner payout approval workflow.

ALTER TABLE public.matches
  ADD COLUMN IF NOT EXISTS payout_status VARCHAR(20) NOT NULL DEFAULT 'PENDING'
    CHECK (payout_status IN ('PENDING', 'APPROVED', 'REJECTED'));
ALTER TABLE public.matches
  ADD COLUMN IF NOT EXISTS payout_note TEXT NOT NULL DEFAULT '';
ALTER TABLE public.matches
  ADD COLUMN IF NOT EXISTS payout_reviewed_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_matches_payout_status
  ON public.matches(payout_status, updated_at DESC);

DROP POLICY IF EXISTS "Match participants and admins can update" ON public.matches;
CREATE POLICY "Match participants and admins can update safely" ON public.matches
  FOR UPDATE
  USING (public.is_admin() OR auth.uid() = creator_id OR auth.uid() = opponent_id)
  WITH CHECK (
    public.is_admin()
    OR (
      (auth.uid() = creator_id OR auth.uid() = opponent_id)
      AND winner_id IS NULL
      AND payout_status = 'PENDING'
    )
  );

CREATE OR REPLACE FUNCTION public.admin_set_match_result(
  match_id_value UUID,
  winner_id_value UUID,
  note_value TEXT DEFAULT ''
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  game public.matches%ROWTYPE;
  selected_winner_name TEXT;
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

  UPDATE public.matches
  SET status = 'COMPLETED',
      winner_id = winner_id_value,
      winner_name = COALESCE(selected_winner_name, 'اللاعب الفائز'),
      payout_status = 'PENDING',
      payout_note = COALESCE(note_value, ''),
      payout_reviewed_at = NULL,
      updated_at = NOW()
  WHERE id = match_id_value;
END;
$$;

CREATE OR REPLACE FUNCTION public.review_match_payout(
  match_id_value UUID,
  approve BOOLEAN,
  note_value TEXT DEFAULT ''
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  game public.matches%ROWTYPE;
  next_balance NUMERIC;
  loser_id UUID;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  SELECT * INTO game
  FROM public.matches
  WHERE id = match_id_value
  FOR UPDATE;

  IF game.id IS NULL OR game.winner_id IS NULL THEN
    RAISE EXCEPTION 'winner must be recorded before payout review';
  END IF;
  IF game.status NOT IN ('COMPLETED', 'DISPUTE') THEN
    RAISE EXCEPTION 'match result is not ready for payout review';
  END IF;
  IF game.payout_status = 'APPROVED' THEN
    RAISE EXCEPTION 'match payout is already approved';
  END IF;

  IF approve THEN
    loser_id := CASE WHEN game.winner_id = game.creator_id THEN game.opponent_id ELSE game.creator_id END;
    UPDATE public.users
    SET balance = balance + game.prize,
        wins = wins + 1,
        updated_at = NOW()
    WHERE id = game.winner_id
    RETURNING balance INTO next_balance;
    IF next_balance IS NULL THEN
      RAISE EXCEPTION 'winner account not found';
    END IF;
    IF loser_id IS NOT NULL THEN
      UPDATE public.users
      SET losses = losses + 1, updated_at = NOW()
      WHERE id = loser_id;
    END IF;
    INSERT INTO public.transactions (user_id, type, description, amount, balance_after)
    VALUES (game.winner_id, 'MATCH_PAYOUT', 'اعتماد جائزة المباراة', game.prize, next_balance);
  END IF;

  UPDATE public.matches
  SET status = CASE WHEN approve THEN 'COMPLETED' ELSE 'DISPUTE' END,
      payout_status = CASE WHEN approve THEN 'APPROVED' ELSE 'REJECTED' END,
      payout_note = COALESCE(note_value, ''),
      payout_reviewed_at = NOW(),
      updated_at = NOW()
  WHERE id = match_id_value;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_set_match_result(UUID, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.review_match_payout(UUID, BOOLEAN, TEXT) TO authenticated;
