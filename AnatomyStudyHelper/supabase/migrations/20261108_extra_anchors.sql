alter table public.structures
  add column if not exists extra_anchors jsonb not null default '[]'::jsonb
  check (jsonb_typeof(extra_anchors) = 'array');
