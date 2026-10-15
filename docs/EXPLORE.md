# Snapshare Explore architecture

## Current system

Snapshare's active client is the sibling `snapshare-fe` React 18/Vite application. It authenticates with Supabase Auth and performs normal application reads and writes with the authenticated Supabase browser client. React Router owns page navigation. The root `snapshare-be` Express application is still used for a few legacy/account-management routes and uses a server-only service-role key; it is not in the Explore request path. The nested `snapshare-be/backend` folder is an older, incompatible API implementation and should not be extended.

Current social data lives in `users123`, `posts`, `user_likes`, `likes`, `comments_test`, `followers`, and `reports`. Media is uploaded by `CreatePost.jsx` to the public `Upload` storage bucket and post rows store an array of public URLs in `file_url`; some legacy rows may use `image_url`. Home builds a following feed in the browser. Search fetches a bounded set of users and posts and filters them locally. Post detail, comments, profiles, follows, messages, and notifications are reusable rather than duplicated for Explore.

The existing schema did not contain saves, blocks, views/impressions, hashtags, private-account state, or a recommendation query. Like totals were maintained by read/modify/write code in the client, which was vulnerable to lost updates. Public profile reads used `users123`, exposing fields such as email and `password_hash` through the anonymous API.

## Implemented Explore flow

1. The authenticated user opens `/explore`.
2. `useExploreFeed` fixes an `asOf` timestamp for the browsing session and calls the authenticated `get_explore_feed` PostgreSQL RPC.
3. PostgreSQL generates bounded recent, popular, social, and creator-affinity candidate pools, filters inaccessible or irrelevant posts, computes features in batches, ranks them, and applies a two-post-per-creator diversity cap.
4. The RPC returns denormalized post, safe author, engagement, viewer-state, score, and explanation fields. This avoids browser-side joins and N+1 requests.
5. React renders the first page in a responsive grid. An `IntersectionObserver` requests the next keyset-cursor page near the end of the grid.
6. Page merging is idempotent by `post_id`. Loaded results are recorded as impressions and opening a tile records a click. The existing `/post/:postId` page is the canonical detail view.

No new Express route is required for version one. The ranking operation belongs close to the relational data and the authenticated RPC is protected by explicit grants, an auth check, and a fixed search path.

## Data changes

`20260907_explore_feed.sql` adds only data that the first recommendation version can use:

- `post_saves`: one saved relationship per user/post.
- `user_blocks`: one directional block relationship per user pair.
- `explore_impressions`: first/last load time, load count, and latest click time per user/post.
- `post_hashtags`: normalized hashtags extracted from captions by a trigger.
- `user_likes.created_at`: time information for future recency-aware personalization.
- An authoritative trigger that derives `likes.like_count` from `user_likes`.
- Supporting indexes for follows, engagement, post cursors, hashtags, blocks, and impressions.
- `public_profiles`, a safe public-profile projection without email or password-related fields.

The migration preserves existing data, deduplicates legacy likes before adding uniqueness, backfills hashtags and like counts, and is safe to rerun. Existing `posts.image_url` rows remain eligible when `file_url` is empty.

## Candidate generation and ranking

The candidate stage bounds ranking work before scoring:

- Up to 300 newest eligible posts.
- Up to 250 posts with the strongest weighted raw engagement.
- Up to 200 posts interacted with by people the viewer follows.
- Up to 150 recent posts from creators whose work the viewer has previously liked, commented on, or saved.

The score is rule-based and inspectable:

```text
score = 0.30 * recency
      + 0.25 * normalized engagement
      + 0.15 * followed-user activity
      + 0.15 * hashtag overlap
      + 0.10 * creator affinity
      + 0.05 * deterministic daily discovery
      - 0.15 * recent repeat penalty
```

Recency uses exponential decay over a seven-day time scale. Engagement combines log-normalized likes (45%), comments (35%), and saves (20%), which prevents a single viral count from overwhelming every other signal. Social, topic, affinity, and repeat features are capped. A deterministic hash provides limited daily exploration without making cursor ordering unstable. Scores are rounded, sorted with `created_at` and `post_id` tie-breakers, and limited to two posts per creator.

The feed excludes the viewer's posts, creators already followed, blocks in either direction, posts the viewer reported, posts newer than the fixed session timestamp, and rows without a usable media URL. Recent impressions reduce ranking rather than permanently excluding a post, allowing a sparse community to continue producing a feed.

## API contract and pagination

The browser calls:

```text
get_explore_feed(
  p_limit,
  p_cursor_score,
  p_cursor_created_at,
  p_cursor_post_id,
  p_as_of
)
```

Each item contains the post and author IDs, caption, media URLs, author display fields, like/comment/save counts, viewer liked/saved flags, score, and a short recommendation reason. The next request uses the last displayed item's `(score, created_at, post_id)` tuple. `p_as_of` remains constant until refresh, so posts created mid-scroll cannot reshuffle existing pages. The client asks for one extra row to determine `hasMore` and removes duplicate IDs defensively.

