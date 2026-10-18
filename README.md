# AquaDirect Flutter app

## Supabase configuration

The Flutter app loads `SUPABASE_URL` and `SUPABASE_ANON_KEY` from the root `.env` file. The project URL is prefilled there; replace `YOUR_SUPABASE_ANON_KEY` with the project's anon/publishable key from Supabase **Project Settings → API Keys**. Never use the `service_role` or secret key in a Flutter app.

The root `.env` is git-ignored and included as a Flutter asset at build time. It is configuration, not a secure secret store: the anon key is public in a client app, so keep Supabase Row Level Security enabled.

The customer login and sign-up use Supabase Auth. New sign-ups send `full_name` metadata, which the checked-in database schema's `on_auth_user_created` trigger uses to create the `profiles` row and customer role. Apply `supabase/schema.sql` to the Supabase project before testing signup. If email confirmation is enabled, the customer must confirm the email before logging in.

Run the app with:

```sh
flutter pub get
flutter run
```
