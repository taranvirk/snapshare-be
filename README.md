# Snapshare API

Express backend for Snapshare's legacy profile, post, and account-management routes. Direct messages now use the authenticated Supabase client in the React app so database Row Level Security and Supabase Realtime protect the full message flow.

## Local setup

1. Run `npm install`.
2. Copy `.env.example` to `.env`.
3. Add the same Supabase project URL used by the frontend and a freshly rotated service-role key for that project.
4. Run `npm start`.

The API runs on `http://localhost:3000` by default. Use `GET /health` for a lightweight health check.

## Messaging database migration

Before opening Messages, run [`supabase/migrations/20260903_reliable_direct_messages.sql`](supabase/migrations/20260903_reliable_direct_messages.sql) once in the Supabase SQL editor for the **same project configured by the frontend's `VITE_SUPABASE_URL`**.

The migration:

- creates canonical one-to-one conversations and prevents duplicate user pairs;
- creates ordered messages with a unique client ID for duplicate protection;
- migrates valid rows from the legacy `direct_messages` table without deleting it;
- enables participant-only RLS policies; and
- adds `messages` to the Supabase Realtime publication.

The legacy table is retained as an archive, but its client grants are revoked after migration. The migration is designed to be safe to rerun.

For reliable follow/unfollow behavior, also run [`supabase/migrations/20260903_reliable_follows.sql`](supabase/migrations/20260903_reliable_follows.sql). It removes duplicate relationships while preserving one copy, repairs the ID sequence, enforces one row per user pair, and installs authenticated RLS policies.

## Explore database migration

Run [`supabase/migrations/20260907_explore_feed.sql`](supabase/migrations/20260907_explore_feed.sql) in the frontend's Supabase project before using Explore. Apply the migrations in date order: direct messages, follows, then Explore.

The Explore migration is additive and preserves existing posts and engagement. It:

- adds saves, blocks, hashtag extraction, and per-user Explore impression/click tracking;
- makes the `likes` aggregate authoritative with a database trigger and repairs existing counts;
- creates a safe `public_profiles` view so email and password-related profile fields are no longer publicly readable;
- replaces legacy open policies with authenticated RLS rules and hides blocked or user-reported posts;
- adds the indexes used by candidate generation and ranking; and
- exposes authenticated `get_explore_feed`, `record_explore_impressions`, and `record_explore_click` RPCs.

`get_explore_feed` uses recent, popular, social, and creator-affinity candidate pools. It ranks them using recency, normalized engagement, interactions from followed users, hashtag overlap, creator affinity, a small deterministic discovery factor, and a repeat-view penalty. The RPC excludes the signed-in user's posts, followed creators, blocked relationships, reported posts, and posts without usable media. Results use a stable score/time/post cursor and are capped at two posts per creator.

The current schema has no private-account or follow-request model, so Explore cannot enforce private-account visibility until those product concepts are added. Do not add a privacy toggle without also adding follow approval and storage access controls.

After Explore, apply [`supabase/migrations/20260908_lock_down_legacy_tables.sql`](supabase/migrations/20260908_lock_down_legacy_tables.sql). It preserves the unused legacy `following`, `post_files`, and `users` tables while removing their anonymous/authenticated API access and enabling RLS.

See [`docs/EXPLORE.md`](docs/EXPLORE.md) for the audited architecture, scoring formula, request flow, security model, rollout phases, and verification plan.

## Configuration

- `PORT`: API port (defaults to `3000`).
- `CLIENT_ORIGIN`: comma-separated allowed frontend origins.
- `SUPABASE_URL`: Supabase project URL.
- `SUPABASE_SERVICE_ROLE_KEY`: server-only key. Never expose it in the frontend or commit it.
