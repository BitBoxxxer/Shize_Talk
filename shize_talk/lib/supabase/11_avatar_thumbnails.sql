-- ============================================================================
-- Shize Talk — компактные превью аватарок (thumb_url) для списков (чаты,
-- друзья, поиск) вместо полноразмерной картинки/гифки. Полный avatar_url
-- остаётся только там, где реально нужен крупный вид (экран профиля).
-- Выполнить один раз в Supabase → SQL Editor, после 10.
-- ============================================================================

-- 1. Колонки ------------------------------------------------------------------
alter table public.profiles
  add column if not exists thumb_url text;

alter table public.profile_avatars
  add column if not exists thumb_url text;

-- 2. add_profile_avatar — теперь принимает и превью ---------------------------
drop function if exists public.add_profile_avatar(text, text, text);

create or replace function public.add_profile_avatar(
  p_storage_path text,
  p_public_url text,
  p_media_type text,
  p_thumb_url text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_count int;
begin
  if p_media_type not in ('image', 'gif') then
    raise exception 'Неподдерживаемый тип аватарки';
  end if;

  select count(*) into v_count from public.profile_avatars where user_id = auth.uid();
  if v_count >= 10 then
    raise exception 'Можно хранить не более 10 аватарок — удалите старые, прежде чем добавлять новую';
  end if;

  insert into public.profile_avatars (user_id, storage_path, public_url, media_type, thumb_url)
  values (auth.uid(), p_storage_path, p_public_url, p_media_type, p_thumb_url)
  returning id into v_id;

  return v_id;
end;
$$;

-- 3. set_active_avatar — вместе с полным URL переключаем и превью -------------
create or replace function public.set_active_avatar(p_avatar_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_thumb text;
begin
  select public_url, thumb_url into v_url, v_thumb
  from public.profile_avatars
  where id = p_avatar_id and user_id = auth.uid();

  if v_url is null then
    raise exception 'Аватарка не найдена';
  end if;

  update public.profiles set avatar_url = v_url, thumb_url = v_thumb where id = auth.uid();
end;
$$;

-- 4. delete_profile_avatar — чистим и превью, если удаляем активную -----------
create or replace function public.delete_profile_avatar(p_avatar_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
begin
  select public_url into v_url
  from public.profile_avatars
  where id = p_avatar_id and user_id = auth.uid();

  if v_url is null then
    raise exception 'Аватарка не найдена';
  end if;

  delete from public.profile_avatars where id = p_avatar_id and user_id = auth.uid();

  update public.profiles
  set avatar_url = null, thumb_url = null
  where id = auth.uid() and avatar_url = v_url;
end;
$$;

-- 5. list_my_avatars — тоже отдаёт превью (экран "Аватарки" может показывать
-- сетку компактно, это тоже список, не крупный просмотр) ----------------------
drop function if exists public.list_my_avatars();

create or replace function public.list_my_avatars()
returns table (
  id uuid,
  public_url text,
  thumb_url text,
  media_type text,
  is_active boolean,
  created_at timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select pa.id, pa.public_url, pa.thumb_url, pa.media_type,
         (p.avatar_url = pa.public_url) as is_active,
         pa.created_at
  from public.profile_avatars pa
  join public.profiles p on p.id = auth.uid()
  where pa.user_id = auth.uid()
  order by pa.created_at desc;
$$;

-- 6. Прокидываем thumb_url через все места, где раньше был только avatar_url --
drop function if exists public.get_my_profile();

create or replace function public.get_my_profile()
returns table (
  id uuid,
  username text,
  display_name text,
  bio text,
  birth_date date,
  avatar_url text,
  thumb_url text,
  avatar_visibility text,
  language text
)
language sql
security definer
set search_path = public
as $$
  select p.id, p.username, p.display_name, p.bio, p.birth_date,
         p.avatar_url, p.thumb_url, p.avatar_visibility, p.language
  from public.profiles p
  where p.id = auth.uid();
$$;

drop function if exists public.search_users(text);

create or replace function public.search_users(p_query text)
returns table (id uuid, username text, display_name text, avatar_url text, thumb_url text)
language sql
security definer
set search_path = public
stable
as $$
  select p.id, p.username, p.display_name,
         public.visible_avatar_url(p.id, p.avatar_url, p.avatar_visibility),
         public.visible_avatar_url(p.id, p.thumb_url, p.avatar_visibility)
  from public.profiles p
  where p.id <> auth.uid()
    and p.username is not null
    and p.username ilike p_query || '%'
  order by p.username
  limit 20;
$$;

drop function if exists public.list_friends();

create or replace function public.list_friends()
returns table (friend_id uuid, username text, display_name text, avatar_url text, thumb_url text)
language sql
security definer
set search_path = public
as $$
  select p.id, p.username, p.display_name, p.avatar_url, p.thumb_url
  from public.friendships f
  join public.profiles p on p.id = (
    case when f.requester_id = auth.uid() then f.addressee_id else f.requester_id end
  )
  where (f.requester_id = auth.uid() or f.addressee_id = auth.uid())
    and f.status = 'accepted'
  order by p.username;
$$;
-- (avatar_url/thumb_url друзей не режем приватностью — раз вы уже друзья,
-- видимость 'friends' и так открывает вам доступ; helper всё равно вернул
-- бы то же самое значение, здесь просто без лишнего вызова функции)

drop function if exists public.list_friend_requests();

create or replace function public.list_friend_requests()
returns table (
  request_id uuid,
  requester_id uuid,
  requester_username text,
  requester_display_name text,
  requester_avatar_url text,
  requester_thumb_url text,
  created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select f.id, p.id, p.username, p.display_name,
         public.visible_avatar_url(p.id, p.avatar_url, p.avatar_visibility),
         public.visible_avatar_url(p.id, p.thumb_url, p.avatar_visibility),
         f.created_at
  from public.friendships f
  join public.profiles p on p.id = f.requester_id
  where f.addressee_id = auth.uid() and f.status = 'pending'
  order by f.created_at desc;
$$;

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
    public.visible_avatar_url(other_p.id, other_p.avatar_url, other_p.avatar_visibility),
    public.visible_avatar_url(other_p.id, other_p.thumb_url, other_p.avatar_visibility),
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
