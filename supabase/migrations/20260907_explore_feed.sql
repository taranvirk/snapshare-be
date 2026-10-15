-- Snapshare Explore: secure profiles, authoritative engagement, saves,
-- hashtags, blocks, interaction tracking, and a cursor-paginated ranking RPC.
-- Run in the SAME Supabase project configured by the React frontend.

begin;

create table if not exists public.post_saves (
    user_id uuid not null references auth.users(id) on delete cascade,
    post_id bigint not null references public.posts(post_id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (user_id, post_id)
);

create table if not exists public.user_blocks (
    blocker_id uuid not null references auth.users(id) on delete cascade,
    blocked_id uuid not null references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (blocker_id, blocked_id),
    constraint user_blocks_distinct_users check (blocker_id <> blocked_id)
);

create table if not exists public.explore_impressions (
    user_id uuid not null references auth.users(id) on delete cascade,
    post_id bigint not null references public.posts(post_id) on delete cascade,
    first_seen_at timestamptz not null default now(),
    last_seen_at timestamptz not null default now(),
    seen_count integer not null default 1 check (seen_count > 0),
    clicked_at timestamptz,
    primary key (user_id, post_id)
);

create table if not exists public.post_hashtags (
    post_id bigint not null references public.posts(post_id) on delete cascade,
    tag text not null check (tag = lower(tag) and char_length(tag) between 1 and 60),
    primary key (post_id, tag)
);

alter table public.user_likes add column if not exists created_at timestamptz;
alter table public.user_likes alter column created_at set default now();
update public.user_likes set created_at = now() where created_at is null;
alter table public.user_likes alter column created_at set not null;

-- The legacy likes table stored an unused required user_id even though each row
-- represents a post-wide aggregate. New aggregate rows must not invent an owner.
alter table public.likes alter column user_id drop not null;

-- Preserve one row if legacy clients created duplicate likes.
delete from public.user_likes duplicate
using public.user_likes kept
where duplicate.user_id = kept.user_id
  and duplicate.post_id = kept.post_id
  and duplicate.ctid > kept.ctid;

-- Legacy clients could also create more than one aggregate row per post.
-- The aggregate is rebuilt from user_likes below, so keeping either row is safe.
delete from public.likes duplicate
using public.likes kept
where duplicate.post_id = kept.post_id
  and duplicate.ctid > kept.ctid;

create unique index if not exists user_likes_user_post_idx on public.user_likes (user_id, post_id);
create index if not exists user_likes_post_user_idx on public.user_likes (post_id, user_id);
create unique index if not exists likes_post_idx on public.likes (post_id);
create index if not exists comments_test_post_created_idx on public.comments_test (post_id, created_at desc);
create index if not exists posts_created_cursor_idx on public.posts (created_at desc, post_id desc);
create index if not exists posts_creator_created_idx on public.posts (user_id, created_at desc, post_id desc);
create index if not exists followers_following_follower_idx on public.followers (following_id, follower_id);
create index if not exists reports_user_post_idx on public.reports (user_id, post_id);
create index if not exists post_saves_post_user_idx on public.post_saves (post_id, user_id);
create index if not exists explore_impressions_recent_idx on public.explore_impressions (user_id, last_seen_at desc);
create index if not exists post_hashtags_tag_post_idx on public.post_hashtags (tag, post_id);
create index if not exists user_blocks_blocked_blocker_idx on public.user_blocks (blocked_id, blocker_id);

create or replace function public.extract_post_hashtags()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    delete from public.post_hashtags where post_id = new.post_id;
    insert into public.post_hashtags (post_id, tag)
    select new.post_id, lower(matches.value[1])
    from regexp_matches(coalesce(new.caption, ''), '#([[:alnum:]_]{1,60})', 'g') as matches(value)
    on conflict do nothing;
    return new;
end;
$$;

drop trigger if exists extract_post_hashtags on public.posts;
create trigger extract_post_hashtags
after insert or update of caption on public.posts
for each row execute function public.extract_post_hashtags();

insert into public.post_hashtags (post_id, tag)
select post.post_id, lower(matches.value[1])
from public.posts post
cross join lateral regexp_matches(coalesce(post.caption, ''), '#([[:alnum:]_]{1,60})', 'g') as matches(value)
on conflict do nothing;

create or replace function public.sync_post_like_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    affected_post_id bigint;
begin
    affected_post_id := case when tg_op = 'DELETE' then old.post_id else new.post_id end;
    insert into public.likes (post_id, like_count)
    values (
        affected_post_id,
        (select count(*) from public.user_likes where post_id = affected_post_id)
    )
    on conflict (post_id) do update set like_count = excluded.like_count;
    if tg_op = 'DELETE' then
        return old;
    end if;
    return new;
end;
$$;

drop trigger if exists sync_post_like_count on public.user_likes;
create trigger sync_post_like_count
after insert or delete on public.user_likes
for each row execute function public.sync_post_like_count();

insert into public.likes (post_id, like_count)
select post.post_id, count(user_like.post_id)
from public.posts post
left join public.user_likes user_like on user_like.post_id = post.post_id
group by post.post_id
on conflict (post_id) do update set like_count = excluded.like_count;

alter table public.users123 enable row level security;
alter table public.posts enable row level security;
alter table public.user_likes enable row level security;
alter table public.likes enable row level security;
alter table public.comments_test enable row level security;
alter table public.followers enable row level security;
alter table public.reports enable row level security;
alter table public.post_saves enable row level security;
alter table public.user_blocks enable row level security;
alter table public.explore_impressions enable row level security;
alter table public.post_hashtags enable row level security;

-- Replace legacy policies on core tables with the rules the current React app needs.
do $$
declare
    selected_table text;
    existing_policy record;
begin
    foreach selected_table in array array[
        'users123', 'posts', 'user_likes', 'likes', 'comments_test',
        'followers', 'reports', 'post_saves', 'user_blocks',
        'explore_impressions', 'post_hashtags'
    ]
    loop
        for existing_policy in
            select policyname
            from pg_policies
            where schemaname = 'public' and tablename = selected_table
        loop
            execute format('drop policy %I on public.%I', existing_policy.policyname, selected_table);
        end loop;
    end loop;
end;
$$;

create policy "Users manage their own profile"
on public.users123 for all to authenticated
using (auth.uid()::text = user_id::text)
with check (auth.uid()::text = user_id::text);

create policy "Authenticated users view posts"
on public.posts for select to authenticated
using (
    not exists (
        select 1 from public.user_blocks block
        where (block.blocker_id = auth.uid() and block.blocked_id::text = posts.user_id::text)
           or (block.blocked_id = auth.uid() and block.blocker_id::text = posts.user_id::text)
    )
    and not exists (
        select 1 from public.reports report
        where report.user_id::text = auth.uid()::text
          and report.post_id::bigint = posts.post_id::bigint
    )
);
create policy "Creators insert posts"
on public.posts for insert to authenticated with check (auth.uid()::text = user_id::text);
create policy "Creators update posts"
on public.posts for update to authenticated
using (auth.uid()::text = user_id::text) with check (auth.uid()::text = user_id::text);
create policy "Creators delete posts"
on public.posts for delete to authenticated using (auth.uid()::text = user_id::text);

create policy "Authenticated users view likes"
on public.user_likes for select to authenticated using (true);
create policy "Users create their own likes"
on public.user_likes for insert to authenticated with check (auth.uid()::text = user_id::text);
create policy "Users remove their own likes"
on public.user_likes for delete to authenticated using (auth.uid()::text = user_id::text);
create policy "Authenticated users view like counts"
on public.likes for select to authenticated using (true);

create policy "Authenticated users view comments"
on public.comments_test for select to authenticated using (true);
create policy "Users create their own comments"
on public.comments_test for insert to authenticated with check (auth.uid()::text = user_id::text);
create policy "Users update their own comments"
on public.comments_test for update to authenticated
using (auth.uid()::text = user_id::text) with check (auth.uid()::text = user_id::text);
create policy "Users delete their own comments"
on public.comments_test for delete to authenticated using (auth.uid()::text = user_id::text);

create policy "Authenticated users view follows"
on public.followers for select to authenticated using (true);
create policy "Users create their own follows"
on public.followers for insert to authenticated
with check (auth.uid()::text = follower_id::text and follower_id <> following_id);
create policy "Users remove their own follows"
on public.followers for delete to authenticated using (auth.uid()::text = follower_id::text);

create policy "Users create their own reports"
on public.reports for insert to authenticated with check (auth.uid()::text = user_id::text);
create policy "Users view their own reports"
on public.reports for select to authenticated using (auth.uid()::text = user_id::text);

create policy "Users manage their own saves"
on public.post_saves for all to authenticated
using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "Users view blocks involving them"
on public.user_blocks for select to authenticated
using (auth.uid() = blocker_id or auth.uid() = blocked_id);
create policy "Users create their own blocks"
on public.user_blocks for insert to authenticated
with check (auth.uid() = blocker_id and blocker_id <> blocked_id);
create policy "Users remove their own blocks"
on public.user_blocks for delete to authenticated using (auth.uid() = blocker_id);
create policy "Users view their own Explore history"
on public.explore_impressions for select to authenticated using (auth.uid() = user_id);
create policy "Authenticated users view hashtags"
on public.post_hashtags for select to authenticated using (true);

create or replace view public.public_profiles
with (security_barrier = true, security_invoker = false)
as
select profile.user_id,
       profile.username,
       profile.user_bio,
       profile.profile_picture_url,
       profile.website,
       profile.created_at,
       profile.updated_at
from public.users123 profile
where auth.uid() is not null
  and not exists (
      select 1 from public.user_blocks block
      where (block.blocker_id = auth.uid() and block.blocked_id::text = profile.user_id::text)
         or (block.blocked_id = auth.uid() and block.blocker_id::text = profile.user_id::text)
  );

revoke all on table public.users123, public.posts, public.user_likes, public.likes,
    public.comments_test, public.followers, public.reports, public.post_saves,
    public.user_blocks, public.explore_impressions, public.post_hashtags from anon;
revoke all on table public.public_profiles from public, anon;

grant select (user_id, username, email, user_bio, profile_picture_url, website, created_at, updated_at)
    on table public.users123 to authenticated;
grant insert (user_id, username, email, user_bio, profile_picture_url, website)
    on table public.users123 to authenticated;
grant update (user_id, username, email, user_bio, profile_picture_url, website)
    on table public.users123 to authenticated;
grant delete on table public.users123 to authenticated;
grant select, insert, update, delete on table public.posts to authenticated;
grant select, insert, delete on table public.user_likes to authenticated;
grant select on table public.likes to authenticated;
grant select, insert, update, delete on table public.comments_test to authenticated;
grant select, insert, delete on table public.followers to authenticated;
grant select, insert on table public.reports to authenticated;
grant select, insert, update, delete on table public.post_saves to authenticated;
grant select, insert, delete on table public.user_blocks to authenticated;
grant select on table public.explore_impressions, public.post_hashtags, public.public_profiles to authenticated;
grant usage, select on all sequences in schema public to authenticated;

create or replace function public.record_explore_impressions(p_post_ids bigint[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    current_user_id uuid := auth.uid();
begin
    if current_user_id is null then raise exception 'Authentication required'; end if;
    if coalesce(cardinality(p_post_ids), 0) > 100 then raise exception 'Too many posts'; end if;

    insert into public.explore_impressions (user_id, post_id)
    select current_user_id, candidate.post_id
    from (
        select distinct unnest(p_post_ids) as post_id
    ) candidate
    join public.posts post on post.post_id = candidate.post_id
    where post.user_id::text <> current_user_id::text
    on conflict (user_id, post_id) do update
    set last_seen_at = now(),
        seen_count = public.explore_impressions.seen_count + 1;
end;
$$;

create or replace function public.record_explore_click(p_post_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    current_user_id uuid := auth.uid();
begin
    if current_user_id is null then raise exception 'Authentication required'; end if;
    if not exists (
        select 1 from public.posts
        where post_id = p_post_id and user_id::text <> current_user_id::text
    ) then raise exception 'Post not found'; end if;

    insert into public.explore_impressions (user_id, post_id, clicked_at)
    values (current_user_id, p_post_id, now())
    on conflict (user_id, post_id) do update set clicked_at = now();
end;
$$;

create or replace function public.get_explore_feed(
    p_limit integer default 25,
    p_cursor_score double precision default null,
    p_cursor_created_at timestamptz default null,
    p_cursor_post_id bigint default null,
    p_as_of timestamptz default now()
)
returns table (
    post_id bigint,
    user_id uuid,
    caption text,
    image_url text,
    file_url jsonb,
    created_at timestamptz,
    username text,
    profile_picture_url text,
    like_count bigint,
    comment_count bigint,
    save_count bigint,
    viewer_liked boolean,
    viewer_saved boolean,
    score double precision,
    reason text
)
language sql
stable
security definer
set search_path = ''
as $$
with viewer as (
    select auth.uid() as id
),
viewer_following as (
    select follow.following_id::uuid as user_id
    from public.followers follow, viewer
    where follow.follower_id::text = viewer.id::text
),
all_interactions as (
    select user_like.post_id::bigint, user_like.user_id::uuid from public.user_likes user_like
    union all
    select comment.post_id::bigint, comment.user_id::uuid from public.comments_test comment
    union all
    select saved.post_id, saved.user_id from public.post_saves saved
),
viewer_creators as (
    select distinct post.user_id::uuid as user_id
    from all_interactions interaction
    join public.posts post on post.post_id = interaction.post_id
    join viewer on interaction.user_id = viewer.id
),
eligible as materialized (
    select post.post_id::bigint,
           post.user_id::uuid,
           post.caption::text,
           post.image_url::text,
           to_jsonb(post.file_url) as file_url,
           post.created_at,
           profile.username::text,
           profile.profile_picture_url::text
    from public.posts post
    join public.users123 profile on profile.user_id::text = post.user_id::text
    cross join viewer
    where viewer.id is not null
      and post.user_id::text <> viewer.id::text
      and post.created_at <= p_as_of
      and (
          coalesce(jsonb_array_length(to_jsonb(post.file_url)), 0) > 0
          or nullif(post.image_url::text, '') is not null
      )
      and not exists (select 1 from viewer_following follow where follow.user_id::text = post.user_id::text)
      and not exists (
          select 1 from public.user_blocks block
          where (block.blocker_id = viewer.id and block.blocked_id::text = post.user_id::text)
             or (block.blocked_id = viewer.id and block.blocker_id::text = post.user_id::text)
      )
      and not exists (
          select 1 from public.reports report
          where report.post_id::bigint = post.post_id::bigint
            and report.user_id::text = viewer.id::text
      )
),
post_stats as materialized (
    select eligible.post_id,
           count(distinct user_like.user_id)::bigint as like_count,
           count(distinct comment.id)::bigint as comment_count,
           count(distinct saved.user_id)::bigint as save_count
    from eligible
    left join public.user_likes user_like on user_like.post_id::bigint = eligible.post_id
    left join public.comments_test comment on comment.post_id::bigint = eligible.post_id
    left join public.post_saves saved on saved.post_id = eligible.post_id
    group by eligible.post_id
),
recent_pool as (
    select eligible.post_id from eligible order by eligible.created_at desc, eligible.post_id desc limit 300
),
popular_pool as (
    select stats.post_id
    from post_stats stats
    join eligible on eligible.post_id = stats.post_id
    order by (stats.like_count + stats.comment_count * 2 + stats.save_count * 3) desc,
             eligible.created_at desc
    limit 250
),
social_pool as (
    select distinct eligible.post_id
    from eligible
    join all_interactions interaction on interaction.post_id = eligible.post_id
    join viewer_following follow on follow.user_id = interaction.user_id
    limit 200
),
affinity_pool as (
    select eligible.post_id
    from eligible
    join viewer_creators creator on creator.user_id = eligible.user_id
    order by eligible.created_at desc
    limit 150
),
candidate_ids as (
    select post_id from recent_pool
    union select post_id from popular_pool
    union select post_id from social_pool
    union select post_id from affinity_pool
),
social_stats as (
    select candidate.post_id, count(distinct interaction.user_id)::bigint as social_count
    from candidate_ids candidate
    join all_interactions interaction on interaction.post_id = candidate.post_id
    join viewer_following follow on follow.user_id = interaction.user_id
    group by candidate.post_id
),
creator_affinity as (
    select interacted_post.user_id::uuid as user_id, count(*)::bigint as interaction_count
    from all_interactions interaction
    join public.posts interacted_post on interacted_post.post_id = interaction.post_id
    cross join viewer
    where interaction.user_id = viewer.id
    group by interacted_post.user_id
),
viewer_tags as (
    select distinct hashtag.tag
    from public.post_hashtags hashtag
    join all_interactions interaction on interaction.post_id = hashtag.post_id
    cross join viewer
    where interaction.user_id = viewer.id
),
topic_overlap as (
    select candidate.post_id, count(*)::bigint as overlap_count
    from candidate_ids candidate
    join public.post_hashtags hashtag on hashtag.post_id = candidate.post_id
    join viewer_tags viewer_tag on viewer_tag.tag = hashtag.tag
    group by candidate.post_id
),
features as (
    select eligible.*,
           stats.like_count,
           stats.comment_count,
           stats.save_count,
           coalesce(social.social_count, 0)::bigint as social_count,
           coalesce(affinity.interaction_count, 0)::bigint as affinity_count,
           coalesce(topic.overlap_count, 0)::bigint as topic_count,
           impression.seen_count,
           impression.last_seen_at,
           exists (
               select 1 from public.user_likes user_like, viewer
               where user_like.post_id::bigint = eligible.post_id and user_like.user_id::text = viewer.id::text
           ) as viewer_liked,
           exists (
               select 1 from public.post_saves saved, viewer
               where saved.post_id = eligible.post_id and saved.user_id = viewer.id
           ) as viewer_saved,
           max(stats.like_count) over () as maximum_likes,
           max(stats.comment_count) over () as maximum_comments,
           max(stats.save_count) over () as maximum_saves
    from candidate_ids candidate
    join eligible on eligible.post_id = candidate.post_id
    join post_stats stats on stats.post_id = candidate.post_id
    left join social_stats social on social.post_id = candidate.post_id
    left join creator_affinity affinity on affinity.user_id = eligible.user_id
    left join topic_overlap topic on topic.post_id = candidate.post_id
    left join public.explore_impressions impression
      on impression.post_id = eligible.post_id and impression.user_id = auth.uid()
),
scored as (
    select features.*,
           round((
               0.30 * exp(-greatest(extract(epoch from (p_as_of - features.created_at)), 0) / 604800.0)
               + 0.25 * (
                   0.45 * coalesce(ln(1 + features.like_count) / nullif(ln(1 + features.maximum_likes), 0), 0)
                   + 0.35 * coalesce(ln(1 + features.comment_count) / nullif(ln(1 + features.maximum_comments), 0), 0)
                   + 0.20 * coalesce(ln(1 + features.save_count) / nullif(ln(1 + features.maximum_saves), 0), 0)
               )
               + 0.15 * least(features.social_count / 3.0, 1.0)
               + 0.15 * least(features.topic_count / 3.0, 1.0)
               + 0.10 * least(features.affinity_count / 5.0, 1.0)
               + 0.05 * ((('x' || substr(md5(auth.uid()::text || features.post_id::text || p_as_of::date::text), 1, 8))::bit(32)::bigint) / 4294967295.0)
               - 0.15 * case
                   when features.last_seen_at >= p_as_of - interval '7 days'
                   then least(features.seen_count / 5.0, 1.0)
                   else 0
                 end
           )::numeric, 8)::double precision as ranking_score
    from features
),
diversified as (
    select scored.*,
           row_number() over (
               partition by scored.user_id
               order by scored.ranking_score desc, scored.created_at desc, scored.post_id desc
           ) as creator_rank
    from scored
),
cursor_filtered as (
    select * from diversified
    where creator_rank <= 2
      and (
          p_cursor_score is null
          or ranking_score < p_cursor_score
          or (ranking_score = p_cursor_score and created_at < p_cursor_created_at)
          or (ranking_score = p_cursor_score and created_at = p_cursor_created_at and post_id < p_cursor_post_id)
      )
)
select cursor_filtered.post_id,
       cursor_filtered.user_id,
       cursor_filtered.caption,
       cursor_filtered.image_url,
       cursor_filtered.file_url,
       cursor_filtered.created_at,
       cursor_filtered.username,
       cursor_filtered.profile_picture_url,
       cursor_filtered.like_count,
       cursor_filtered.comment_count,
       cursor_filtered.save_count,
       cursor_filtered.viewer_liked,
       cursor_filtered.viewer_saved,
       cursor_filtered.ranking_score as score,
       case
           when cursor_filtered.social_count > 0 then 'Popular with your circle'
           when cursor_filtered.topic_count > 0 then 'Based on posts you liked'
           when cursor_filtered.save_count > cursor_filtered.like_count then 'Worth saving'
           when cursor_filtered.like_count + cursor_filtered.comment_count > 0 then 'Popular right now'
           else 'Fresh on Snapshare'
       end as reason
from cursor_filtered
order by cursor_filtered.ranking_score desc,
         cursor_filtered.created_at desc,
         cursor_filtered.post_id desc
limit least(greatest(coalesce(p_limit, 25), 1), 50);
$$;

revoke all on function public.get_explore_feed(integer, double precision, timestamptz, bigint, timestamptz) from public, anon;
revoke all on function public.record_explore_impressions(bigint[]) from public, anon;
revoke all on function public.record_explore_click(bigint) from public, anon;
grant execute on function public.get_explore_feed(integer, double precision, timestamptz, bigint, timestamptz) to authenticated;
grant execute on function public.record_explore_impressions(bigint[]) to authenticated;
grant execute on function public.record_explore_click(bigint) to authenticated;

commit;
