// Supabase Edge Function — send-notification
// Déploiement : supabase functions deploy send-notification
//
// Variables d'environnement requises (Dashboard > Settings > Edge Functions) :
//   RESEND_API_KEY    — clé API Resend (resend.com, gratuit jusqu'à 3000 mails/mois)
//   APP_FROM_EMAIL    — ex: "+1Life <noreply@tondomaine.fr>"
//   APP_URL           — ex: "https://deadbull.vercel.app"
//
// Pour les notifications "2h avant un event", ajouter dans Supabase SQL Editor :
//   SELECT cron.schedule(
//     'notify-upcoming',
//     '*/30 * * * *',
//     $$ SELECT net.http_post(
//       url := current_setting('app.supabase_url') || '/functions/v1/send-notification',
//       headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer ' || current_setting('app.service_role_key')),
//       body := '{"type":"upcoming"}'::jsonb
//     ) $$
//   );
//
// SQL nécessaire (à exécuter dans Supabase Dashboard > SQL Editor) :
//   CREATE EXTENSION IF NOT EXISTS pg_net;
//   CREATE TABLE IF NOT EXISTS notification_log (
//     id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
//     event_id UUID, type TEXT, sent_at TIMESTAMPTZ DEFAULT NOW()
//   );

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  const supabaseAdmin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )
  const resendKey = Deno.env.get('RESEND_API_KEY')
  const fromEmail = Deno.env.get('APP_FROM_EMAIL') || '+1Life <noreply@plusonelife.fr>'
  const appUrl = Deno.env.get('APP_URL') || 'https://plusonelife.vercel.app'

  const body = await req.json().catch(() => ({}))
  const { type, event_id, titre, date_heure } = body

  // ── Cas 1 : event supprimé ─────────────────────────────────────────────
  if (type === 'event_deleted' && event_id) {
    // Récupérer les participants
    const { data: parts } = await supabaseAdmin
      .from('event_participants')
      .select('user_id')
      .eq('event_id', event_id)

    if (!parts?.length) return new Response(JSON.stringify({ ok: true, sent: 0 }), { headers: corsHeaders })

    const userIds = parts.map((p: any) => p.user_id)
    const { data: users } = await supabaseAdmin.auth.admin.listUsers()
    const emails = users?.users
      .filter((u: any) => userIds.includes(u.id) && u.email)
      .map((u: any) => u.email) || []

    const dateStr = date_heure
      ? new Date(date_heure).toLocaleDateString('fr-FR', { weekday: 'long', day: 'numeric', month: 'long', hour: '2-digit', minute: '2-digit' })
      : 'date non précisée'

    let sent = 0
    for (const email of emails) {
      await sendEmail(resendKey, fromEmail, email, `[+1Life] Événement annulé : ${titre}`, `
        <p>Bonjour,</p>
        <p>L'événement <strong>${titre}</strong> prévu le <strong>${dateStr}</strong> a été annulé par son organisateur.</p>
        <p>Retrouve d'autres événements sur <a href="${appUrl}">${appUrl}</a></p>
        <p>— L'équipe +1Life</p>
      `)
      sent++
    }
    return new Response(JSON.stringify({ ok: true, sent }), { headers: corsHeaders })
  }

  // ── Cas 2 : rappel 2h avant (appelé par pg_cron) ──────────────────────
  if (type === 'upcoming') {
    const in2h = new Date(Date.now() + 2 * 60 * 60 * 1000)
    const in2h30 = new Date(Date.now() + 2.5 * 60 * 60 * 1000)

    const { data: events } = await supabaseAdmin
      .from('events')
      .select('id, titre, date_heure, lieu, ville')
      .gte('date_heure', in2h.toISOString())
      .lte('date_heure', in2h30.toISOString())

    let sent = 0
    for (const ev of (events || [])) {
      // Vérifier si on a déjà envoyé ce rappel
      const { data: already } = await supabaseAdmin
        .from('notification_log')
        .select('id')
        .eq('event_id', ev.id)
        .eq('type', 'upcoming')
        .single()
      if (already) continue

      const { data: parts } = await supabaseAdmin
        .from('event_participants')
        .select('user_id')
        .eq('event_id', ev.id)

      if (!parts?.length) continue

      const userIds = parts.map((p: any) => p.user_id)
      const { data: users } = await supabaseAdmin.auth.admin.listUsers()
      const emails = users?.users
        .filter((u: any) => userIds.includes(u.id) && u.email)
        .map((u: any) => u.email) || []

      const dateStr = new Date(ev.date_heure).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })
      const lieu = ev.ville || ev.lieu || ''

      for (const email of emails) {
        await sendEmail(resendKey, fromEmail, email, `[+1Life] Rappel — ${ev.titre} dans 2h !`, `
          <p>Bonjour,</p>
          <p>Ton événement <strong>${ev.titre}</strong> commence à <strong>${dateStr}</strong>${lieu ? ` à ${lieu}` : ''}.</p>
          <p>N'oublie pas d'y aller ! 💪</p>
          <p><a href="${appUrl}">${appUrl}</a></p>
          <p>— L'équipe +1Life</p>
        `)
        sent++
      }

      // Log pour éviter les doublons
      await supabaseAdmin.from('notification_log').insert({ event_id: ev.id, type: 'upcoming' })
    }

    return new Response(JSON.stringify({ ok: true, sent }), { headers: corsHeaders })
  }

  return new Response(JSON.stringify({ error: 'Unknown type' }), { status: 400, headers: corsHeaders })
})

async function sendEmail(apiKey: string | undefined, from: string, to: string, subject: string, html: string) {
  if (!apiKey) { console.warn('No RESEND_API_KEY'); return }
  await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${apiKey}` },
    body: JSON.stringify({ from, to, subject, html }),
  })
}
