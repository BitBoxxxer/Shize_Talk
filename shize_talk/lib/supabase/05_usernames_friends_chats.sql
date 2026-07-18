-- ============================================================================
-- Shize Talk — юзернеймы, друзья и отдельные чаты (вместо одного общего)
-- Выполнить один раз в Supabase → SQL Editor.
-- Предполагается, что уже существуют: profiles(id, display_name, role, ...),
-- check_invite_token / redeem_invite / create_invite / list_invites / revoke_invite.
-- ============================================================================

-- 1. Юзернейм в profiles -----------------------------------------------------
alter table public.profiles
  add column if not exists username text;

-- Юзернейм уникален без учёта регистра, 3-20 символов: латиница/цифры/подчёркивание
create unique index if not exists profiles_username_lower_idx
  on public.profiles (lower(username));

alter table public.profiles
  add constraint profiles_username_format
  check (username is null or username ~ '^[a-zA-Z0-9_]{3,20}$');

-- 2. Друзья -------------------------------------------------------------------
create table if not exists public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id) on delete cascade,
  addressee_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'blocked')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  constraint friendships_no_self check (requester_id <> addressee_id),
  constraint friendships_unique_pair unique (requester_id, addressee_id)
);

alter table public.friendships enable row level security;

create policy friendships_select on public.friendships
  for select using (auth.uid() = requester_id or auth.uid() = addressee_id);

-- inserts/updates происходят только через SECURITY DEFINER RPC ниже,
-- поэтому прямых insert/update policy для обычных пользователей не даём.

-- 3. Чаты ----------------------------------------------------------------------
create table if not exists public.chats (
  id uuid primary key default gen_random_uuid(),
  type text not null default 'direct' check (type in ('direct', 'group')),
  title text,
  created_at timestamptz not null default now()
);

