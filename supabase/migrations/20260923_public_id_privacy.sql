-- Let players choose whether their eFootball ID is public on the leaderboard.
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS show_efootball_id BOOLEAN NOT NULL DEFAULT FALSE;

DROP FUNCTION IF EXISTS public.get_public_leaderboard();

CREATE OR REPLACE FUNCTION public.get_public_leaderboard()
RETURNS TABLE (
  id UUID,
  username TEXT,
  efootball_id TEXT,
  show_efootball_id BOOLEAN,
  wins INTEGER,
  losses INTEGER,
  favorite_team TEXT,
  favorite_team_logo TEXT
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    u.id,
    u.username,
    CASE
      WHEN COALESCE(u.show_efootball_id, FALSE) THEN u.efootball_id
      WHEN length(u.efootball_id) > 4 THEN left(u.efootball_id, 2) || '****' || right(u.efootball_id, 2)
      ELSE '****'
    END,
    COALESCE(u.show_efootball_id, FALSE),
    u.wins,
    u.losses,
    u.favorite_team,
    u.favorite_team_logo
  FROM public.users AS u
  WHERE COALESCE(u.banned, FALSE) = FALSE
  ORDER BY
    u.wins DESC,
    CASE WHEN u.wins + u.losses > 0 THEN u.wins::NUMERIC / (u.wins + u.losses) ELSE 0 END DESC,
    u.losses ASC,
    u.username ASC;
$$;

REVOKE ALL ON FUNCTION public.get_public_leaderboard() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_leaderboard() TO anon, authenticated;
