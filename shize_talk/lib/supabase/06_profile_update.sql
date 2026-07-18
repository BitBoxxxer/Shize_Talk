-- ============================================================================
-- Shize Talk — RPC для редактирования профиля (display_name)
-- Юзернейм уже можно менять через существующий public.set_username(p_username).
-- Выполнить один раз в Supabase → SQL Editor, после 05_usernames_friends_chats.sql
-- ============================================================================

create or replace function public.update_display_name(p_display_name text)
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

  update public.profiles
  set display_name = trim(p_display_name)
  where id = auth.uid();
end;
$$;

-- Удобный RPC, чтобы экран профиля одним вызовом получал и username, и display_name
create or replace function public.get_my_profile()
returns table (id uuid, username text, display_name text)
language sql
security definer
set search_path = public
as $$
  select p.id, p.username, p.display_name
  from public.profiles p
  where p.id = auth.uid();
$$;
