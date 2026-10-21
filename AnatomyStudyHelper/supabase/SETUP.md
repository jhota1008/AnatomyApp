# Supabase setup

1. Create a Supabase project.
2. In the Supabase SQL Editor, run `schema.sql`. It creates the `diagrams` and `structures` tables, enables row-level security, and creates the private `anatomy-diagrams` Storage bucket and access policies.
3. In Project Settings → API, copy the Project URL and anon/publishable key. Do not use a service-role or secret key in the browser app.
4. Copy `.env.example` to `.env.local` and set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` to those values.
5. In Authentication → Providers, enable Email. Configure email confirmation as desired; when enabled, users must confirm their email before signing in.
6. Restart the Vite server, then create an account in the app.

The browser client uses the public anon/publishable key. Row-level security policies scope records and image paths to the signed-in user. Never add a Supabase service-role key to a `VITE_` variable.

After signing in, the app offers to import diagrams saved by the older browser-local version. Each local copy is removed only after its image, diagram, and structures have been uploaded successfully.
