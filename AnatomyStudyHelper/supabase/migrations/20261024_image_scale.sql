alter table public.diagrams
  add column if not exists image_scale double precision not null default 100
  check (image_scale >= 50 and image_scale <= 200);