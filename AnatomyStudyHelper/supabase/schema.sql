create table public.diagrams (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  title text not null default 'Untitled diagram',
  image_path text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.structures (
  id uuid primary key default gen_random_uuid(),
  diagram_id uuid not null references public.diagrams (id) on delete cascade,
  name text not null,
  x double precision not null check (x >= 0 and x <= 100),
  y double precision not null check (y >= 0 and y <= 100),
  position integer not null default 0
);

create index diagrams_user_id_updated_at_idx
  on public.diagrams (user_id, updated_at desc);

create index structures_diagram_id_position_idx
  on public.structures (diagram_id, position);

alter table public.diagrams enable row level security;
alter table public.structures enable row level security;

create policy "Users can manage their own diagrams"
  on public.diagrams
  for all
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "Users can manage structures on their diagrams"
  on public.structures
  for all
  to authenticated
  using (
    exists (
      select 1
      from public.diagrams
      where diagrams.id = structures.diagram_id
        and diagrams.user_id = (select auth.uid())
    )
  )
  with check (
    exists (
      select 1
      from public.diagrams
      where diagrams.id = structures.diagram_id
        and diagrams.user_id = (select auth.uid())
    )
  );

insert into storage.buckets (id, name, public)
values ('anatomy-diagrams', 'anatomy-diagrams', false)
on conflict (id) do nothing;

create policy "Users can read their own diagram images"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'anatomy-diagrams'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "Users can upload their own diagram images"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'anatomy-diagrams'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "Users can update their own diagram images"
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'anatomy-diagrams'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'anatomy-diagrams'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "Users can delete their own diagram images"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'anatomy-diagrams'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );