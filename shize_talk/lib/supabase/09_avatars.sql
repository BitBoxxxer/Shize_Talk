-- ============================================================================
-- Shize Talk — аватарки (несколько штук на выбор, картинка или гиф).
-- Выполнить один раз в Supabase → SQL Editor, после 05, 06, 07, 08.
-- ============================================================================

-- 1. Storage bucket ---------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

drop policy if exists "avatar_upload_own_folder" on storage.objects;
create policy "avatar_upload_own_folder" on storage.objects
  for insert
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "avatar_update_own_folder" on storage.objects;
create policy "avatar_update_own_folder" on storage.objects
  for update
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "avatar_delete_own_folder" on storage.objects;
create policy "avatar_delete_own_folder" on storage.objects
  for delete
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- Бакет публичный: любой может ЧИТАТЬ файлы (нужно, чтобы друзья видели
-- аватарку в чате/списке друзей) — но писать/удалять может только владелец
-- папки avatars/{свой user_id}/...
drop policy if exists "avatar_public_read" on storage.objects;
create policy "avatar_public_read" on storage.objects
  for select
  using (bucket_id = 'avatars');

-- 2. Таблица-галерея аватарок пользователя -----------------------------------------
alter table public.profiles
  add column if not exists avatar_url text;

create table if not exists public.profile_avatars (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  storage_path text not null,
  public_url text not null,
  media_type text not null check (media_type in ('image', 'gif')),
  created_at timestamptz not null default now()
);

alter table public.profile_avatars enable row level security;

-- Список своих аватарок — приватный (управление). Активная аватарка при этом
-- видна всем через profiles.avatar_url (отдаётся через RPC ниже).
drop policy if exists profile_avatars_select_own on public.profile_avatars;
create policy profile_avatars_select_own on public.profile_avatars
  for select using (user_id = auth.uid());

-- 3. RPC: зарегистрировать загруженный файл как аватарку --------------------------
create or replace function public.add_profile_avatar(
  p_storage_path text,
  p_public_url text,
  p_media_type text
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

  insert into public.profile_avatars (user_id, storage_path, public_url, media_type)
  values (auth.uid(), p_storage_path, p_public_url, p_media_type)
  returning id into v_id;

  return v_id;
end;
$$;

-- 4. RPC: сделать аватарку активной ------------------------------------------------
create or replace function public.set_active_avatar(p_avatar_id uuid)
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

  update public.profiles set avatar_url = v_url where id = auth.uid();
end;
$$;

-- 5. RPC: удалить метаданные аватарки (сам файл в Storage удаляет клиент) --------
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
  set avatar_url = null
  where id = auth.uid() and avatar_url = v_url;
end;
$$;

-- 6. RPC: список своих аватарок ----------------------------------------------------
create or replace function public.list_my_avatars()
returns table (id uuid, public_url text, media_type text, is_active boolean, created_at timestamptz)
language sql
security definer
set search_path = public
stable
as $$
  select pa.id, pa.public_url, pa.media_type,
         (p.avatar_url = pa.public_url) as is_active,
         pa.created_at
  from public.profile_avatars pa
  join public.profiles p on p.id = auth.uid()
  where pa.user_id = auth.uid()
  order by pa.created_at desc;
$$;

-- 7. Прокидываем avatar_url в уже существующие RPC ---------------------------------
-- Меняется набор колонок — сначала удаляем старые версии.
drop function if exists public.get_my_profile();
create or replace function public.get_my_profile()
returns table (
  id uuid,
  username text,
  display_name text,
  bio text,
  birth_date date,
  avatar_url text
)
language sql
security definer
set search_path = public
as $$
  select p.id, p.username, p.display_name, p.bio, p.birth_date, p.avatar_url
  from public.profiles p
  where p.id = auth.uid();
$$;

drop function if exists public.search_users(text);
create or replace function public.search_users(p_query text)
returns table (id uuid, username text, display_name text, avatar_url text)
language sql
security definer
set search_path = public
as $$
  select p.id, p.username, p.display_name, p.avatar_url
  from public.profiles p
  where p.id <> auth.uid()
    and p.username is not null
    and p.username ilike p_query || '%'
  order by p.username
  limit 20;
$$;

drop function if exists public.list_friends();
create or replace function public.list_friends()
returns table (friend_id uuid, username text, display_name text, avatar_url text)
language sql
security definer
set search_path = public
as $$
  select p.id, p.username, p.display_name, p.avatar_url
  from public.friendships f
  join public.profiles p on p.id = (
    case when f.requester_id = auth.uid() then f.addressee_id else f.requester_id end
  )
  where (f.requester_id = auth.uid() or f.addressee_id = auth.uid())
    and f.status = 'accepted'
  order by p.username;
$$;

drop function if exists public.list_friend_requests();
create or replace function public.list_friend_requests()
returns table (
  request_id uuid,
  requester_id uuid,
  requester_username text,
  requester_display_name text,
  requester_avatar_url text,
  created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select f.id, p.id, p.username, p.display_name, p.avatar_url, f.created_at
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
