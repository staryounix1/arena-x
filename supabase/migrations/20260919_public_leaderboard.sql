-- Expose only the public statistics needed by the leaderboard.
CREATE OR REPLACE FUNCTION public.get_public_leaderboard()
RETURNS TABLE (
  id UUID,
  username TEXT,
  efootball_id TEXT,
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
    u.efootball_id,
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
