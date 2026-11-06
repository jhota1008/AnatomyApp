# Public Launch TODO

## Test in Supabase

- Apply `migrations/20261105_launch_hardening.sql` with the Supabase SQL editor or migration tooling.
- Confirm the `anatomy-diagrams` bucket still permits `image/webp` uploads up to 25 MB.
- Confirm existing PNG/JPEG image replacements fail until those files are converted; new uploads are converted by the browser.
- Test private diagrams from two different signed-in accounts: neither account can read, update, delete, or list the other user's private objects.
- Test public diagrams: other signed-in accounts can read the diagram, image, structures, and allowed public metadata but cannot edit them.
- Verify an authenticated user cannot insert a diagram row with another `user_id`.
- Verify an authenticated user cannot insert or update a folder that belongs to another account.
- Verify storage paths always begin with `{auth.uid()}/{diagram-id}/`.
- Test direct storage URLs, signed URLs, expired URLs, image replacement, and image deletion.

## Implement in Supabase

- Add a server-side per-user storage quota. Browser enforcement can be bypassed. Options:
  - Track optimized upload bytes in a `storage_usage` table with a transactional `reserve_storage` function.
  - Use an Edge Function for upload processing and quota enforcement.
  - Use Supabase billing/storage alerts for growth monitoring, but do not rely on alerts as an access control.
- Choose a public quota and communicate it in the UI. The initial browser implementation uses 250 MB per account.
- Add server-side image validation for MIME type, dimensions, and decoded size. Supabase Storage bucket MIME limits are part of the boundary but a signed URL could still reference unusual content.
- Add an orphan cleanup job for database rows whose image objects were not removed and storage objects whose diagram row no longer exists.
- Review Supabase Auth settings:
  - Require email confirmation for new accounts.
  - Configure Site URL and Redirect URLs for production.
  - Configure password recovery email templates and redirect URLs.
  - Add password-reset-complete UI so recovery links can actually set a new password.
  - Enable captcha or abuse protection if account creation begins receiving automated signups.
  - Review password, session, refresh-token, email-rate-limit, and signup-rate-limit settings.
- Add auth audit/monitoring and alerts for unusual signup, password-reset, or storage activity.
- Add database backups and a tested restore procedure.

## Browser UX tests

- Upload 0, 1, 20, and 21 valid files.
- Test source files over 25 MB, unusual extensions, corrupt images, and dimensions over 16,000 px.
- Cancel the resize modal and then open replacement/upload again.
- Replace an image and verify the database, signed URL, old object, and new object remain consistent.
- Test the 250 MB estimate at low available storage and after deleting diagrams.
- Test sign-up confirmation, sign-out, sign-in, reset-link request, expired sessions, and network failure states.
- Test Chrome and Safari WebP canvas conversion, especially transparent and very large images.
- Test labels outside image bounds, point placement, circle placement, dragging, zoom, and fitting on portrait/landscape images.
- Test mobile layouts and browser widths around 320, 768, 1024, and 1440 pixels.

## Before broad public sharing

- Run all private/public RLS tests with two real accounts.
- Complete backup, restore, account-deletion, and orphan cleanup procedures.
- Add an account-deletion flow that removes owned diagrams, structures, folders, and all storage objects.
- Run a trusted-user beta with usage and cost monitoring for at least one week.
