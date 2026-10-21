create table if not exists public.folders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 80),
  created_at timestamptz not null default now()
);

create unique index if not exists folders_user_name_lower_idx
  on public.folders (user_id, lower(name));

create index if not exists diagrams_folder_id_idx on public.diagrams (folder_id);

alter table public.diagrams
  add column if not exists folder_id uuid references public.folders (id) on delete set null;

insert into public.folders (user_id, name)
select user_id, min(btrim(folder_name))
from public.diagrams
where folder_name is not null and btrim(folder_name) <> ''
group by user_id, lower(btrim(folder_name))
on conflict do nothing;

update public.diagrams as diagram
set folder_id = folder.id
from public.folders as folder
where diagram.folder_id is null
  and diagram.folder_name is not null
  and lower(btrim(diagram.folder_name)) = lower(folder.name)
  and diagram.user_id = folder.user_id;

update public.diagrams set folder_name = null where folder_name is not null;

alter table public.folders enable row level security;
drop policy if exists "Users can manage their own folders" on public.folders;
create policy "Users can manage their own folders"
  on public.folders for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create or replace function public.ensure_diagram_folder_owner()
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

drop trigger if exists diagrams_folder_owner_check on public.diagrams;
create trigger diagrams_folder_owner_check
  before insert or update of folder_id, user_id on public.diagrams
  for each row execute function public.ensure_diagram_folder_owner();