create table if not exists public.chat_participants (
  chat_id uuid not null references public.chats(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (chat_id, user_id)
);

alter table public.chats enable row level security;
alter table public.chat_participants enable row level security;

create policy chats_select on public.chats
  for select using (
    exists (
      select 1 from public.chat_participants cp
      where cp.chat_id = chats.id and cp.user_id = auth.uid()
    )
  );

create policy chat_participants_select on public.chat_participants
  for select using (
    exists (
      select 1 from public.chat_participants cp2
      where cp2.chat_id = chat_participants.chat_id and cp2.user_id = auth.uid()
    )
  );

-- 4. Сообщения — переносим на chat_id ------------------------------------------
alter table public.messages
  add column if not exists chat_id uuid references public.chats(id) on delete cascade;

-- RLS: видеть/писать сообщения можно только в чатах, где ты участник
alter table public.messages enable row level security;

drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages
  for select using (
    chat_id is null -- совместимость со старыми сообщениями общего чата, если были
    or exists (
      select 1 from public.chat_participants cp
      where cp.chat_id = messages.chat_id and cp.user_id = auth.uid()
    )
  );

drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages
  for insert with check (
    sender_id = auth.uid()
    and exists (
      select 1 from public.chat_participants cp
      where cp.chat_id = messages.chat_id and cp.user_id = auth.uid()
    )
  );

create index if not exists messages_chat_id_created_at_idx
  on public.messages (chat_id, created_at);

-- Включаем Realtime-рассылку для таблицы messages (без этого шага
-- postgres_changes подписка в приложении не будет получать новые сообщения).
-- Если таблица уже была добавлена ранее — команда вернёт безобидную ошибку
-- "relation is already member of publication", это можно игнорировать.
alter publication supabase_realtime add table public.messages;

-- 5. RPC: установить свой юйзернейм --------------------------------------------
create or replace function public.set_username(p_username text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_username !~ '^[a-zA-Z0-9_]{3,20}$' then
    raise exception 'Юзернейм должен быть 3-20 символов: латиница, цифры, подчёркивание';
  end if;

  if exists (
    select 1 from public.profiles
    where lower(username) = lower(p_username) and id <> auth.uid()
  ) then
    raise exception 'Этот юзернейм уже занят';
  end if;

  update public.profiles set username = p_username where id = auth.uid();
end;
$$;

-- 6. RPC: поиск пользователей по юзернейму (для добавления в друзья) ----------
create or replace function public.search_users(p_query text)
returns table (id uuid, username text, display_name text)
language sql
security definer
set search_path = public
as $$
  select p.id, p.username, p.display_name
  from public.profiles p
  where p.id <> auth.uid()
    and p.username is not null
    and p.username ilike p_query || '%'
  order by p.username
  limit 20;
$$;

-- 7. RPC: отправить заявку в друзья по юзернейму -------------------------------
create or replace function public.send_friend_request(p_username text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target uuid;
  v_existing record;
begin
  select id into v_target from public.profiles where lower(username) = lower(p_username);

  if v_target is null then
    raise exception 'Пользователь с таким юзернеймом не найден';
  end if;

  if v_target = auth.uid() then
    raise exception 'Нельзя добавить самого себя';
  end if;

  select * into v_existing from public.friendships
  where (requester_id = auth.uid() and addressee_id = v_target)
     or (requester_id = v_target and addressee_id = auth.uid());

  if v_existing.id is not null then
    if v_existing.status = 'accepted' then
      raise exception 'Уже в друзьях';
    elsif v_existing.status = 'pending' then
      raise exception 'Заявка уже отправлена и ожидает ответа';
    end if;
  end if;

  insert into public.friendships (requester_id, addressee_id, status)
  values (auth.uid(), v_target, 'pending')
  on conflict (requester_id, addressee_id)
  do update set status = 'pending', responded_at = null, created_at = now();
end;
$$;

-- 8. RPC: ответить на заявку в друзья -------------------------------------------
create or replace function public.respond_friend_request(p_request_id uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.friendships
  set status = case when p_accept then 'accepted' else 'declined' end,
      responded_at = now()
  where id = p_request_id and addressee_id = auth.uid() and status = 'pending';

  if not found then
    raise exception 'Заявка не найдена или уже обработана';
  end if;
end;
$$;

-- 9. RPC: список входящих заявок ------------------------------------------------
create or replace function public.list_friend_requests()
returns table (
  request_id uuid,
  requester_id uuid,
  requester_username text,
  requester_display_name text,
  created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select f.id, p.id, p.username, p.display_name, f.created_at
  from public.friendships f
  join public.profiles p on p.id = f.requester_id
  where f.addressee_id = auth.uid() and f.status = 'pending'
  order by f.created_at desc;
$$;

-- 10. RPC: список друзей ---------------------------------------------------------
create or replace function public.list_friends()
returns table (
  friend_id uuid,
  username text,
  display_name text
)
language sql
security definer
set search_path = public
as $$
  select p.id, p.username, p.display_name
  from public.friendships f
  join public.profiles p on p.id = (
    case when f.requester_id = auth.uid() then f.addressee_id else f.requester_id end
  )
  where (f.requester_id = auth.uid() or f.addressee_id = auth.uid())
    and f.status = 'accepted'
  order by p.username;
$$;

-- 11. RPC: получить (или создать) личный чат с другим пользователем -------------
create or replace function public.get_or_create_direct_chat(p_other_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_chat_id uuid;
begin
  if p_other_user_id = auth.uid() then
    raise exception 'Нельзя создать чат с самим собой';
  end if;

  -- друзья ли вообще — чат разрешаем только между друзьями
  if not exists (
    select 1 from public.friendships
    where status = 'accepted'
      and ((requester_id = auth.uid() and addressee_id = p_other_user_id)
        or (requester_id = p_other_user_id and addressee_id = auth.uid()))
  ) then
    raise exception 'Чат можно начать только с другом';
  end if;

  select cp1.chat_id into v_chat_id
  from public.chat_participants cp1
  join public.chat_participants cp2 on cp1.chat_id = cp2.chat_id
  join public.chats c on c.id = cp1.chat_id
  where c.type = 'direct'
    and cp1.user_id = auth.uid()
    and cp2.user_id = p_other_user_id
  limit 1;

  if v_chat_id is not null then
    return v_chat_id;
  end if;

  insert into public.chats (type) values ('direct') returning id into v_chat_id;
  insert into public.chat_participants (chat_id, user_id) values (v_chat_id, auth.uid());
  insert into public.chat_participants (chat_id, user_id) values (v_chat_id, p_other_user_id);

  return v_chat_id;
end;
$$;

-- 12. RPC: список чатов текущего пользователя с превью последнего сообщения ------
create or replace function public.list_chats()
returns table (
  chat_id uuid,
  chat_type text,
  chat_title text,
  other_user_id uuid,
  other_username text,
  other_display_name text,
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
