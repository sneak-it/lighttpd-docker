#!/bin/sh
# Smoke test an image: asserts it starts, serves, and has the intended feature set.
# Usage: test.sh IMAGE [VERSION]
set -eu
IMAGE=${1:?usage: test.sh IMAGE [VERSION]}
WANT=${2:-}
NAME=lighttpd-smoke-$$
PORT=18099
DOC=$(mktemp -d)
CFG=$(mktemp -d)
chmod 755 "$DOC" "$CFG"   # mktemp -d is 0700 and the server runs as uid 1000
FAILED=0

cleanup() {
  docker rm -f "$NAME" "$NAME-d" >/dev/null 2>&1 || true
  rm -rf "$DOC" "$CFG"
}
trap cleanup EXIT

# The run log is ephemeral; the step summary is what stays readable on the run page.
note()  { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"; return 0; }
ok()    { printf 'ok   %s\n' "$1"; note "- \`ok\` $1"; }
fail()  { printf 'FAIL %s: %s\n' "$1" "$2"; note "- **FAIL** $1: $2"; FAILED=1; }
check() { [ "$2" = "$3" ] && ok "$1" || fail "$1" "want $3, got $2"; }
wait_http() {
  i=0
  while [ "$i" -lt 20 ]; do
    curl -fsS -o /dev/null "$1" 2>/dev/null && return 0
    i=$((i + 1)); sleep 1
  done
  return 1
}

note "## \`$IMAGE\`"

echo "hello" > "$DOC/index.html"
echo "junk"  > "$DOC/x.php"
printf 'body{color:red}\n%.0s' $(seq 400) > "$DOC/big.css"
chmod 644 "$DOC"/*

# 1. The binary runs. Catches a broken build or a missing shared library.
if V=$(docker run --rm "$IMAGE" /usr/local/sbin/lighttpd -V 2>&1); then
  ok "binary executes"
  ver=$(echo "$V" | head -1 | sed 's|.*lighttpd/\([0-9.]*\).*|\1|')
  [ -z "$WANT" ] && ok "version $ver" || check "version" "$ver" "$WANT"
else
  fail "binary executes" "lighttpd -V exited non-zero"
  exit 1
fi

# 2. Feature contract. A flag that silently stopped applying is otherwise invisible.
for f in "zlib" "brotli" "zstd" "OpenSSL" "PCRE" "LUA" "inotify"; do
  echo "$V" | grep -q "^	+ $f support" && ok "built: $f" || fail "built: $f" "not enabled"
done
for f in "bzip2" "MySQL" "PgSQL" "DBI" "LDAP" "Kerberos" "PAM" "xml" "SQLite"; do
  echo "$V" | grep -q "^	- $f support" && ok "excluded: $f" || fail "excluded: $f" "unexpectedly enabled"
done
for m in mod_deflate mod_openssl mod_magnet mod_maxminddb mod_auth mod_h2; do
  docker run --rm "$IMAGE" test -f "/usr/local/lib/lighttpd/$m.so" \
    && ok "module: $m" || fail "module: $m" "not built"
done

# 3. Bundled config parses and passes a full startup test.
docker run --rm "$IMAGE" /usr/local/sbin/lighttpd -tt -f /etc/lighttpd/lighttpd.conf >/dev/null 2>&1 \
  && ok "config startup test" || fail "config startup test" "lighttpd -tt failed"

# 4. It actually serves. This is the failure a successful build cannot catch.
docker run -d --name "$NAME" -p "$PORT:8080" -v "$DOC:/var/www/html:ro" "$IMAGE" >/dev/null
wait_http "http://localhost:$PORT/index.html" \
  && ok "serves a request" || fail "serves a request" "no 200 within 20s"

code() { curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT$1"; }
check "index.html 200" "$(code /index.html)" "200"
check ".php denied"    "$(code /x.php)"      "403"

# Without the mime map, CSS goes out as application/octet-stream.
check "mime map applied" \
  "$(curl -sI "http://localhost:$PORT/big.css" | grep -i '^content-type' | tr -d '\r' | cut -d' ' -f2)" \
  "text/css;charset=utf-8"

# lighttpd points its own stdout at /dev/null, so a log aimed there vanishes silently.
docker logs "$NAME" 2>&1 | grep -q 'GET /index.html' \
  && ok "access log reaches docker logs" || fail "access log reaches docker logs" "no request logged"

check "container running" "$(docker inspect -f '{{.State.Running}}' "$NAME")" "true"
check "runs as uid 1000" "$(docker exec "$NAME" id -u 2>/dev/null)" "1000"

# Healthcheck must pass against a document root with no index, not just a populated one.
i=0
while [ "$i" -lt 20 ]; do
  h=$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo none)
  [ "$h" = healthy ] && break
  i=$((i + 1)); sleep 1
done
check "healthcheck healthy" "${h:-none}" "healthy"

# 5. Compression actually works, which is the point of the zlib/brotli/zstd flags.
cat > "$CFG/deflate.conf" <<'CONF'
server.document-root = env.SERVER_ROOT
server.port          = env.PORT
server.modules       = ( "mod_deflate" )
include "/etc/lighttpd/mime.conf"
deflate.mimetypes         = ( "text/" )
deflate.allowed-encodings = ( "br", "zstd", "gzip" )
CONF
chmod 644 "$CFG/deflate.conf"
docker run -d --name "$NAME-d" -p "$((PORT + 1)):8080" \
  -v "$CFG/deflate.conf:/etc/lighttpd/lighttpd.conf:ro" \
  -v "$DOC:/var/www/html:ro" "$IMAGE" >/dev/null
if wait_http "http://localhost:$((PORT + 1))/big.css"; then
  for e in gzip br zstd; do
    got=$(curl -s -H "Accept-Encoding: $e" -o /dev/null -D- "http://localhost:$((PORT + 1))/big.css" \
          | grep -i '^content-encoding' | tr -d '\r' | cut -d' ' -f2)
    check "encoding: $e" "$got" "$e"
  done
else
  fail "deflate container" "did not come up"
fi

# 6. Access logging must be silenceable, since it is noisy on a busy server.
docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" -e ACCESS_LOG=/dev/null -p "$PORT:8080" \
  -v "$DOC:/var/www/html:ro" "$IMAGE" >/dev/null
if wait_http "http://localhost:$PORT/index.html"; then
  docker logs "$NAME" 2>&1 | grep -q 'GET /index.html' \
    && fail "ACCESS_LOG=/dev/null" "still logging" || ok "ACCESS_LOG=/dev/null silences"
else
  fail "ACCESS_LOG=/dev/null" "container did not serve"
fi

# 7. conf.d drop-ins must extend the default config without replacing it.
mkdir -p "$CFG/conf.d"
chmod 755 "$CFG/conf.d"
printf 'server.modules += ( "mod_setenv" )\nsetenv.add-response-header = ( "X-Dropin" => "yes" )\n' \
  > "$CFG/conf.d/10-test.conf"
chmod 644 "$CFG/conf.d/10-test.conf"
docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" -p "$PORT:8080" -v "$DOC:/var/www/html:ro" \
  -v "$CFG/conf.d:/etc/lighttpd/conf.d:ro" "$IMAGE" >/dev/null
if wait_http "http://localhost:$PORT/index.html"; then
  check "conf.d drop-in applied" \
    "$(curl -sI "http://localhost:$PORT/index.html" | grep -i '^x-dropin' | tr -d '\r' | cut -d' ' -f2)" \
    "yes"
else
  fail "conf.d drop-in" "container did not serve"
fi

# 8. PORT is the documented knob, and env.PORT in the config is what makes it work.
docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" -e PORT=9000 -p "$PORT:9000" -v "$DOC:/var/www/html:ro" "$IMAGE" >/dev/null
wait_http "http://localhost:$PORT/index.html" \
  && ok "PORT override" || fail "PORT override" "PORT=9000 did not take effect"

[ "$FAILED" -eq 0 ] && echo "PASS" || { echo "FAILED"; docker logs "$NAME" 2>&1 | tail -20; }
exit "$FAILED"
