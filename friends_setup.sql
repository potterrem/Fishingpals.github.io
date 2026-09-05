-- =============================================================================
-- FRIENDS FEATURE SETUP
-- Run this in your Supabase project's SQL Editor (same place you ran the
-- original supabase_setup.sql). This adds a `friends` table plus two helper
-- functions used by the new Friends tab in index.html.
--
-- Assumes `public.profiles` already exists (id uuid primary key referencing
-- auth.users, display_name text) from your original setup.
-- =============================================================================

-- Each row is one direction of a friendship: "user_id considers friend_id a
-- friend". A mutual friendship is two rows (A->B and B->A), both inserted
-- together by add_friend() below - a player can only ever insert the row for
-- their OWN user_id under RLS, so the reverse row has to be written by a
-- function that runs with elevated privileges instead.
create table if not exists public.friends (
  user_id uuid not null references public.profiles(id) on delete cascade,
  friend_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, friend_id),
  check (user_id <> friend_id)
);

alter table public.friends enable row level security;

-- Players can only ever see/delete their OWN side of a friendship edge.
drop policy if exists "friends_select_own" on public.friends;
create policy "friends_select_own"
  on public.friends for select
  using (auth.uid() = user_id);

drop policy if exists "friends_delete_own" on public.friends;
create policy "friends_delete_own"
  on public.friends for delete
  using (auth.uid() = user_id);

-- No direct INSERT policy is defined - all friend creation goes through
-- add_friend() below, since a normal insert policy could never let a player
-- write the reverse (friend_id -> user_id) row needed for a mutual add.

-- Adds a mutual friendship between the calling player and target_id in one
-- step (no separate "accept" flow). SECURITY DEFINER lets it write both
-- directions despite the RLS policies above.
create or replace function public.add_friend(target_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if target_id is null or target_id = auth.uid() then
    raise exception 'Invalid friend id';
  end if;
  if not exists (select 1 from public.profiles where id = target_id) then
    raise exception 'Player not found';
  end if;

  insert into public.friends (user_id, friend_id) values (auth.uid(), target_id)
    on conflict (user_id, friend_id) do nothing;
  insert into public.friends (user_id, friend_id) values (target_id, auth.uid())
    on conflict (user_id, friend_id) do nothing;
end;
$$;

grant execute on function public.add_friend(uuid) to authenticated;

-- Removes both directions of the friendship at once, for the same reason
-- add_friend needs to write both directions.
create or replace function public.remove_friend(target_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.friends where user_id = auth.uid() and friend_id = target_id;
  delete from public.friends where user_id = target_id and friend_id = auth.uid();
end;
$$;

grant execute on function public.remove_friend(uuid) to authenticated;

-- The "Add Friend" search (by username or UID) reads public.profiles
-- directly from the client, the same way the Leaderboard already does - so
-- no additional policy is needed there as long as profiles already has a
-- SELECT policy allowing that (it must, for the leaderboard to work).
--
-- NOTE: display_name is not enforced unique in the original schema, so a
-- username search returns whichever matching account was created first. If
-- you want guaranteed-unique usernames, add:
--   alter table public.profiles add constraint profiles_display_name_unique unique (display_name);
-- (this will fail if any duplicate display_names already exist - rename them
-- first).
