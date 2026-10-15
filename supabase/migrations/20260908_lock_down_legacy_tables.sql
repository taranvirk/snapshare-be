-- Lock down legacy tables that are not used by the active Snapshare client.
-- Data is preserved and the service role retains its normal bypass access.

begin;

alter table if exists public.following enable row level security;
alter table if exists public.post_files enable row level security;
alter table if exists public.users enable row level security;

revoke all on table public.following from anon, authenticated;
revoke all on table public.post_files from anon, authenticated;
revoke all on table public.users from anon, authenticated;

commit;
