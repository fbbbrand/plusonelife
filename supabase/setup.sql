-- ================================================================
-- +1Life — SQL à exécuter dans Supabase Dashboard > SQL Editor
-- ================================================================

-- 1. Ajouter le champ "ville" à la table events
ALTER TABLE events ADD COLUMN IF NOT EXISTS ville TEXT;

-- 2. Table reviews (avis sur les profils)
CREATE TABLE IF NOT EXISTS reviews (
  id           UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  reviewer_id  UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  reviewed_id  UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  rating       INTEGER NOT NULL CHECK (rating >= 1 AND rating <= 5),
  comment      TEXT,
  created_at   TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(reviewer_id, reviewed_id)  -- un seul avis par paire
);
ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;
DO $$ DECLARE r RECORD; BEGIN FOR r IN SELECT schemaname, tablename, policyname FROM pg_policies WHERE tablename IN ('reviews','banned_users') LOOP EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', r.policyname, r.schemaname, r.tablename); END LOOP; END $$;
CREATE POLICY "Reviews visible to all"           ON reviews FOR SELECT USING (true);
CREATE POLICY "Auth users can post reviews"      ON reviews FOR INSERT WITH CHECK (auth.uid() = reviewer_id AND auth.uid() != reviewed_id);
CREATE POLICY "Auth users can update own review" ON reviews FOR UPDATE USING (auth.uid() = reviewer_id);
CREATE POLICY "Auth users can delete own review" ON reviews FOR DELETE USING (auth.uid() = reviewer_id);

-- 3. Table banned_users (bannissements admin)
CREATE TABLE IF NOT EXISTS banned_users (
  user_id   UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  raison    TEXT,
  banned_at TIMESTAMPTZ DEFAULT NOW(),
  banned_by UUID REFERENCES auth.users(id)
);
ALTER TABLE banned_users ENABLE ROW LEVEL SECURITY;
-- Un utilisateur peut vérifier son propre statut de ban
CREATE POLICY "Users can check own ban" ON banned_users FOR SELECT USING (auth.uid() = user_id);
-- L'admin (app_metadata.role = 'admin') gère les bans
CREATE POLICY "Admin can view banned"   ON banned_users FOR SELECT USING ((auth.jwt()->'app_metadata'->>'role') = 'admin');
CREATE POLICY "Admin can ban users"     ON banned_users FOR INSERT WITH CHECK ((auth.jwt()->'app_metadata'->>'role') = 'admin');
CREATE POLICY "Admin can unban users"   ON banned_users FOR DELETE USING ((auth.jwt()->'app_metadata'->>'role') = 'admin');

-- 4. Table notification_log (éviter les doublons d'emails)
CREATE TABLE IF NOT EXISTS notification_log (
  id         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  event_id   UUID,
  type       TEXT,
  sent_at    TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE notification_log ENABLE ROW LEVEL SECURITY;
-- Seul le service role y accède (pas de policy publique nécessaire)

-- 4. Notifications "2h avant" via pg_cron (activer l'extension d'abord)
-- Dans Supabase Dashboard > Database > Extensions, activer "pg_cron" et "pg_net"
-- Puis exécuter :
-- SELECT cron.schedule(
--   'notify-upcoming-events',
--   '*/30 * * * *',
--   $$ SELECT net.http_post(
--     url := 'VOTRE_SUPABASE_URL/functions/v1/send-notification',
--     headers := '{"Content-Type":"application/json","Authorization":"Bearer VOTRE_SERVICE_ROLE_KEY"}'::jsonb,
--     body := '{"type":"upcoming"}'::jsonb
--   ) $$
-- );
