# Site operations and retained subscriber export

The site serves the landing page and retains authenticated access to existing
subscriber records. Public signup is retired: `/api/subscribe` returns `404`
for all methods and doesn't add records or update existing answers or sources.
The page no longer collects email addresses, usage answers, or referral labels.

## Storage

Keep the existing Railway volume mounted at `/data`. The server opens
`waitlist.db` under `RAILWAY_VOLUME_MOUNT_PATH`; without that variable, it uses
`site/waitlist.db`. Signup retirement doesn't delete the database, subscriber
rows, or the volume. A separate retention decision is required for deletion.

The server keeps the existing `subscribers` schema and adds missing nullable
`use_case` and `source` columns for older databases. Existing email addresses,
timestamps, answers, and sources remain available across restarts and deploys.
SQLite uses WAL mode, and the server closes the database on `SIGTERM` after
closing HTTP connections so the WAL is checkpointed.

## Export existing records

Set a nonempty `EXPORT_TOKEN` on the server and use the same token in the
`Authorization: Bearer` header. Keep this credential out of browser code and
public links. With the token available in your shell, download the CSV:

```sh
curl --fail --show-error \
  --header "Authorization: Bearer $EXPORT_TOKEN" \
  https://vishot.dev/api/export.csv \
  --output subscribers.csv
```

Only `GET /api/export.csv` exports records. An unset or empty server token,
missing or incorrect credentials, and other methods return `404`. Export
responses use `Cache-Control: no-store` and contain
`email,created_at,use_case,source`, ordered by creation time. Optional values
can be empty. CSV fields escape commas and quotes; sources starting with
`=`, `+`, `-`, or `@` gain a leading apostrophe to prevent spreadsheet formulas.
The export doesn't modify stored values.

## Public serving and checks

The server continues to answer `/healthz` with `200` and `ok`. Static serving
accepts only `GET` and `HEAD` for `/`, `/main.js`, `/style.css`, `/favicon.svg`,
`/og.png`, and the bundled files under `/fonts/`. It doesn't expose server
source, package files, database files, WAL files, or arbitrary filesystem paths,
even when you supply export credentials. Requests to `www` redirect to the
canonical bare host.

Run the served-site tests with Node 24 or later from `site/`:

```sh
npm test
```

Tests create temporary volume directories, seed synthetic subscriber records,
and verify preservation through authenticated HTTP exports. Cleanup removes
only those temporary fixtures, never the local or deployed subscriber database.