The client also calls `record_explore_impressions(bigint[])` after a page loads and `record_explore_click(bigint)` when a tile is opened. Both require an authenticated user and reject invalid or excessive input.

## UI structure

- `Explore.jsx`: page shell, refresh/search actions, state switching, and infinite-scroll sentinel.
- `useExploreFeed.js`: request lifecycle, stable cursor snapshot, stale-request protection, dedupe, and impression recording.
- `exploreService.js`: typed-by-convention RPC boundary and friendly migration error.
- `ExploreTile.jsx`: image/video/fallback rendering, engagement overlay, recommendation reason, and click event.
- `ExploreSkeleton.jsx`: loading grid.
- `exploreUtils.js`: pure pagination/media helpers with Node tests.

The grid uses four columns on wide screens, three on medium screens, and two on mobile. Selected tiles span two tracks on desktop for visual rhythm. Mobile restores equal tile sizes and keeps essential metadata visible. Loading, empty, initial-error, loading-more, and end-of-feed states are distinct.

## Security and privacy

The migration revokes anonymous access to application tables, enables RLS, and grants only the operations the authenticated React client needs. Users can mutate only their own profile, follows, likes, comments, reports, saves, blocks, and Explore history. Post writes remain creator-owned. The public profile view deliberately exposes only display-safe columns and filters blocked relationships. Direct post reads also hide blocked and viewer-reported content. Security-definer RPCs pin an empty `search_path`, schema-qualify every relation, validate `auth.uid()`, and are executable only by `authenticated`.

Snapshare does not currently have private accounts, follow requests/approval, or private media delivery. A future privacy phase must add those together: an `is_private` profile flag alone is not enough while media is served from a public bucket. Add accepted/pending follow state, post-read rules, profile visibility rules, and private/signed storage access as one feature.

## Performance and future evolution

Version one performs bounded set-based queries and returns denormalized rows, avoiding N+1 requests. Composite indexes support candidate and cursor filters. Stable keyset pagination avoids large offsets. As the dataset grows, measure RPC plans with `EXPLAIN (ANALYZE, BUFFERS)` and consider a periodically refreshed post-stat/materialized-candidate table. Cache only per-user page results with short TTLs and invalidate on interaction; do not cache across users.

Useful next signals are actual viewport visibility, longer-term click-through, saves, likes, and comments. Impressions and clicks are implemented because they directly improve repeat suppression and evaluation. Dwell time is intentionally deferred until there is a clear product use and a privacy-conscious sampling plan. Machine learning is not justified until event volume is substantially larger and the rule-based baseline can be measured.

## Delivery phases

1. **Foundation (implemented):** migration, secure profile projection, reliable counters, route, responsive grid, states, and detail navigation.
2. **Candidate generation (implemented):** recent, popular, social, and affinity pools.
3. **Personalized ranking (implemented):** normalized rule-based score, hashtag affinity, diversity, repeat penalty, and stable cursor.
4. **Interaction tracking (implemented):** saves, impressions, and clicks. True viewport views and dwell time remain deferred.
5. **Scale work:** query-plan measurement, precomputation, short-lived caching, and monitoring after real traffic exists.
6. **Privacy and refinement:** private accounts/follow approval/private storage, ranking experiments, abuse controls, and product analytics.

## Files changed for Explore

Backend repository:

- `supabase/migrations/20260907_explore_feed.sql`
- `README.md`
- `docs/EXPLORE.md`

Frontend repository:

- `src/App.jsx`, `src/App.css`, and `src/components/Navbar/Navbar.jsx`
- `src/pages/Explore/*`
- `src/lib/postInteractionService.js`
- `src/pages/Home/Home.jsx` and `src/pages/Post/PostPage.jsx`
- `src/pages/Profile/Content/Content.jsx`
- Public-profile query call sites in Home, Search, Notifications, comments, profiles, navigation, post detail, and messaging
- `package.json` and `README.md`

## Verification plan

Automated checks cover duplicate page merging, deterministic cursors, media classification, rapid-message ordering, optimistic/realtime message dedupe, and conversation isolation. ESLint and the Vite production build must remain clean.

After applying the SQL in a staging Supabase project, verify with two or more authenticated accounts:

- Anonymous requests to core tables fail; authenticated safe-profile reads work without exposing email or password fields.
- Self, followed, blocked, and reported posts never appear in Explore.
- Saving and liking are idempotent and concurrent likes produce the correct aggregate count.
- Hashtags are added, changed, and removed when captions change.
- Page cursors return no duplicates or gaps while switching pages and while new posts are created.
- Repeated refreshes increase impression counts and reduce recently repeated items.
- Empty databases, sparse candidate pools, deleted media, failed RPCs, and expired sessions show usable states.
- Grid, keyboard focus, scrolling, and post navigation work at desktop, tablet, and mobile widths.

This feature demonstrates practical recommendation-system design, feature weighting and normalization, multi-source candidate generation, keyset pagination, database triggers, RLS/security-definer boundaries, set-based query optimization, interaction analytics, responsive React UI, and progressive delivery without introducing a new service prematurely.
