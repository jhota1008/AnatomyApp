alter table public.structures
  add column if not exists target_type text not null default 'point'
  check (target_type in ('point', 'circle'));

alter table public.structures
  add column if not exists radius double precision
  check (radius is null or (radius > 0 and radius <= 25));
