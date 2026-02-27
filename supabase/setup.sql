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
CREATE POLICY "Reviews visible to all"           ON reviews FOR SELECT USING (true);
CREATE POLICY "Auth users can post reviews"      ON reviews FOR INSERT WITH CHECK (auth.uid() = reviewer_id AND auth.uid() != reviewed_id);
CREATE POLICY "Auth users can update own review" ON reviews FOR UPDATE USING (auth.uid() = reviewer_id);
CREATE POLICY "Auth users can delete own review" ON reviews FOR DELETE USING (auth.uid() = reviewer_id);

-- 3. Table notification_log (éviter les doublons d'emails)
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
