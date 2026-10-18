# Site operations

The site serves the landing page and caches public GitHub release and repository
metadata in memory. It has no database, subscriber collection, or export service.
Both `/api/subscribe` and `/api/export.csv` return `404`, including requests with
old export credentials.

## Runtime configuration

Run the server with Node 24 from `site/` using `npm start`. `PORT` defaults to
`3000`. Railway uses `site/` as the service root, `node server.js` as the start
command, and `/healthz` as its health check. The existing GitHub autodeploy watches
`site/**` on `main` and waits for the `Site` workflow.

Installation controls remain gated unless `VISHOT_INSTALL_READY=true` and public
release and tap metadata pass validation. Repository and release metadata use
public requests without credentials. The server requires no persistent volume,
export token, or database migrations.

## Retire the old storage configuration

Existing subscriber data remains an archive outside the site's runtime. This
change doesn't open, modify, or delete database files or the Railway volume.
The server ignores `EXPORT_TOKEN` and `RAILWAY_VOLUME_MOUNT_PATH` if they're
still configured.

To finish the hosting cleanup, archive the existing subscriber database with a
consistent SQLite backup, then remove the obsolete `EXPORT_TOKEN` variable and
detach the `/data` volume from the Railway service. Preserve the archive; volume
or subscriber-data deletion is a separate decision. No export endpoint remains
after this version is deployed.

## Public serving and checks

The server answers `/healthz` with `200` and `ok`. Static serving accepts only
`GET` and `HEAD` for the page, browser scripts, styles, images, and bundled fonts.
It doesn't expose server source, package files, archived database files, or
arbitrary filesystem paths. Requests to `www` redirect to the canonical bare host.

Run `npm test` from `site/` to check static serving, retired routes, installation
gating, and metadata validation. Tests also verify that obsolete storage settings
don't prevent startup and archived files remain byte-for-byte unchanged.
