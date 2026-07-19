-- ============================================================================
-- Shize Talk — выход из группы, ответы на сообщения, закреплённые сообщения,
-- удаление сообщений.
-- Выполнить один раз в Supabase → SQL Editor, после 05..13.
-- ============================================================================

-- 1. Колонки на messages: ответ и закрепление -----------------------------------
alter table public.messages
  add column if not exists reply_to_id uuid references public.messages(id) on delete set null,
  add column if not exists is_pinned boolean not null default false,
  add column if not exists pinned_at timestamptz,
  add column if not exists pinned_by uuid references public.profiles(id);

create index if not exists messages_reply_to_id_idx on public.messages (reply_to_id);
create index if not exists messages_chat_pinned_idx on public.messages (chat_id, is_pinned);

-- 2. RPC: удалить сообщение — только автор ---------------------------------------
-- ВАЖНО: если у сообщения есть вложение, файл в Storage эта функция не трогает —
-- клиент должен сам вызвать storage.remove() ДО этого RPC (по аналогии с уже
-- существующей _tryDeleteOrphanedAttachment в chat_screen.dart), иначе после
-- удаления строки сообщения ссылка на путь потеряется и файл-сирота останется
-- в бакете навсегда.
create or replace function public.delete_message(p_message_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.messages
  where id = p_message_id and sender_id = auth.uid();

  if not found then
    raise exception 'Сообщение не найдено или вы не его автор';
  end if;
end;
$$;

-- 3. RPC: закрепить/открепить сообщение — доступно любому участнику чата --------
create or replace function public.pin_message(p_message_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_chat_id uuid;
begin
  select chat_id into v_chat_id from public.messages where id = p_message_id;
  if v_chat_id is null or not public.is_chat_participant(v_chat_id, auth.uid()) then
    raise exception 'Сообщение не найдено';
  end if;

  update public.messages
  set is_pinned = true, pinned_at = now(), pinned_by = auth.uid()
  where id = p_message_id;
end;
$$;

create or replace function public.unpin_message(p_message_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_chat_id uuid;
begin
  select chat_id into v_chat_id from public.messages where id = p_message_id;
  if v_chat_id is null or not public.is_chat_participant(v_chat_id, auth.uid()) then
    raise exception 'Сообщение не найдено';
  end if;

  update public.messages
  set is_pinned = false, pinned_at = null, pinned_by = null
  where id = p_message_id;
end;
$$;

-- 4. RPC: список закреплённых сообщений чата -------------------------------------
create or replace function public.list_pinned_messages(p_chat_id uuid)
returns table (
  id uuid,
  sender_id uuid,
  sender_name text,
  content text,
  attachment_type text,
  attachment_name text,
  created_at timestamptz,
  pinned_at timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select m.id, m.sender_id, m.sender_name, m.content, m.attachment_type, m.attachment_name,
         m.created_at, m.pinned_at
  from public.messages m
  where m.chat_id = p_chat_id
    and m.is_pinned
    and public.is_chat_participant(p_chat_id, auth.uid())
  order by m.pinned_at desc;
$$;

-- 5. RPC: выйти из группового чата ------------------------------------------------
create or replace function public.leave_group(p_chat_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.chats where id = p_chat_id and type = 'group') then
    raise exception 'Это не групповой чат';
  end if;

  delete from public.chat_participants
  where chat_id = p_chat_id and user_id = auth.uid();

  if not found then
    raise exception 'Вы не участник этого чата';
  end if;
end;
$$;
