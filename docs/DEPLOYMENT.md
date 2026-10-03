# Deployment

Production today:

| Piece | Where |
|---|---|
| Web app (PWA) | GitHub Pages, deployed by `.github/workflows/ci-deploy.yml` on every push to `main` |
| Database, auth, edge functions, cron | Supabase project `hisab-kitab` (ref `qevxdlmsgapvccidjtkx`, region ap-south-1) |

## 1. Supabase project (one-time, already done for production)

```bash
supabase login
supabase link --project-ref <project-ref>
supabase db push                      # applies supabase/migrations in order
supabase functions deploy sync-orders --no-verify-jwt
supabase functions deploy sync-tracking --no-verify-jwt
supabase functions deploy integrations
```

`sync-orders` / `sync-tracking` skip the gateway JWT check because pg_cron calls them with the Vault cron secret; both functions authenticate every request themselves (user JWT + finance role, or the cron secret).

Then, in the SQL editor, tell pg_cron where the functions live (once per project):

```sql
select vault.create_secret('https://<project-ref>.supabase.co', 'hk_project_url', 'Project URL for pg_cron');
-- hk_cron_secret is generated automatically by migration 20261003100200
```

### Auth settings (Supabase dashboard → Authentication → URL Configuration)

* **Site URL**: `https://<github-user>.github.io/<repo>/`
* **Redirect URLs**: add the same URL and `http://localhost:8080/**`

These make email-confirmation and password-reset links open the app. Optional hardening: Authentication → Providers → Email → keep "Confirm email" on; set minimum password length ≥ 10.

The **first person to sign up becomes admin**. Everyone after that is `pending` until an admin assigns a role in Settings → Users.

## 2. GitHub repository

1. Repository → **Settings → Pages** → Source: **GitHub Actions**.
   *(Pages on a private repository requires GitHub Pro/Team/Enterprise; on the free plan make the repository public — no secrets are in the code.)*
2. Repository → **Settings → Secrets and variables → Actions → Variables** (these are public values, so *Variables*, not Secrets):
   * `SUPABASE_URL` = `https://<project-ref>.supabase.co`
   * `SUPABASE_PUBLISHABLE_KEY` = `sb_publishable_…` (Supabase → Project Settings → API Keys)
3. Push to `main`. The workflow runs `flutter analyze`, `flutter test`, Deno checks/tests, builds with `--base-href /<repo>/` and deploys.

The live URL is `https://<github-user>.github.io/<repo>/`.

## 3. Integrations (in the app, admin)

Settings → Integrations → **Configure** each provider → **Test connection** → **Test & save**:

* **Shopify**: store domain `your-store.myshopify.com` + an Admin API access token (custom app with `read_orders`, `read_products`, `read_inventory`; `read_customers` optional for names/phones), or a Dev Dashboard app's client ID + secret.
* **Triple Whale** (ad spend): store domain + API key with scope `summary-page:read` (Triple Whale → Settings → API Keys). Then Settings → Sync → *Backfill ad spend*. Remove any manually entered ad-spend expenses for the same days to avoid double counting.
* **PostEx**: API token · **BlueEx**: API username + password · **Tranzo**: API token · **XPS**: auth key · **M&P**: no key needed (public tracking).

Then on the dashboard press **Sync now**, and use Settings → Sync → **Backfill older orders** to import history (e.g. from the start of the year).

## Environments

| Env | How |
|---|---|
| development | `app/.env` with `APP_ENV=development`, `flutter run -d chrome --dart-define-from-file=.env` against a dev Supabase project (or `supabase start` locally) |
| staging | Create a second Supabase project, apply the same migrations, and build with its URL/key and `APP_ENV=staging` (e.g. a second Pages repo or `flutter build web` to any static host) |
| production | GitHub Actions variables → GitHub Pages |

Integration secrets are per Supabase project, so staging and production never share courier/Shopify credentials.

## Native apps (optional)

The PWA installs on iOS (Safari → Share → Add to Home Screen) and Android (Chrome → Install app). Native builds are also possible from the same code:

```bash
cd app
flutter build apk --release --dart-define-from-file=.env      # Android (needs Android SDK)
flutter build ipa --release --dart-define-from-file=.env      # iOS (needs macOS + Xcode)
```

## Rollback

* Web: re-run the deploy workflow on a previous commit (Actions → CI & Deploy → Run workflow), or `git revert` and push.
* Database: migrations are forward-only; write a new migration to undo a change. Take a backup first (Supabase → Database → Backups).
