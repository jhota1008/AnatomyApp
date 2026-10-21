alter table public.structures
  add column if not exists label_x double precision
  check (label_x is null or (label_x >= 0 and label_x <= 100));

alter table public.structures
  add column if not exists label_y double precision
  check (label_y is null or (label_y >= 0 and label_y <= 100));
