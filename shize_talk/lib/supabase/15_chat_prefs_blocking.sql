-- ============================================================================
-- Shize Talk — «дискордовские» действия над чатом (закрепить/заглушить/
-- игнорировать), блокировка пользователей, даты "друзья с..." и "в группе с...".
-- Выполнить один раз в Supabase → SQL Editor, после 05..14.
-- ============================================================================

-- 1. Настройки конкретного участника в конкретном чате -------------------------
-- Это per-user настройки (у каждого своя копия: если я закрепил чат у себя,
-- у собеседника он не закрепляется) — поэтому колонки на chat_participants,
-- а не на chats.
alter table public.chat_participants
  add column if not exists pinned_at timestamptz,
  add column if not exists muted_until timestamptz,
  add column if not exists is_ignored boolean not null default false;

create or replace function public.set_chat_pinned(p_chat_id uuid, p_pinned boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.chat_participants
  set pinned_at = case when p_pinned then now() else null end
  where chat_id = p_chat_id and user_id = auth.uid();

  if not found then
    raise exception 'Вы не участник этого чата';
  end if;
end;
$$;

-- p_minutes: null — снять заглушение; -1 — заглушить "пока не включу заново";
-- любое положительное число — на столько минут (15/60/480/1440 и т.д. — сколько
-- вариантов сделать в интерфейсе, решает клиент).
create or replace function public.set_chat_muted(p_chat_id uuid, p_minutes int)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.chat_participants
  set muted_until = case
    when p_minutes is null then null
    when p_minutes < 0 then 'infinity'::timestamptz
    else now() + (p_minutes || ' minutes')::interval
  end
  where chat_id = p_chat_id and user_id = auth.uid();

  if not found then
    raise exception 'Вы не участник этого чата';
  end if;
end;
$$;

create or replace function public.set_chat_ignored(p_chat_id uuid, p_ignored boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.chat_participants
  set is_ignored = p_ignored
  where chat_id = p_chat_id and user_id = auth.uid();

  if not found then
    raise exception 'Вы не участник этого чата';
  end if;
end;
$$;

-- 2. Блокировка пользователей ---------------------------------------------------
create table if not exists public.blocked_users (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint blocked_users_no_self check (blocker_id <> blocked_id)
);

alter table public.blocked_users enable row level security;

create policy blocked_users_select on public.blocked_users
  for select using (auth.uid() = blocker_id);
-- inserts/updates/deletes — только через RPC ниже.

create or replace function public.is_blocked(p_a uuid, p_b uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.blocked_users
    where (blocker_id = p_a and blocked_id = p_b)
       or (blocker_id = p_b and blocked_id = p_a)
  );
$$;

create or replace function public.block_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user_id = auth.uid() then
    raise exception 'Нельзя заблокировать самого себя';
  end if;

  insert into public.blocked_users (blocker_id, blocked_id)
  values (auth.uid(), p_user_id)
  on conflict do nothing;
end;
$$;

create or replace function public.unblock_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.blocked_users where blocker_id = auth.uid() and blocked_id = p_user_id;
end;
$$;

create or replace function public.list_blocked_users()
returns table (user_id uuid, username text, display_name text, avatar_url text, thumb_url text, blocked_at timestamptz)
language sql
security definer
set search_path = public
stable
as $$
  select p.id, p.username, p.display_name, p.avatar_url, p.thumb_url, b.created_at
  from public.blocked_users b
  join public.profiles p on p.id = b.blocked_id
  where b.blocker_id = auth.uid()
  order by b.created_at desc;
$$;

-- Блокировка запрещает и заявки в друзья, и (ниже) сами сообщения.
create or replace function public.send_friend_request(p_username text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target uuid;
begin
  select id into v_target from public.profiles where lower(username) = lower(p_username);

  if v_target is null then
    raise exception 'Пользователь @% не найден', p_username;
  end if;
  if v_target = auth.uid() then
    raise exception 'Нельзя добавить самого себя';
  end if;
  if public.is_blocked(auth.uid(), v_target) then
    raise exception 'Невозможно отправить заявку этому пользователю';
  end if;

  insert into public.friendships (requester_id, addressee_id)
  values (auth.uid(), v_target)
  on conflict (requester_id, addressee_id) do update
  set status = 'pending', created_at = now(), responded_at = null
  where public.friendships.status = 'declined';
end;
$$;

-- Сообщения между заблокированными — запрет прямо на уровне таблицы, чтобы
-- не зависеть от того, через какой именно клиентский код идёт insert.
create or replace function public.check_not_blocked_before_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_other uuid;
begin
  select cp.user_id into v_other
  from public.chat_participants cp
  join public.chats c on c.id = cp.chat_id
  where cp.chat_id = new.chat_id and cp.user_id <> new.sender_id and c.type = 'direct'
  limit 1;

  if v_other is not null and public.is_blocked(new.sender_id, v_other) then
    raise exception 'Нельзя отправить сообщение — пользователь заблокирован';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_check_not_blocked on public.messages;
create trigger trg_check_not_blocked
  before insert on public.messages
  for each row execute function public.check_not_blocked_before_message();

-- 3. list_chats — плюс pinned/muted/ignored, закреплённые чаты первыми ----------
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
  other_thumb_url text,
  other_last_seen_at timestamptz,
  last_message text,
  last_message_at timestamptz,
  is_pinned boolean,
  muted_until timestamptz,
  is_ignored boolean
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
    public.visible_avatar_url(other_p.id, other_p.avatar_url, other_p.avatar_visibility),
    public.visible_avatar_url(other_p.id, other_p.thumb_url, other_p.avatar_visibility),
    other_p.last_seen_at,
    lm.content,
    lm.created_at,
    (my.pinned_at is not null),
    my.muted_until,
    my.is_ignored
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
  order by
    my.pinned_at desc nulls last,
    my.is_ignored asc,
    coalesce(lm.created_at, c.created_at) desc;
$$;

-- 4. list_friends / list_chat_participants — добавляем даты --------------------
drop function if exists public.list_friends();

create or replace function public.list_friends()
returns table (
  friend_id uuid,
  username text,
  display_name text,
  avatar_url text,
  thumb_url text,
  friends_since timestamptz
)
language sql
security definer
set search_path = public
as $$
  select p.id, p.username, p.display_name, p.avatar_url, p.thumb_url, f.responded_at
  from public.friendships f
  join public.profiles p on p.id = (
    case when f.requester_id = auth.uid() then f.addressee_id else f.requester_id end
  )
  where (f.requester_id = auth.uid() or f.addressee_id = auth.uid())
    and f.status = 'accepted'
  order by p.username;
$$;

drop function if exists public.list_chat_participants(uuid);

create or replace function public.list_chat_participants(p_chat_id uuid)
returns table (
  user_id uuid,
  username text,
  display_name text,
  avatar_url text,
  thumb_url text,
  joined_at timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select p.id, p.username, p.display_name,
         public.visible_avatar_url(p.id, p.avatar_url, p.avatar_visibility),
         public.visible_avatar_url(p.id, p.thumb_url, p.avatar_visibility),
         cp.joined_at
  from public.chat_participants cp
  join public.profiles p on p.id = cp.user_id
  where cp.chat_id = p_chat_id
    and public.is_chat_participant(p_chat_id, auth.uid())
  order by cp.joined_at;
$$;

-- 5. get_public_profile — плюс "друзья с", блок статус -------------------------
drop function if exists public.get_public_profile(uuid);

create or replace function public.get_public_profile(p_user_id uuid)
returns table (
  id uuid,
  username text,
  display_name text,
  bio text,
  avatar_url text,
  thumb_url text,
  is_friend boolean,
  has_pending_request boolean,
  is_me boolean,
  friends_since timestamptz,
  is_blocked_by_me boolean
)
language sql
security definer
set search_path = public
stable
as $$
  select
    p.id,
    p.username,
    p.display_name,
    p.bio,
    public.visible_avatar_url(p.id, p.avatar_url, p.avatar_visibility),
    public.visible_avatar_url(p.id, p.thumb_url, p.avatar_visibility),
    public.is_friend(p.id, auth.uid()),
    exists (
      select 1 from public.friendships f
      where f.status = 'pending'
        and ((f.requester_id = auth.uid() and f.addressee_id = p.id)
          or (f.requester_id = p.id and f.addressee_id = auth.uid()))
    ),
    p.id = auth.uid(),
    (
      select f.responded_at from public.friendships f
      where f.status = 'accepted'
        and ((f.requester_id = auth.uid() and f.addressee_id = p.id)
          or (f.requester_id = p.id and f.addressee_id = auth.uid()))
      limit 1
    ),
    exists (
      select 1 from public.blocked_users b
      where b.blocker_id = auth.uid() and b.blocked_id = p.id
    )
  from public.profiles p
  where p.id = p_user_id;
$$;
