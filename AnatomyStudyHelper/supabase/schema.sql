create table public.folders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 80),
  created_at timestamptz not null default now()
);

create unique index folders_user_name_lower_idx on public.folders (user_id, lower(name));

create table public.diagrams (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  title text not null default 'Untitled diagram',
  image_path text not null,
  folder_id uuid references public.folders (id) on delete set null,
  tags text[] not null default '{}',
  visibility text not null default 'private' check (visibility in ('private', 'public')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.structures (
  id uuid primary key default gen_random_uuid(),
  diagram_id uuid not null references public.diagrams (id) on delete cascade,
  name text not null,
  x double precision not null check (x >= 0 and x <= 100),
  y double precision not null check (y >= 0 and y <= 100),
  label_x double precision check (label_x is null or (label_x >= 0 and label_x <= 100)),
  label_y double precision check (label_y is null or (label_y >= 0 and label_y <= 100)),
  target_type text not null default 'point' check (target_type in ('point', 'circle')),
  radius double precision check (radius is null or (radius > 0 and radius <= 25)),
  position integer not null default 0
);

create index diagrams_user_id_updated_at_idx
  on public.diagrams (user_id, updated_at desc);

create index diagrams_folder_id_idx on public.diagrams (folder_id);

create index structures_diagram_id_position_idx
  on public.structures (diagram_id, position);

alter table public.diagrams enable row level security;
alter table public.structures enable row level security;
alter table public.folders enable row level security;

create policy "Users can manage their own folders"
  on public.folders
  for all
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create function public.ensure_diagram_folder_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.folder_id is not null and not exists (
    select 1 from public.folders
    where id = new.folder_id and user_id = new.user_id
  ) then
    raise exception 'Diagram folder must belong to its owner' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger diagrams_folder_owner_check
  before insert or update of folder_id, user_id on public.diagrams
  for each row execute function public.ensure_diagram_folder_owner();

create policy "Users can read own and public diagrams"
  on public.diagrams
  for select
  to authenticated
  using (user_id = (select auth.uid()) or visibility = 'public');

create policy "Users can insert own diagrams"
  on public.diagrams
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy "Users can update own diagrams"
  on public.diagrams
  for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "Users can delete own diagrams"
  on public.diagrams
  for delete
  to authenticated
  using (user_id = (select auth.uid()));

create policy "Users can read structures on own and public diagrams"
  on public.structures
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.diagrams
      where diagrams.id = structures.diagram_id
        and (diagrams.user_id = (select auth.uid()) or diagrams.visibility = 'public')
    )
  );

create policy "Users can insert structures on own diagrams"
  on public.structures
  for insert
  to authenticated
  with check (
    exists (
      select 1 from public.diagrams
      where diagrams.id = structures.diagram_id and diagrams.user_id = (select auth.uid())
    )
  );

create policy "Users can update structures on own diagrams"
  on public.structures
  for update
  to authenticated
  using (
    exists (
      select 1 from public.diagrams
      where diagrams.id = structures.diagram_id and diagrams.user_id = (select auth.uid())
    )
  )
  with check (
    exists (
      select 1 from public.diagrams
      where diagrams.id = structures.diagram_id and diagrams.user_id = (select auth.uid())
    )
  );

create policy "Users can delete structures on own diagrams"
  on public.structures
  for delete
  to authenticated
  using (
    exists (
      select 1 from public.diagrams
      where diagrams.id = structures.diagram_id and diagrams.user_id = (select auth.uid())
    )
  );

insert into storage.buckets (id, name, public)
values ('anatomy-diagrams', 'anatomy-diagrams', false)
on conflict (id) do nothing;

create policy "Users can read own and public diagram images"
  on storage.objects
  for select
  to authenticated
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