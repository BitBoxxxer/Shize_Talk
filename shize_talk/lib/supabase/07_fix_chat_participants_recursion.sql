-- ============================================================================
-- Shize Talk — исправление "infinite recursion detected in policy for
-- relation chat_participants".
--
-- Причина: политика chat_participants_select проверяла участие в чате,
-- обращаясь к той же таблице chat_participants (self-join через cp2) —
-- Postgres при чтении любой строки снова применяет ту же политику,
-- и так до бесконечности.
--
-- Решение: вынести проверку в отдельную SECURITY DEFINER функцию.
-- Внутри такой функции запрос выполняется от имени владельца функции
-- (обычно роль postgres с BYPASSRLS), поэтому RLS-политика на
-- chat_participants там не перепроверяется и рекурсии не возникает.
--
-- Выполнить один раз в Supabase → SQL Editor, после 05 и 06 миграций.
-- ============================================================================

create or replace function public.is_chat_participant(p_chat_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.chat_participants
    where chat_id = p_chat_id and user_id = p_user_id
  );
$$;

-- Пересоздаём политику на chat_participants через функцию — без self-join
drop policy if exists chat_participants_select on public.chat_participants;
create policy chat_participants_select on public.chat_participants
  for select using (
    public.is_chat_participant(chat_participants.chat_id, auth.uid())
  );

-- Заодно переводим на ту же функцию политики chats и messages —
-- не обязательно для исправления рекурсии (там не self-join), но так
-- всё завязано на единую, проверенную логику проверки участия.
drop policy if exists chats_select on public.chats;
create policy chats_select on public.chats
  for select using (
    public.is_chat_participant(chats.id, auth.uid())
  );

drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages
  for select using (
    chat_id is null
    or public.is_chat_participant(messages.chat_id, auth.uid())
  );

drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages
  for insert with check (
    sender_id = auth.uid()
    and public.is_chat_participant(messages.chat_id, auth.uid())
  );
