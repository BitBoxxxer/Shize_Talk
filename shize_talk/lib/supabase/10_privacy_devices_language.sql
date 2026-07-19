-- ============================================================================
-- Shize Talk — приватность аватарки, язык интерфейса, список устройств.
-- Выполнить один раз в Supabase → SQL Editor, после 05, 06, 07, 08, 09.
-- ============================================================================

-- 1. Приватность аватарки и язык -------------------------------------------------
alter table public.profiles
  add column if not exists avatar_visibility text not null default 'everyone'
  check (avatar_visibility in ('everyone', 'friends'));

alter table public.profiles
  add column if not exists language text not null default 'ru'
  check (language in ('ru', 'en', 'es'));

create or replace function public.update_privacy_settings(p_avatar_visibility text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_avatar_visibility not in ('everyone', 'friends') then
    raise exception 'Неизвестное значение приватности';
  end if;
  update public.profiles set avatar_visibility = p_avatar_visibility where id = auth.uid();
end;
$$;

create or replace function public.update_language(p_language text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_language not in ('ru', 'en', 'es') then
    raise exception 'Неизвестный язык';
  end if;
  update public.profiles set language = p_language where id = auth.uid();
end;
$$;

-- get_my_profile — добавляем новые поля (форма OUT-параметров меняется,
-- поэтому сначала дропаем старую версию).
drop function if exists public.get_my_profile();

create or replace function public.get_my_profile()
returns table (
  id uuid,
  username text,
  display_name text,
  bio text,
  birth_date date,
  avatar_url text,
  avatar_visibility text,
  language text
)
language sql
security definer
set search_path = public
as $$
  select p.id, p.username, p.display_name, p.bio, p.birth_date,
         p.avatar_url, p.avatar_visibility, p.language
  from public.profiles p
  where p.id = auth.uid();
$$;

-- 2. Проверка дружбы (нужна, чтобы скрывать аватарку от не-друзей) ----------------
create or replace function public.is_friend(p_a uuid, p_b uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.friendships f
    where f.status = 'accepted'
      and ((f.requester_id = p_a and f.addressee_id = p_b)
        or (f.requester_id = p_b and f.addressee_id = p_a))
  );
$$;

-- Применяем правило приватности к чужому avatar_url: показываем, если
-- аватарка открыта всем, либо если смотрящий — сам владелец или друг.
create or replace function public.visible_avatar_url(
  p_owner_id uuid,
  p_avatar_url text,
  p_visibility text
)
returns text
language sql
security definer
set search_path = public
stable
as $$
  select case
    when p_avatar_url is null then null
    when p_owner_id = auth.uid() then p_avatar_url
    when p_visibility = 'everyone' then p_avatar_url
    when public.is_friend(p_owner_id, auth.uid()) then p_avatar_url
    else null
  end;
$$;

-- search_users, list_chats — прогоняем avatar_url через правило приватности.
create or replace function public.search_users(p_query text)
returns table (id uuid, username text, display_name text, avatar_url text)
language sql
security definer
set search_path = public
stable
as $$
  select p.id, p.username, p.display_name,
         public.visible_avatar_url(p.id, p.avatar_url, p.avatar_visibility)
  from public.profiles p
  where p.username ilike '%' || p_query || '%'
     or p.display_name ilike '%' || p_query || '%'
  limit 20;
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
    public.visible_avatar_url(other_p.id, other_p.avatar_url, other_p.avatar_visibility),
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

-- 3. Устройства (сессии) -----------------------------------------------------------
-- ВАЖНО: это только информационный список "откуда заходили" — anon-key
-- клиент не может прицельно завершить чужую auth-сессию Supabase (для
-- настоящего remote-logout нужен service-role бэкенд, его тут нет). Кнопка
-- "Завершить" удаляет запись из списка и помечает устройство как отозванное;
-- реальный форс-логаут этого устройства — задача на будущее с Edge Function.
create table if not exists public.user_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  device_id text not null,
  device_name text,
  platform text,
  app_version text,
  created_at timestamptz not null default now(),
  last_active_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique (user_id, device_id)
);

alter table public.user_devices enable row level security;

create policy user_devices_select on public.user_devices
  for select using (auth.uid() = user_id);

-- вставки/обновления только через SECURITY DEFINER RPC ниже.

create or replace function public.touch_device(
  p_device_id text,
  p_device_name text,
  p_platform text,
  p_app_version text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.user_devices (user_id, device_id, device_name, platform, app_version)
  values (auth.uid(), p_device_id, p_device_name, p_platform, p_app_version)
  on conflict (user_id, device_id) do update
  set last_active_at = now(),
      device_name = excluded.device_name,
      platform = excluded.platform,
      app_version = excluded.app_version,
      revoked_at = null;
end;
$$;

create or replace function public.list_my_devices()
returns table (
  device_id text,
  device_name text,
  platform text,
  app_version text,
  created_at timestamptz,
  last_active_at timestamptz,
  is_current boolean
)
language sql
security definer
set search_path = public
stable
as $$
  select d.device_id, d.device_name, d.platform, d.app_version,
         d.created_at, d.last_active_at, false as is_current
  from public.user_devices d
  where d.user_id = auth.uid() and d.revoked_at is null
  order by d.last_active_at desc;
$$;

create or replace function public.revoke_device(p_device_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.user_devices
  set revoked_at = now()
  where user_id = auth.uid() and device_id = p_device_id;
end;
$$;
