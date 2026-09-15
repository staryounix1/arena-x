-- Efootball Arena Database Schema
-- Created for Supabase PostgreSQL

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Users table
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    username VARCHAR(100) UNIQUE NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(20) NOT NULL DEFAULT 'PLAYER' CHECK (role IN ('PLAYER', 'ADMIN')),
    balance DECIMAL(15,2) NOT NULL DEFAULT 0.00,
    efootball_id VARCHAR(50) NOT NULL DEFAULT 'EF-000000',
    whatsapp VARCHAR(50) NOT NULL DEFAULT '',
    wins INTEGER NOT NULL DEFAULT 0,
    losses INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Matches table
CREATE TABLE matches (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    title VARCHAR(255) NOT NULL,
    creator_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    creator_name VARCHAR(100) NOT NULL,
    creator_efootball_id VARCHAR(50) NOT NULL,
    opponent_id UUID REFERENCES users(id) ON DELETE SET NULL,
    opponent_name VARCHAR(100),
    opponent_efootball_id VARCHAR(50),
    platform VARCHAR(50) NOT NULL,
    stake DECIMAL(15,2) NOT NULL,
    prize DECIMAL(15,2) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'PLAYING', 'DISPUTE', 'COMPLETED', 'CANCELLED')),
    room_code VARCHAR(50),
    winner_id UUID REFERENCES users(id) ON DELETE SET NULL,
    winner_name VARCHAR(100),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Match messages table
CREATE TABLE match_messages (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    match_id UUID NOT NULL REFERENCES matches(id) ON DELETE CASCADE,
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    username VARCHAR(100) NOT NULL,
    message TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Tournaments table
CREATE TABLE tournaments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    title VARCHAR(255) NOT NULL,
    prize_pool DECIMAL(15,2) NOT NULL,
    entry_fee DECIMAL(15,2) NOT NULL,
    max_players INTEGER NOT NULL,
    participant_count INTEGER NOT NULL DEFAULT 0,
    start_date VARCHAR(100) NOT NULL,
    rules TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Tournament participants table
CREATE TABLE tournament_participants (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tournament_id UUID NOT NULL REFERENCES tournaments(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(tournament_id, user_id)
);

-- Transactions table
CREATE TABLE transactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type VARCHAR(50) NOT NULL,
    description TEXT NOT NULL,
    amount DECIMAL(15,2) NOT NULL,
    balance_after DECIMAL(15,2) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Recharges table
CREATE TABLE recharges (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    username VARCHAR(100) NOT NULL,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    amount DECIMAL(15,2) NOT NULL,
    payment_method VARCHAR(50) NOT NULL,
    whatsapp VARCHAR(50) NOT NULL,
    notes TEXT,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Settings table
CREATE TABLE settings (
    key VARCHAR(100) PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes for performance
CREATE INDEX idx_matches_status ON matches(status);
CREATE INDEX idx_matches_creator_id ON matches(creator_id);
CREATE INDEX idx_matches_opponent_id ON matches(opponent_id);
CREATE INDEX idx_match_messages_match_id ON match_messages(match_id);
CREATE INDEX idx_tournament_participants_tournament_id ON tournament_participants(tournament_id);
CREATE INDEX idx_tournament_participants_user_id ON tournament_participants(user_id);
CREATE INDEX idx_transactions_user_id ON transactions(user_id);
CREATE INDEX idx_recharges_user_id ON recharges(user_id);
CREATE INDEX idx_recharges_status ON recharges(status);

-- Row Level Security (RLS) Policies
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE matches ENABLE ROW LEVEL SECURITY;
ALTER TABLE match_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE tournaments ENABLE ROW LEVEL SECURITY;
ALTER TABLE tournament_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE recharges ENABLE ROW LEVEL SECURITY;
ALTER TABLE settings ENABLE ROW LEVEL SECURITY;

-- Users policies
CREATE POLICY "Users can view own profile" ON users
    FOR SELECT USING (auth.uid() = id);

CREATE POLICY "Users can update own profile" ON users
    FOR UPDATE USING (auth.uid() = id);

CREATE POLICY "Admins can view all users" ON users
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM users WHERE id = auth.uid() AND role = 'ADMIN'
        )
    );

CREATE POLICY "Admins can update all users" ON users
    FOR UPDATE USING (
        EXISTS (
            SELECT 1 FROM users WHERE id = auth.uid() AND role = 'ADMIN'
        )
    );

-- Matches policies
CREATE POLICY "Anyone can view open matches" ON matches
    FOR SELECT USING (status = 'OPEN' OR auth.uid() = creator_id OR auth.uid() = opponent_id);

CREATE POLICY "Authenticated users can create matches" ON matches
    FOR INSERT WITH CHECK (auth.uid() = creator_id);

CREATE POLICY "Match participants can update match" ON matches
    FOR UPDATE USING (auth.uid() = creator_id OR auth.uid() = opponent_id);

CREATE POLICY "Admins can view all matches" ON matches
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM users WHERE id = auth.uid() AND role = 'ADMIN'
        )
    );

