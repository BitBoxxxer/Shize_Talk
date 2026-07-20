// supabase/functions/notify-new-message/index.ts
//
// Триггерится через Database Webhook (Supabase → Database → Webhooks) на
// INSERT в public.messages. Находит остальных участников чата (кроме
// отправителя), исключает тех, кто заглушил чат (muted_until) или у кого
// нет зарегистрированного push-токена, и шлёт push через FCM HTTP v1 API.
//
// НУЖНА РУЧНАЯ НАСТРОЙКА (без этого функция не заработает):
// 1. Создать проект в Firebase Console (console.firebase.google.com),
//    добавить туда Android-приложение с вашим applicationId
//    (смотрите android/app/build.gradle.kts → applicationId), скачать
//    google-services.json → положить в android/app/.
// 2. В Firebase Console → Project settings → Service accounts →
//    "Generate new private key" — скачается JSON с ключом сервисного аккаунта.
// 3. Supabase Dashboard → Edge Functions → Secrets, добавить:
//      FCM_PROJECT_ID       = ваш Firebase project id
//      FCM_SERVICE_ACCOUNT  = содержимое скачанного JSON целиком (в одну строку)
// 4. Задеплоить: supabase functions deploy notify-new-message
// 5. Supabase Dashboard → Database → Webhooks → Create a new hook:
//      Table: messages, Events: Insert, Type: HTTP Request,
//      URL: <ваш project ref>.supabase.co/functions/v1/notify-new-message
//      Headers: Authorization: Bearer <service_role key> (Settings → API)

import { createClient } from 'npm:@supabase/supabase-js@2';
import { GoogleAuth } from 'npm:google-auth-library@9';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const FCM_PROJECT_ID = Deno.env.get('FCM_PROJECT_ID')!;
const FCM_SERVICE_ACCOUNT = JSON.parse(Deno.env.get('FCM_SERVICE_ACCOUNT')!);

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

async function getAccessToken(): Promise<string> {
  const auth = new GoogleAuth({
    credentials: FCM_SERVICE_ACCOUNT,
    scopes: ['https://www.googleapis.com/auth/firebase.messaging'],
  });
  const client = await auth.getClient();
  const token = await client.getAccessToken();
  return token.token as string;
}

async function sendPush(token: string, title: string, body: string, chatId: string, accessToken: string) {
  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${FCM_PROJECT_ID}/messages:send`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        message: {
          token,
          notification: { title, body },
          data: { chat_id: chatId },
          android: { priority: 'high' },
        },
      }),
    },
  );

  if (!res.ok) {
    const text = await res.text();
    console.error('FCM send failed', res.status, text);
    // Токен мог протухнуть (пользователь удалил приложение и т.п.) —
    // 404/400 UNREGISTERED — чистим его, чтобы не пытаться снова каждый раз.
    if (res.status === 404 || text.includes('UNREGISTERED')) {
      await supabase.from('push_tokens').delete().eq('token', token);
    }
  }
}

Deno.serve(async (req) => {
  try {
    const payload = await req.json();
    const message = payload.record;
    if (!message) return new Response('no record', { status: 200 });

    const { data: chat } = await supabase
      .from('chats')
      .select('type, title')
      .eq('id', message.chat_id)
      .single();

    const { data: participants } = await supabase
      .from('chat_participants')
      .select('user_id, muted_until')
      .eq('chat_id', message.chat_id)
      .neq('user_id', message.sender_id);

    if (!participants || participants.length === 0) {
      return new Response('no recipients', { status: 200 });
    }

    const now = Date.now();
    const recipients = participants.filter((p) => {
      if (!p.muted_until) return true;
      return new Date(p.muted_until).getTime() < now;
    });
    if (recipients.length === 0) return new Response('all muted', { status: 200 });

    const { data: tokens } = await supabase
      .from('push_tokens')
      .select('token')
      .in('user_id', recipients.map((r) => r.user_id));

    if (!tokens || tokens.length === 0) return new Response('no tokens', { status: 200 });

    const title = chat?.type === 'group'
      ? `${message.sender_name} в «${chat.title}»`
      : message.sender_name ?? 'Новое сообщение';
    const body: string = message.content
      ?? (message.attachment_type ? '📎 Вложение' : 'Новое сообщение');

    const accessToken = await getAccessToken();
    await Promise.all(
      tokens.map((t) => sendPush(t.token, title, body, message.chat_id, accessToken)),
    );

    return new Response('ok', { status: 200 });
  } catch (e) {
    console.error(e);
    return new Response(String(e), { status: 500 });
  }
});
