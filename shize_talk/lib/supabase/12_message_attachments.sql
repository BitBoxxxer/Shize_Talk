-- ============================================================================
-- Shize Talk — вложения в чате (фото и любые файлы).
-- Выполнить один раз в Supabase → SQL Editor, после 05, 06, 07 (нужна функция
-- is_chat_participant), остальные миграции (08-11) можно выполнить в любом
-- порядке относительно этой.
-- ============================================================================

-- 1. Storage bucket ---------------------------------------------------------------
-- НЕ публичный (в отличие от avatars) — вложения чата видны только
-- участникам конкретного чата, а не всему интернету по прямой ссылке.
insert into storage.buckets (id, name, public, file_size_limit)
values ('chat_attachments', 'chat_attachments', false, 20 * 1024 * 1024) -- 20 МБ
on conflict (id) do update set file_size_limit = 20 * 1024 * 1024;

-- Файлы лежат по пути chat_attachments/{chat_id}/{message_id}.{ext} —
-- проверка доступа идёт по chat_id (первая часть пути), не по user_id,
-- как в бакете avatars, потому что вложение должны видеть ОБА участника
-- чата, а не только тот, кто его загрузил.
drop policy if exists "chat_attachments_insert" on storage.objects;
create policy "chat_attachments_insert" on storage.objects
  for insert
  with check (
    bucket_id = 'chat_attachments'
    and public.is_chat_participant(
      ((storage.foldername(name))[1])::uuid,
      auth.uid()
    )
  );

drop policy if exists "chat_attachments_select" on storage.objects;
create policy "chat_attachments_select" on storage.objects
  for select
  using (
    bucket_id = 'chat_attachments'
    and public.is_chat_participant(
      ((storage.foldername(name))[1])::uuid,
      auth.uid()
    )
  );

-- Удалять вложение может только тот, кто его отправил — проверяем через
-- messages по attachment_path, а не просто "любой участник чата".
drop policy if exists "chat_attachments_delete" on storage.objects;
create policy "chat_attachments_delete" on storage.objects
  for delete
  using (
    bucket_id = 'chat_attachments'
    and exists (
      select 1 from public.messages m
      where m.attachment_path = storage.objects.name
        and m.sender_id = auth.uid()
    )
  );

-- 2. Колонки вложения на messages ---------------------------------------------
alter table public.messages
  add column if not exists attachment_path text,       -- путь в Storage (для RLS/подписанных ссылок/удаления)
  add column if not exists attachment_type text          -- 'image' | 'file'
    check (attachment_type is null or attachment_type in ('image', 'file')),
  add column if not exists attachment_name text,          -- исходное имя файла
  add column if not exists attachment_size_bytes bigint,
  add column if not exists attachment_width int,          -- для картинок — превью без мигания размера
  add column if not exists attachment_height int;

-- Сообщение либо с текстом, либо с вложением (или и то, и другое — подпись
-- к фото), но не полностью пустое.
alter table public.messages
  drop constraint if exists messages_content_or_attachment_check;
alter table public.messages
  add constraint messages_content_or_attachment_check
  check (
    (content is not null and length(trim(content)) > 0)
    or attachment_path is not null
  );

-- content раньше был обязательным (not null) — сообщения с одним вложением
-- без подписи должны разрешать пустую строку.
alter table public.messages alter column content drop not null;

-- 3. Подписанные ссылки на приватные вложения --------------------------------
-- ВАЖНО: storage.create_signed_url — это не SQL-функция, вызываемая из
-- PL/pgSQL (в отличие от storage.foldername, которая есть в БД) — создание
-- подписанных ссылок доступно только через клиентские SDK Supabase
-- (Storage API поверх HTTP). Поэтому здесь нет отдельного RPC — клиент
-- в chat_screen.dart вызывает
--   Supabase.instance.client.storage.from('chat_attachments')
--       .createSignedUrl(attachmentPath, 60 * 60 * 24)
-- напрямую. Это безопасно: Storage API сам проверяет RLS-политики выше
-- (chat_attachments_select) при выдаче подписанной ссылки — участник
-- чужого чата получит отказ на этом же шаге, а не просто "красивую", но
-- нерабочую ссылку.

-- 4. Превью последнего сообщения в списке чатов: показываем "📷 Фото" /
-- "📎 Файл" вместо пустой строки, если у последнего сообщения только
-- вложение без подписи. Пересоздаём list_chats с этой логикой.
drop function if exists public.list_chats();
create or replace function public.list_chats()
returns table (
  chat_id uuid,
  chat_type text,
  chat_title text,
  other_user_id uuid,
  other_username text,
  other_display_name text,
  other_avatar_url text,
  other_last_seen_at timestamptz,
  last_message text,
  last_message_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    c.id,
    c.type,
    c.title,
    other_p.id,
    other_p.username,
    other_p.display_name,
    other_p.avatar_url,
    other_p.last_seen_at,
    case
      when lm.content is not null and length(trim(lm.content)) > 0 then lm.content
      when lm.attachment_type = 'image' then '📷 Фото'
      when lm.attachment_type = 'file' then '📎 ' || coalesce(lm.attachment_name, 'Файл')
      else lm.content
    end as last_message,
    lm.created_at
  from public.chats c
  join public.chat_participants my on my.chat_id = c.id and my.user_id = auth.uid()
  left join public.chat_participants other on other.chat_id = c.id and other.user_id <> auth.uid()
  left join public.profiles other_p on other_p.id = other.user_id
  left join lateral (
    select content, created_at, attachment_type, attachment_name
    from public.messages m
    where m.chat_id = c.id
    order by m.created_at desc
    limit 1
  ) lm on true
  order by coalesce(lm.created_at, c.created_at) desc;
$$;
