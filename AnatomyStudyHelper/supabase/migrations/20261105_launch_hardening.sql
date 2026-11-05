-- Public-launch storage limits for the browser-optimized WebP upload workflow.
update storage.buckets
set
  file_size_limit = 26214400,
  allowed_mime_types = array['image/webp']::text[]
where id = 'anatomy-diagrams';

-- Prevent oversized or invalid zoom values at the database boundary.
alter table public.diagrams
  drop constraint if exists diagrams_image_scale_check,
  add constraint diagrams_image_scale_check
  check (image_scale >= 50 and image_scale <= 200);

alter table public.structures
  drop constraint if exists structures_name_length_check,
  add constraint structures_name_length_check
  check (char_length(btrim(name)) between 1 and 120);

alter table public.diagrams
  drop constraint if exists diagrams_title_length_check,
  add constraint diagrams_title_length_check
  check (char_length(btrim(title)) between 1 and 120);
