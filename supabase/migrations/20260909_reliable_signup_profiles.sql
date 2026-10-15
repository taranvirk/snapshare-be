-- Ensure every Supabase Auth user has a corresponding Snapshare profile.
-- Existing profiles are preserved; only missing rows are inserted.

create or replace function public.create_snapshare_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  base_username text;
  profile_username text;
  profile_email text;
begin
  -- Serialize username selection so simultaneous signups cannot choose the same name.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('snapshare-profile-username'));

  base_username := pg_catalog.lower(
    pg_catalog.regexp_replace(
      coalesce(
        nullif(new.raw_user_meta_data ->> 'preferred_username', ''),
        nullif(new.raw_user_meta_data ->> 'user_name', ''),
        nullif(new.raw_user_meta_data ->> 'name', ''),
        nullif(pg_catalog.split_part(coalesce(new.email, ''), '@', 1), ''),
        'snapuser'
      ),
      '[^a-zA-Z0-9._]+',
      '',
      'g'
    )
  );
  base_username := pg_catalog.left(base_username, 200);

  if pg_catalog.char_length(base_username) < 3 then
    base_username := 'snapuser';
  end if;

  profile_username := base_username;
  if exists (
    select 1
    from public.users123
    where pg_catalog.lower(username) = pg_catalog.lower(profile_username)
  ) then
    profile_username := pg_catalog.left(base_username, 218)
      || '_'
      || pg_catalog.replace(new.id::text, '-', '');
  end if;

  profile_email := coalesce(
    new.email,
    pg_catalog.replace(new.id::text, '-', '') || '@users.snapshare.local'
  );
  if exists (
    select 1
    from public.users123
    where email = profile_email
      and user_id <> new.id::text
  ) then
    profile_email := pg_catalog.replace(new.id::text, '-', '')
      || '@users.snapshare.local';
  end if;

  insert into public.users123 (
    user_id,
    username,
    email,
    user_bio,
    profile_picture_url,
    website,
    created_at,
    updated_at
  )
  values (
    new.id::text,
    profile_username,
    profile_email,
    '',
    coalesce(
      nullif(new.raw_user_meta_data ->> 'avatar_url', ''),
      nullif(new.raw_user_meta_data ->> 'picture', ''),
      ''
    ),
    '',
    coalesce(new.created_at, pg_catalog.now()),
    pg_catalog.now()
  )
  on conflict (user_id) do nothing;

  return new;
end;
$$;

revoke all on function public.create_snapshare_profile() from public;

drop trigger if exists on_auth_user_created_snapshare_profile on auth.users;
create trigger on_auth_user_created_snapshare_profile
after insert on auth.users
for each row execute function public.create_snapshare_profile();

-- Repair users created before the trigger existed. A UUID suffix guarantees that
-- generated usernames stay unique without changing any existing profile.
insert into public.users123 (
  user_id,
  username,
  email,
  user_bio,
  profile_picture_url,
  website,
  created_at,
  updated_at
)
select
  auth_user.id::text,
  'snapuser_' || pg_catalog.replace(auth_user.id::text, '-', ''),
  case
    when auth_user.email is not null
      and not exists (
        select 1 from public.users123 as email_owner
        where email_owner.email = auth_user.email
      )
    then auth_user.email
    else pg_catalog.replace(auth_user.id::text, '-', '') || '@users.snapshare.local'
  end,
  '',
  coalesce(
    nullif(auth_user.raw_user_meta_data ->> 'avatar_url', ''),
    nullif(auth_user.raw_user_meta_data ->> 'picture', ''),
    ''
  ),
  '',
  coalesce(auth_user.created_at, pg_catalog.now()),
  pg_catalog.now()
from auth.users as auth_user
where not exists (
  select 1
  from public.users123 as profile
  where profile.user_id = auth_user.id::text
)
on conflict do nothing;
