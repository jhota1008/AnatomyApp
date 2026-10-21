alter table public.diagrams
  add column if not exists folder_name text;

alter table public.diagrams
  add column if not exists tags text[] not null default '{}';

alter table public.diagrams
  add column if not exists visibility text not null default 'private'
  check (visibility in ('private', 'public'));

drop policy if exists "Users can manage their own diagrams" on public.diagrams;
create policy "Users can read own and public diagrams"
  on public.diagrams for select to authenticated
  using (user_id = (select auth.uid()) or visibility = 'public');
create policy "Users can insert own diagrams"
  on public.diagrams for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "Users can update own diagrams"
  on public.diagrams for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
create policy "Users can delete own diagrams"
  on public.diagrams for delete to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "Users can manage structures on their diagrams" on public.structures;
create policy "Users can read structures on own and public diagrams"
  on public.structures for select to authenticated
  using (exists (
    select 1 from public.diagrams
    where diagrams.id = structures.diagram_id
      and (diagrams.user_id = (select auth.uid()) or diagrams.visibility = 'public')
  ));
create policy "Users can insert structures on own diagrams"
  on public.structures for insert to authenticated
  with check (exists (
    select 1 from public.diagrams
    where diagrams.id = structures.diagram_id and diagrams.user_id = (select auth.uid())
  ));
create policy "Users can update structures on own diagrams"
  on public.structures for update to authenticated
  using (exists (
    select 1 from public.diagrams
    where diagrams.id = structures.diagram_id and diagrams.user_id = (select auth.uid())
  ))
  with check (exists (
    select 1 from public.diagrams
    where diagrams.id = structures.diagram_id and diagrams.user_id = (select auth.uid())
  ));
create policy "Users can delete structures on own diagrams"
  on public.structures for delete to authenticated
  using (exists (
    select 1 from public.diagrams
    where diagrams.id = structures.diagram_id and diagrams.user_id = (select auth.uid())
  ));

drop policy if exists "Users can read their own diagram images" on storage.objects;
create policy "Users can read own and public diagram images"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'anatomy-diagrams'
    and (
      (storage.foldername(name))[1] = (select auth.uid())::text
      or exists (
        select 1 from public.diagrams
        where diagrams.image_path = name and diagrams.visibility = 'public'
      )
    )
  );
