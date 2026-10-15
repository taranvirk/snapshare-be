-- Reliable, idempotent follows for Snapshare.
-- Run in the same Supabase project used by the frontend.

begin;

-- Preserve one copy of each existing relationship before enforcing uniqueness.
delete from public.followers duplicate
using public.followers kept
where duplicate.follower_id = kept.follower_id
  and duplicate.following_id = kept.following_id
  and duplicate.ctid > kept.ctid;

delete from public.followers
where follower_id = following_id;

create unique index if not exists followers_unique_pair_idx
    on public.followers (follower_id, following_id);

alter table public.followers
    drop constraint if exists followers_distinct_users;
alter table public.followers
    add constraint followers_distinct_users check (follower_id <> following_id);

-- Repair a serial/identity sequence that may be behind the table's current IDs.
do $$
declare
    sequence_name text := pg_get_serial_sequence('public.followers', 'id');
    highest_id bigint;
    has_rows boolean;
begin
    if sequence_name is not null then
        select coalesce(max(id), 1), count(*) > 0
        into highest_id, has_rows
        from public.followers;
        perform setval(sequence_name::regclass, highest_id, has_rows);
        execute format('grant usage, select on sequence %s to authenticated', sequence_name);
    end if;
end;
$$;

alter table public.followers enable row level security;

-- Replace legacy policies so an older permissive rule cannot override these checks.
do $$
declare
    existing_policy record;
begin
    for existing_policy in
        select policyname
        from pg_policies
        where schemaname = 'public' and tablename = 'followers'
    loop
        execute format('drop policy %I on public.followers', existing_policy.policyname);
    end loop;
end;
$$;

create policy "Authenticated users can view follows"
on public.followers for select
to authenticated
using (true);

create policy "Users can follow from their own account"
on public.followers for insert
to authenticated
with check (auth.uid()::text = follower_id::text and follower_id <> following_id);

create policy "Users can remove their own follows"
on public.followers for delete
to authenticated
using (auth.uid()::text = follower_id::text);

revoke all on table public.followers from anon;
grant select, insert, delete on table public.followers to authenticated;

commit;