-- Match messages policies
CREATE POLICY "Match participants can view messages" ON match_messages
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM matches 
            WHERE matches.id = match_messages.match_id 
            AND (matches.creator_id = auth.uid() OR matches.opponent_id = auth.uid())
        )
    );

CREATE POLICY "Match participants can send messages" ON match_messages
    FOR INSERT WITH CHECK (
        EXISTS (
            SELECT 1 FROM matches 
            WHERE matches.id = match_messages.match_id 
            AND (matches.creator_id = auth.uid() OR matches.opponent_id = auth.uid())
        )
    );

CREATE POLICY "Admins can view all messages" ON match_messages
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM users WHERE id = auth.uid() AND role = 'ADMIN'
        )
    );

-- Tournaments policies
CREATE POLICY "Anyone can view tournaments" ON tournaments
    FOR SELECT USING (true);

CREATE POLICY "Admins can manage tournaments" ON tournaments
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM users WHERE id = auth.uid() AND role = 'ADMIN'
        )
    );

-- Tournament participants policies
CREATE POLICY "Users can view own participations" ON tournament_participants
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can join tournaments" ON tournament_participants
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Admins can view all participations" ON tournament_participants
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM users WHERE id = auth.uid() AND role = 'ADMIN'
        )
    );

-- Transactions policies
CREATE POLICY "Users can view own transactions" ON transactions
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Admins can view all transactions" ON transactions
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM users WHERE id = auth.uid() AND role = 'ADMIN'
        )
    );

-- Recharges policies
CREATE POLICY "Users can view own recharges" ON recharges
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can create recharge requests" ON recharges
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Admins can view all recharges" ON recharges
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM users WHERE id = auth.uid() AND role = 'ADMIN'
        )
    );

CREATE POLICY "Admins can update recharges" ON recharges
    FOR UPDATE USING (
        EXISTS (
            SELECT 1 FROM users WHERE id = auth.uid() AND role = 'ADMIN'
        )
    );

-- Settings policies
CREATE POLICY "Admins can manage settings" ON settings
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM users WHERE id = auth.uid() AND role = 'ADMIN'
        )
    );

-- Function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Triggers for updated_at
CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_matches_updated_at BEFORE UPDATE ON matches
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_tournaments_updated_at BEFORE UPDATE ON tournaments
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_recharges_updated_at BEFORE UPDATE ON recharges
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_settings_updated_at BEFORE UPDATE ON settings
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Insert default settings
INSERT INTO settings (key, value) VALUES
    ('commission_rate', '0.10'),
    ('admin_whatsapp', '+212600000000'),
    ('cih_rib', 'YOUR-CIH-RIB'),
    ('cih_name', 'MOHAMMED ADMIN'),
    ('cashplus_name', 'MOHAMMED ADMIN'),
    ('cashplus_cin', 'YOUR-CASHPLUS-CIN')
ON CONFLICT (key) DO NOTHING;
