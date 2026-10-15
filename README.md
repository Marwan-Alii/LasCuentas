# Hisab — shared expenses for hostel groups (PKR)

Native Android (Kotlin + Jetpack Compose) client, Supabase (Postgres + Auth + RLS + Edge Functions) backend.
Hisab **records** payments; it never moves money.

## Honest status

| Part | State |
|---|---|
| `core/` accounting engine (allocation, rounding, contributions, debts, repayments, reversals, revisions, settlement suggestions, reminder rules) | **Built and tested** — 25 unit tests pass |
| `supabase/migrations` (schema, server-side validation, RLS, audit, reminders) | **Built and tested** against real PostgreSQL 16 with a local Supabase stand-in — 144 assertions pass |
| `supabase/functions` (email + scheduler workers, Deno/TypeScript) | Written, **not run** (no Deno / no network to providers) |
| `app/` Android client | Written, **never compiled** (Google's Maven repo was unreachable where this was authored). Expect small compile fixes on first build, and dependency versions may need bumping |
| Real Supabase project, email provider, pg_cron | **Not set up** — needs your accounts. Nothing here claims otherwise |

### Not implemented (be aware)
Push notifications (FCM), CSV/PDF export, offline cache/queue (the app needs a connection; it keeps the last loaded data on screen when a refresh fails), receipt/screenshot upload and profile pictures (the DB columns exist), an *edit-expense* screen (the server function `revise_expense` exists and is tested), UI for removing members / voiding / reversing payments / forgiving debts (server functions exist and are tested), WhatsApp-number *verification* (Supabase phone verification needs an SMS provider that may cost money — so guests are claimable by verified **email** out of the box), and the Gradle wrapper (see below).

### Where server and client intentionally differ
* The server validates and **derives debts itself**; the app shows server results. Tie-breaks between equal debtors may match differently than the app's preview — the server is the source of truth.
* Server `revise_expense` refuses to change **amounts** once any confirmed payment or adjustment exists (use *reverse payment* or *forgive part of a debt*); the Kotlin engine can additionally preview/acknowledge an over-payment. Stricter on purpose: history is never rewritten.
* There are no "draft" expenses, so there is no permanent deletion. Expenses are **voided** (allowed only when no confirmed payments remain).

## Repository layout
```
core/                     pure Kotlin/JVM accounting engine + tests (src/test)
app/                      Android app (Compose, Material 3)
supabase/migrations/      0001 schema · 0002 identity/groups · 0003 expenses · 0004 repayments+reminders · 0005 RLS+grants
supabase/functions/       process-reminders, send-notifications, _shared
supabase/cron.sql         pg_cron schedule (run once)
supabase/tests/           00 local stub (NOT for Supabase) · 10_suite.sql
supabase/seed_dev.sql     development-only helper
run-core-tests.sh         sandbox test runner (see "Run the tests")
```

## 1. Create the backend (no credit card should be required — verify at signup)
1. Create a free project at supabase.com. Note the **Project URL**, **anon key** (public) and keep the **service_role key private**.
2. Auth → Providers → Email: keep **Confirm email ON** (verified email is what makes guest claiming and lookup safe).
3. SQL editor: run `supabase/migrations/0001…0005` **in order**. (Or `supabase link` + `supabase db push` with the CLI.) Do **not** run anything in `supabase/tests/00_local_supabase_stub.sql` there.
4. Confirm the app role cannot write directly: Database → Roles shows `authenticated` with only the grants from `0005`.

## 2. Reminders and email (needs accounts you create)
1. Pick an email provider with a free plan and verify a sender address (Brevo: single sender; Resend: free tier may only send to your own address until you verify a domain — check current terms). Without any provider the app still works: in-app notifications are created, and email is recorded as **skipped**, never "sent".
2. Install the Supabase CLI, then:
   ```
   cp .env.example supabase/.env      # edit values; file is git-ignored
   supabase secrets set --env-file supabase/.env
   supabase functions deploy process-reminders --no-verify-jwt
   supabase functions deploy send-notifications --no-verify-jwt
   ```
3. Dashboard → Database → Extensions: enable `pg_cron` and `pg_net`. Edit the two placeholders in `supabase/cron.sql` (project ref and the same `CRON_SECRET`) and run it once. Reminders then run every 10 minutes on the server, independent of any phone.
4. Test by hand: `curl -X POST -H "x-cron-secret: YOUR_SECRET" https://YOUR-REF.supabase.co/functions/v1/process-reminders` → JSON with `claimed`, `emailsSent`, `emailConfigured`.

How duplicates are prevented: the database hands out each reminder once (`reminder_attempts` has a unique `(debt, sequence, channel)` and the claim uses `FOR UPDATE SKIP LOCKED`), and re-checks balance, opt-out, pause, expense status and maximum count at claim time.

## 3. Build the Android app
Requirements: Android Studio (free), JDK 17, an Android phone with USB debugging or an emulator.
1. Open the repository folder in Android Studio. It will download the Android SDK and Gradle.
2. **Gradle wrapper:** this repo does not include `gradlew` (couldn't be generated offline). Android Studio works without it; for the command line run `gradle wrapper --gradle-version 8.10.2` once.
3. `cp local.properties.example local.properties` and fill `sdk.dir`, `SUPABASE_URL`, `SUPABASE_ANON_KEY` (anon key only — never the service-role key).
4. Debug APK: Build → Build APK(s), or `./gradlew :app:assembleDebug` → `app/build/outputs/apk/debug/app-debug.apk`.
5. Install: copy the APK to the phone, open it, allow "install unknown apps" for your file manager/browser. Or `adb install -r app-debug.apk`.
6. Release APK: create a keystore (`keytool -genkeypair -v -keystore hisab-release.jks -alias hisab -keyalg RSA -keysize 2048 -validity 10000`), add the four `RELEASE_*` lines to `local.properties`, run `./gradlew :app:assembleRelease`. Keep the keystore out of git.

## Run the tests
* **Normal machine:** `./gradlew :core:test`
* **Database suite:** start any PostgreSQL 15+, create an empty database, run in order: `supabase/tests/00_local_supabase_stub.sql`, migrations `0001…0005`, then `supabase/tests/10_suite.sql` (`psql -v ON_ERROR_STOP=1 -f …`). Every check prints `PASS`; any failure aborts.
* The stub only imitates `auth.users`, `auth.uid()` and the three roles so the real migrations can run outside Supabase.

What the suites cover: equal/item-level/quantity/proportional/custom allocation and rounding; multiple contributors; partial payments needing recipient confirmation; oldest-first allocation; netting suggestions; reversals as compensating rows; edit conflicts (stale version); append-only audit; reminder eligibility, pause, maximum, opt-out, settled/partial, duplicate scheduler runs; guest claiming (unverified/other/creator all refused, history preserved, single claim); RLS isolation between users/groups, hidden contact columns, no direct writes, forged audit rows refused, payment-method privacy, non-enumerable lookup.
**Not covered:** true concurrent-transaction races (claims, confirmations), load, and the Android/Edge code.

## Free-tier cautions (verify current terms yourself)
Free Supabase projects may be paused after inactivity and have database/egress/Edge-Function limits; free email plans have daily caps and sender-verification rules. When a quota is hit, requests fail with an error the app shows; nothing here enables paid upgrades.

## Troubleshooting
* *App says no Supabase URL/key* → `local.properties` missing or Gradle not re-synced.
* *"permission denied for table …"* → a migration (especially `0005`) wasn't applied; rerun in order.
* *Can't find a friend by email* → they must be **verified** and have turned on "discoverable". The app deliberately cannot tell you whether an account exists.
* *"Verify the email … before claiming"* → the account's email must match the guest's email and be confirmed.
* *No reminder emails* → `process-reminders` response shows `emailConfigured:false`, or the cron job isn't scheduled (`select * from cron.job;`).
* *Gradle can't resolve a dependency version* → bump to the nearest stable release (versions were not resolvable at authoring time).
