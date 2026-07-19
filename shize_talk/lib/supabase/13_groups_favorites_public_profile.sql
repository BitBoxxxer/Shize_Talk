-- ============================================================================
-- Shize Talk — групповые чаты (создание), "Избранное" (чат с самим собой),
-- удаление из друзей, просмотр чужого профиля.
-- Выполнить один раз в Supabase → SQL Editor, после 05..12.
-- ============================================================================

-- 0. На случай, если миграция 11 (thumb_url) применилась не полностью —
-- колонка нужна ниже в list_chat_participants / get_public_profile.
alter table public.profiles
  add column if not exists thumb_url text;

-- 1. Разрешаем тип чата 'favorites' -------------------------------------------
alter table public.chats drop constraint if exists chats_type_check;
alter table public.chats
  add constraint chats_type_check check (type in ('direct', 'group', 'favorites'));

-- 2. RPC: получить (или создать) свой чат "Избранное" --------------------------
-- Обычный чат, где единственный участник — сам пользователь. Сообщения в нём
-- шлются и читаются по тем же RLS-политикам (is_chat_participant), ничего
-- дополнительно менять не нужно.
create or replace function public.get_or_create_favorites_chat()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_chat_id uuid;
begin
  select c.id into v_chat_id
  from public.chats c
  join public.chat_participants cp on cp.chat_id = c.id
  where c.type = 'favorites' and cp.user_id = auth.uid()
  limit 1;

  if v_chat_id is not null then
    return v_chat_id;
  end if;

  insert into public.chats (type, title) values ('favorites', 'Избранное') returning id into v_chat_id;
  insert into public.chat_participants (chat_id, user_id) values (v_chat_id, auth.uid());

  return v_chat_id;
end;
$$;

-- 3. RPC: создать групповой чат -------------------------------------------------
-- Создатель добавляется автоматически. Остальные участники должны быть
-- друзьями создателя (та же логика доверия, что и у личных чатов).
create or replace function public.create_group_chat(p_title text, p_member_ids uuid[])
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_chat_id uuid;
  v_member uuid;
begin
  if p_title is null or length(trim(p_title)) = 0 then
    raise exception 'Укажите название группы';
  end if;

  if p_member_ids is null or array_length(p_member_ids, 1) is null or array_length(p_member_ids, 1) < 1 then
    raise exception 'Добавьте хотя бы одного участника';
  end if;

  foreach v_member in array p_member_ids loop
    if v_member <> auth.uid() and not exists (
      select 1 from public.friendships
      where status = 'accepted'
        and ((requester_id = auth.uid() and addressee_id = v_member)
          or (requester_id = v_member and addressee_id = auth.uid()))
    ) then
      raise exception 'В группу можно добавлять только друзей';
    end if;
  end loop;

  insert into public.chats (type, title) values ('group', trim(p_title)) returning id into v_chat_id;
  insert into public.chat_participants (chat_id, user_id) values (v_chat_id, auth.uid());

  foreach v_member in array p_member_ids loop
    if v_member <> auth.uid() then
      insert into public.chat_participants (chat_id, user_id)
      values (v_chat_id, v_member)
      on conflict do nothing;
    end if;
  end loop;

  return v_chat_id;
end;
$$;

-- 4. RPC: добавить участников в уже существующую группу -------------------------
create or replace function public.add_chat_participants(p_chat_id uuid, p_member_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member uuid;
begin
  if not exists (
    select 1 from public.chats c
    join public.chat_participants cp on cp.chat_id = c.id
    where c.id = p_chat_id and c.type = 'group' and cp.user_id = auth.uid()
  ) then
    raise exception 'Группа не найдена или вы не её участник';
  end if;

  foreach v_member in array p_member_ids loop
    if v_member <> auth.uid() and not exists (
      select 1 from public.friendships
      where status = 'accepted'
        and ((requester_id = auth.uid() and addressee_id = v_member)
          or (requester_id = v_member and addressee_id = auth.uid()))
    ) then
      raise exception 'В группу можно добавлять только друзей';
    end if;

    insert into public.chat_participants (chat_id, user_id)
    values (p_chat_id, v_member)
    on conflict do nothing;
  end loop;
end;
$$;

-- 5. RPC: список участников чата (для экрана группы) ---------------------------
create or replace function public.list_chat_participants(p_chat_id uuid)
returns table (
  user_id uuid,
  username text,
  display_name text,
  avatar_url text,
  thumb_url text
)
language sql
security definer
set search_path = public
stable
as $$
  select p.id, p.username, p.display_name,
         public.visible_avatar_url(p.id, p.avatar_url, p.avatar_visibility),
         public.visible_avatar_url(p.id, p.thumb_url, p.avatar_visibility)
  from public.chat_participants cp
  join public.profiles p on p.id = cp.user_id
  where cp.chat_id = p_chat_id
    and public.is_chat_participant(p_chat_id, auth.uid())
  order by p.username;
$$;

-- 6. RPC: удалить из друзей -----------------------------------------------------
create or replace function public.remove_friend(p_friend_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.friendships
  where status = 'accepted'
    and ((requester_id = auth.uid() and addressee_id = p_friend_id)
      or (requester_id = p_friend_id and addressee_id = auth.uid()));

  if not found then
    raise exception 'Вы не были в друзьях с этим пользователем';
  end if;
end;
$$;

-- 7. RPC: публичный профиль произвольного пользователя --------------------------
-- Доступно всем (нужно для экрана "Просмотр чужого профиля"), но аватар и
-- дата рождения подчиняются тем же правилам приватности, что и везде.
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
  is_me boolean
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
    p.id = auth.uid()
  from public.profiles p
  where p.id = p_user_id;
$$;
