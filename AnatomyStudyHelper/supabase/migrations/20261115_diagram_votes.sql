create table public.diagram_votes (
  diagram_id uuid not null references public.diagrams (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  value smallint not null check (value in (-1, 1)),
  primary key (diagram_id, user_id)
);

alter table public.diagram_votes enable row level security;

create policy "Users can read their own votes" on public.diagram_votes
  for select to authenticated using (user_id = (select auth.uid()));

create policy "Users can vote on others' public diagrams" on public.diagram_votes
  for insert to authenticated with check (
    user_id = (select auth.uid()) and exists (
      select 1 from public.diagrams
      where id = diagram_id and visibility = 'public' and user_id <> (select auth.uid())
    )
  );

create policy "Users can change their own public diagram votes" on public.diagram_votes
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid()) and exists (
      select 1 from public.diagrams
      where id = diagram_id and visibility = 'public' and user_id <> (select auth.uid())
    )
  );

create policy "Users can remove their own votes" on public.diagram_votes
  for delete to authenticated using (user_id = (select auth.uid()));

create function public.get_public_diagram_ratings()
returns table (diagram_id uuid, upvotes bigint, downvotes bigint, my_vote smallint)
language sql stable security definer set search_path = ''
as $$
  select diagrams.id,
    count(*) filter (where votes.value = 1),
    count(*) filter (where votes.value = -1),
    max(votes.value) filter (where votes.user_id = (select auth.uid()))
  from public.diagrams as diagrams
  left join public.diagram_votes as votes on votes.diagram_id = diagrams.id
  where diagrams.visibility = 'public' and (select auth.uid()) is not null
  group by diagrams.id;
$$;

revoke all on function public.get_public_diagram_ratings() from public, anon;
grant execute on function public.get_public_diagram_ratings() to authenticated;