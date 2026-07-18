-- ============================================================================
-- Shize Talk — присутствие (в сети / был в сети), галочки "прочитано",
-- расширенный профиль (био, дата рождения).
-- Выполнить один раз в Supabase → SQL Editor, после 05, 06, 07.
-- ============================================================================

-- 1. Присутствие пользователя -------------------------------------------------
alter table public.profiles
  add column if not exists last_seen_at timestamptz;

alter table public.profiles
  add column if not exists bio text;

alter table public.profiles
  add column if not exists birth_date date;

-- Обновить "последний раз был в сети" — вызывается клиентом периодически,
-- пока приложение открыто.
create or replace function public.touch_presence()
returns void
language sql
security definer
set search_path = public
as $$
  update public.profiles set last_seen_at = now() where id = auth.uid();
$$;

-- Присутствие конкретного пользователя (для шапки чата "в сети"/"был(а) в сети")
create or replace function public.get_user_presence(p_user_id uuid)
returns timestamptz
language sql
security definer
set search_path = public
stable
as $$
  select last_seen_at from public.profiles where id = p_user_id;
$$;

-- 2. Прочитано ------------------------------------------------------------------
alter table public.chat_participants
  add column if not exists last_read_at timestamptz;

-- Отметить чат прочитанным (моя сторона) — вызывается при открытии чата
-- и при получении новых сообщений, пока чат открыт.
create or replace function public.mark_chat_read(p_chat_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.chat_participants
  set last_read_at = now()
  where chat_id = p_chat_id and user_id = auth.uid();
end;
$$;

-- Момент последнего прочтения каждым участником чата — чтобы понять,
-- прочитал ли собеседник мои сообщения.
create or replace function public.get_chat_participants_read(p_chat_id uuid)
returns table (user_id uuid, last_read_at timestamptz)
language sql
security definer
set search_path = public
stable
as $$
  select cp.user_id, cp.last_read_at
  from public.chat_participants cp
  where cp.chat_id = p_chat_id
    and public.is_chat_participant(p_chat_id, auth.uid());
$$;

-- 3. Расширенное редактирование профиля -----------------------------------------
create or replace function public.update_profile_details(
  p_display_name text,
  p_bio text,
  p_birth_date date
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if length(trim(p_display_name)) = 0 then
    raise exception 'Имя не может быть пустым';
  end if;
  if length(p_display_name) > 40 then
    raise exception 'Имя слишком длинное (максимум 40 символов)';
  end if;
  if p_bio is not null and length(p_bio) > 200 then
    raise exception 'Описание профиля слишком длинное (максимум 200 символов)';
  end if;
  if p_birth_date is not null and p_birth_date > current_date then
    raise exception 'Дата рождения не может быть в будущем';
  end if;

  update public.profiles
  set display_name = trim(p_display_name),
      bio = nullif(trim(coalesce(p_bio, '')), ''),
      birth_date = p_birth_date
  where id = auth.uid();
end;
$$;

-- get_my_profile теперь возвращает и новые поля — старую версию (с другим
-- набором колонок) нужно сначала удалить, Postgres не даёт молча поменять
-- форму OUT-параметров через CREATE OR REPLACE.
drop function if exists public.get_my_profile();

create or replace function public.get_my_profile()
returns table (
  id uuid,
  username text,
  display_name text,
  bio text,
  birth_date date
)
language sql
security definer
set search_path = public
as $$
  select p.id, p.username, p.display_name, p.bio, p.birth_date
  from public.profiles p
  where p.id = auth.uid();
$$;

-- 4. list_chats дополнен присутствием собеседника --------------------------------
-- Тоже меняем набор колонок — сначала удаляем старую версию.
drop function if exists public.list_chats();

create or replace function public.list_chats()
returns table (
  chat_id uuid,
  chat_type text,
  chat_title text,
  other_user_id uuid,
  other_username text,
  other_display_name text,
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
    other_p.last_seen_at,
    lm.content,
    lm.created_at
  from public.chats c
  join public.chat_participants my on my.chat_id = c.id and my.user_id = auth.uid()
  left join public.chat_participants other on other.chat_id = c.id and other.user_id <> auth.uid()
  left join public.profiles other_p on other_p.id = other.user_id
  left join lateral (
    select content, created_at
    from public.messages m
    where m.chat_id = c.id
    order by m.created_at desc
    limit 1
  ) lm on true
  order by coalesce(lm.created_at, c.created_at) desc;
$$;
