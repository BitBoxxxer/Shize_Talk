-- ============================================================================
-- Shize Talk — токены устройств для push-уведомлений (Firebase Cloud
-- Messaging). Само отправление пуша делает Edge Function (см. отдельный
-- файл send-message-push/index.ts) — эта миграция только про хранение токенов.
-- Выполнить один раз в Supabase → SQL Editor, после 15.
-- ============================================================================

create table if not exists public.push_tokens (
  user_id uuid not null references public.profiles(id) on delete cascade,
  token text not null,
  platform text not null check (platform in ('android', 'ios')),
  updated_at timestamptz not null default now(),
  primary key (token)
);

create index if not exists push_tokens_user_id_idx on public.push_tokens (user_id);

alter table public.push_tokens enable row level security;

create policy push_tokens_select on public.push_tokens
  for select using (auth.uid() = user_id);
-- вставки/обновления/удаления — только через RPC ниже; сама отправка пушей
-- идёт из Edge Function с service-role ключом, ей RLS не мешает.

create or replace function public.upsert_push_token(p_token text, p_platform text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_platform not in ('android', 'ios') then
    raise exception 'Неизвестная платформа';
  end if;

  -- Один и тот же токен теоретически может "переехать" к другому пользователю
  -- (переустановка приложения на другой аккаунт на этом же устройстве) —
  -- поэтому просто перезаписываем владельца, а не блокируем конфликт.
  insert into public.push_tokens (user_id, token, platform, updated_at)
  values (auth.uid(), p_token, p_platform, now())
  on conflict (token) do update
  set user_id = excluded.user_id, platform = excluded.platform, updated_at = now();
end;
$$;

-- Вызывать при выходе из аккаунта (logout), чтобы после сайнаута это
-- устройство не продолжало получать пуши для уже вышедшего пользователя.
create or replace function public.delete_push_token(p_token text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.push_tokens where token = p_token and user_id = auth.uid();
end;
$$;
