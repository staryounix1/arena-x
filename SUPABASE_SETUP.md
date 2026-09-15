# Supabase Setup Guide for ARENA//X

## 1. Create Supabase Project

1. Open the Supabase dashboard for the project.
2. Copy the project URL and API keys from Project Settings > API:
   - **Project URL**: `https://your-project.supabase.co`
   - **Anon/Public Key**: `eyJ...` (safe to expose in frontend)
   - **Service Role Key**: keep secret; this app does not need it in the browser.

## 2. Apply Database Migration

### Option A: Via Supabase Dashboard (Recommended)
1. Go to your Supabase Dashboard > SQL Editor
2. Create a new query
3. Run `supabase/migrations/20260911_arena.sql` first.
4. Create a second query, paste `supabase/migrations/20260915_remote_arena.sql`, and run it.

The second migration fixes the recursive RLS policies, adds Auth profile creation,
withdrawals, disputes, activity logs, evidence storage, wallet RPCs, and login-by-username.

### Option B: Via Supabase CLI
```bash
# Install Supabase CLI
npm install -g supabase

# Login
supabase login

# Link to your project
supabase link --project-ref YOUR_PROJECT_REF

# Push migration
supabase db push
```

## 3. Configure Environment Variables

Create a `.env` file in the project root:

```env
# Frontend (Vite) - safe to expose
VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-key-here

```

For Vercel, add only `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` in
Project Settings > Environment Variables, then redeploy. Never add the service-role
key to Vite variables, GitHub, or client-side code.

## 4. Create the Admin User

1. In Supabase, open Authentication > Users and create an account with the email
   بريدك الإداري الذي اخترته.
2. Set a private password and complete email verification if enabled.
3. In SQL Editor, run this query:

```sql
UPDATE public.users
SET role = 'ADMIN', banned = FALSE
WHERE email = 'YOUR-ADMIN-EMAIL';
```

The second migration creates the matching `public.users` row automatically when a
new Auth user registers.

## 5. Verify Setup

1. Go to Supabase Dashboard > Authentication > Users
2. Verify the superadmin user exists
3. Go to Table Editor > users table
4. Verify the user record exists with `role = 'ADMIN'`.

## 6. Configure Supabase Auth Settings

In Supabase Dashboard > Authentication > Settings:

### Site URL
Set to your Vercel deployment URL (e.g., `https://your-app.vercel.app`)

### Redirect URLs
Add:
- `https://your-app.vercel.app/**`
- `http://localhost:5173/**` (for local development)

### Email Templates (Optional)
Customize email templates for:
- Confirm signup
- Reset password
- Magic link

## 7. Enable Realtime (Optional)

For real-time features (match chat, live updates):
1. Go to Database > Replication
2. Enable replication for tables: `matches`, `match_messages`, `tournaments`, `recharges`

## 8. Test the Application

```bash
# Install all dependencies
pnpm install

# Run development server
pnpm run dev
```

Visit `http://localhost:5173` and login with superadmin credentials.

## Database Schema Overview

The migrations create:

| Table | Purpose |
|-------|---------|
| `users` | Player/admin accounts, balances, stats |
| `matches` | 1v1 challenges with stakes |
| `match_messages` | Chat messages for matches |
| `tournaments` | Tournament definitions |
| `tournament_participants` | User-tournament relationships |
| `transactions` | Wallet transaction history |
| `recharges` | Recharge requests |
| `withdrawals` | Withdrawal requests |
| `disputes` | Match disputes |
| `dispute_evidence` | Uploaded dispute evidence metadata |
| `activity_logs` | Admin and user activity history |
| `settings` | Platform configuration |

## Row Level Security (RLS)

All tables have RLS enabled with policies:
- Users can only access their own data
- Match participants can access match data
- Admins have full access to everything

## Troubleshooting

### "Relation does not exist" errors
- Ensure migration ran successfully
- Check Table Editor in Supabase Dashboard

### Auth errors
- Verify `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` are correct
- Check Site URL and Redirect URLs in Auth settings

### RLS policy errors
- Verify user is authenticated
- Check policies in Authentication > Policies

### Admin login not working
- Verify the Auth user exists.
- Verify the matching `public.users` row exists with `role = 'ADMIN'`.
- Confirm the Vercel environment variables are set and redeploy after changing them.
