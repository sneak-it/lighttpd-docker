# lighttpd-docker

The goal of this container is to have automated releases that stay up to date with Alpine and lighttpd. Since there is no official lighttpd Docker image, this was created to fill that gap.

Tags: `latest`, `1`, `1.4`, `1.4.85`, and a dated `1.4.85-YYYYMMDD` that never moves.

## Running it

Use [`docker-compose.yml`](docker-compose.yml). Copy it, drop your site in `./site`, edit
[`lighttpd.conf`](lighttpd.conf), and `docker compose up -d`.

    docker compose up -d

For a quick look without a config of your own:

    docker run -p 8080:8080 -v ./site:/var/www/html:ro ghcr.io/sneak-it/lighttpd-docker

## Configuration

The image ships a working [`lighttpd.conf`](lighttpd.conf). To serve static files you do not
have to change anything.

**To add settings,** put `.conf` files in `/etc/lighttpd/conf.d`. The bundled config loads
them. Use `server.modules += ( ... )` so you do not have to repeat the whole module list. An
empty or missing directory is fine.

**To start from scratch,** mount your own file over `/etc/lighttpd/lighttpd.conf`. Keep these
two lines, or you lose mime types and access logs:

    include "/etc/lighttpd/mime.conf"
    accesslog.filename = env.ACCESS_LOG

Check any config before you restart, because a bad one leaves the server down. No output means
it is fine:

    docker compose run --rm lighttpd /usr/local/sbin/lighttpd -tt -f /etc/lighttpd/lighttpd.conf

### Environment variables

| Variable | Required | Default | What it sets |
|---|---|---|---|
| `PORT` | No | `8080` | Listen port inside the container |
| `SERVER_ROOT` | No | `/var/www/html` | Document root |
| `SERVER_NAME` | No | `localhost` | `server.name` |
| `ACCESS_LOG` | No | `/dev/stderr` | Access log path. Set `/dev/null` to silence |

The bundled config reads all four, so do not remove one. Unsetting any gives
`Undefined env variable`, and an empty `PORT` or `SERVER_ROOT` also fails to start. This only
applies while you use the bundled config; your own config can ignore them.

On a busy server, `ACCESS_LOG=/dev/null` still builds each log line before throwing it away.
To skip that work, use your own config without `mod_accesslog`.

Directives and modules: [config syntax](https://wiki.lighttpd.net/Docs_Configuration),
[core options](https://wiki.lighttpd.net/Docs_ConfigurationOptions),
[module index](https://wiki.lighttpd.net/Docs).

## What is in it

**Included:** pcre2, zlib + libdeflate (gzip), brotli, zstd, OpenSSL (TLS and HTTP/2), Lua
(`mod_magnet`), libmaxminddb (`mod_maxminddb`), and upstream's 1389-entry mime map.

OpenSSL is in because browsers only speak HTTP/2 over TLS and 1.4.83 disabled `h2c` upgrade by
default, so a TLS-less build is HTTP/1.1-only for every browser. It costs nothing in CVE terms:
`alpine:3` already ships `libssl3` and `libcrypto3`, and every finding in this image comes from
them whether lighttpd links them or not.

**Excluded:** every database and directory backend (mysql, pgsql, dbi, ldap, sasl, krb5, pam),
since `mod_auth` already does htpasswd and htdigest without them. Also bzip2, which no HTTP
client negotiates; `fam`, redundant with inotify; `libunwind`, `xattr`, and every non-OpenSSL
TLS backend.

`mod_webdav` builds **without** `with_webdav_props`, so it has no properties and no locking,
which is broken for macOS Finder and Windows clients. Fork and add libxml2 and sqlite3 if you
need it.

## Pitfalls

- **`/dev/stdout` silently discards logs.** lighttpd points its own stdout at `/dev/null`
  (`/proc/1/fd/1 -> /dev/null`), so a log aimed there is lost with no error. Use `/dev/stderr`.
- **A directive whose module is not loaded is silently ignored**, logged only as
  `unknown config-key` at startup. `index-file.names` needs `mod_indexfile`, listed before
  `mod_cgi`. `server.dir-listing`, `ssl.cipher-list` and `ssl.honor-cipher-order` were removed
  outright, so a config from an older lighttpd loses those settings without saying so.
- **`url.access-deny` is a suffix match, not a path match.** `/.ht` does not block
  `.htaccess`, because the URL does not end in `/.ht`. Use the full suffix.
- **Runs as uid 1000.** Mounted files must be readable by it and directories traversable; a
  0700 directory produces a confusing 403.
- **`mod_deflate` needs a writable `deflate.cache`** to compress each object once, which means
  a writable volume on an otherwise read-only container. Weigh it against pre-compressing.
- **The healthcheck accepts any HTTP status**, so an empty document root still reports healthy.
  It checks that lighttpd answers, not that your content exists.

## Build

Source tarballs are GPG-verified against a key committed to this repo and pinned by fingerprint
in the Dockerfile. Releases ship no checksum file, so the signature is the only integrity check.

    Glenn Strauss (lighttpd) <gstrauss@gluelogic.com>
    649D 0DD7 67FF 2062 02A7  6C51 58F1 4A78 6FE1 98C8   (expires 2030-05-12)

**The fingerprint is the trust anchor, not the key file.** The committed key is a cache; swap it
and `SIGNING_FPR` stops matching and the build fails. Pinning the fingerprint already makes
keyserver trust irrelevant, so fetching at build time would add a flaky dependency and buy
nothing.

The build also fails if the pinned key has **expired**, because `gpg --verify` exits 0 on a good
signature from an expired key. Without that check, verification would quietly degrade the day
upstream rotates. Rotate the key file and `SIGNING_FPR` together.

Meson option types are inconsistent upstream: `with_pcre2`, `with_lua` and `with_openssl` are
boolean, the rest are features (`enabled`/`disabled`/`auto`).

    docker build --pull --build-arg LIGHTTPD_VERSION=1.4.85 -t lighttpd-docker .

## Updates

The weekly workflow resolves the newest upstream tarball and pushes. Upstream has no release
feed, so the schedule is the release trigger; use **Run workflow** to pull a fix in sooner.
Dependabot keeps the actions current.

The base is the floating `alpine:3`, so branch bumps arrive on their own and no pin goes EOL.
A branch jump can rename a build dependency; the build then fails loudly and the dated tags
stay pullable.

Rebuilds produce a new digest even with no upstream change, so digest-watching updaters
(Watchtower, Dockhand) redeploy on every rebuild.
