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
mkdir -m 755 "$DOC/.git" "$DOC/.well-known"
echo "junk"  > "$DOC/.git/config"
echo "acme"  > "$DOC/.well-known/x"
head -c 67108864 /dev/zero > "$DOC/big.bin"
chmod 644 "$DOC"/* "$DOC/.git/config" "$DOC/.well-known/x"

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
docker run -d --name "$NAME" -p "$PORT:8080" -p "$((PORT + 2)):8081" \
  -v "$DOC:/var/www/html:ro" "$IMAGE" >/dev/null
wait_http "http://localhost:$PORT/index.html" \
  && ok "serves a request" || fail "serves a request" "no 200 within 20s"

code() { curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT$1"; }
check "index.html 200" "$(code /index.html)" "200"
check ".php denied"    "$(code /x.php)"      "403"
check "/ serves index"     "$(code /)"              "200"
check "dotfile denied"     "$(code /.git/config)"   "403"
check ".well-known served" "$(code /.well-known/x)" "200"

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
wait_healthy() {
  i=0
  while [ "$i" -lt 25 ]; do
    h=$(docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null || echo none)
    [ "$h" = healthy ] && return 0
    [ "$h" = unhealthy ] && return 1
    i=$((i + 1)); sleep 1
  done
  return 1
}
wait_healthy "$NAME" && ok "healthcheck healthy" || fail "healthcheck healthy" "got ${h:-none}"

# The health listener is bound to loopback in the container, so publishing its port
# must not make it answer. Otherwise the endpoint is public, not internal.
check "health port not published" \
  "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://localhost:$((PORT + 2))/healthz")" "000"

# A probe every 30s would otherwise bury the access log.
docker exec "$NAME" wget -qT2 -O- "http://127.0.0.1:8081/healthz" >/dev/null 2>&1
docker logs "$NAME" 2>&1 | grep -q healthz \
  && fail "healthz stays out of access log" "probe was logged" \
  || ok "healthz stays out of access log"

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

# 9. TLS on the public port must not break the healthcheck. A probe that spoke plain
# HTTP to that port would report unhealthy forever on any TLS deployment.
openssl req -x509 -newkey rsa:2048 -keyout "$CFG/k.pem" -out "$CFG/c.pem" \
  -days 2 -nodes -subj /CN=localhost >/dev/null 2>&1
cat "$CFG/k.pem" "$CFG/c.pem" > "$CFG/tls.pem"
chmod 644 "$CFG/tls.pem"
cat > "$CFG/tls.conf" <<'CONF'
server.document-root = env.SERVER_ROOT
server.port          = env.PORT
server.modules       = ( "mod_openssl" )
$SERVER["socket"] == "127.0.0.1:" + env.HEALTH_PORT {
  server.document-root = "/usr/local/share/lighttpd/health"
}
$SERVER["socket"] == ":" + env.PORT {
  ssl.engine  = "enable"
  ssl.pemfile = "/etc/lighttpd/tls/tls.pem"
}
CONF
chmod 644 "$CFG/tls.conf"
docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" -p "$PORT:8080" -v "$DOC:/var/www/html:ro" \
  -v "$CFG/tls.conf:/etc/lighttpd/lighttpd.conf:ro" \
  -v "$CFG/tls.pem:/etc/lighttpd/tls/tls.pem:ro" "$IMAGE" >/dev/null
wait_healthy "$NAME" && ok "healthy behind TLS" || fail "healthy behind TLS" "got ${h:-none}"

# 10. A config that drops the health listener must still report healthy, so replacing
# the bundled config does not silently strand the container in unhealthy.
cat > "$CFG/bare.conf" <<'CONF'
server.document-root = env.SERVER_ROOT
server.port          = env.PORT
CONF
chmod 644 "$CFG/bare.conf"
docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" -p "$PORT:8080" -v "$DOC:/var/www/html:ro" \
  -v "$CFG/bare.conf:/etc/lighttpd/lighttpd.conf:ro" "$IMAGE" >/dev/null
wait_healthy "$NAME" && ok "healthy without health listener" \
  || fail "healthy without health listener" "got ${h:-none}"

# 11. A health listener that answers wrongly must fail the probe, not fall back to the
# bare connect. Here it serves the site root, which has no /healthz.
cat > "$CFG/broken.conf" <<'CONF'
server.document-root = env.SERVER_ROOT
server.port          = env.PORT
$SERVER["socket"] == "127.0.0.1:" + env.HEALTH_PORT { }
CONF
chmod 644 "$CFG/broken.conf"
docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" -p "$PORT:8080" -v "$DOC:/var/www/html:ro" \
  -v "$CFG/broken.conf:/etc/lighttpd/lighttpd.conf:ro" "$IMAGE" >/dev/null
if wait_http "http://localhost:$PORT/index.html"; then
  docker exec "$NAME" sh -c "$(docker inspect -f '{{index .Config.Healthcheck.Test 1}}' "$NAME")" >/dev/null 2>&1 \
    && fail "broken health listener fails probe" "probe passed" \
    || ok "broken health listener fails probe"
else
  fail "broken health listener" "container did not serve"
fi

# 12. The cache directory must be writable by uid 1000 on a fresh named volume.
docker run --rm -v "$NAME-v:/var/cache/lighttpd/compress" "$IMAGE" \
  touch /var/cache/lighttpd/compress/x 2>/dev/null \
  && ok "cache volume writable" || fail "cache volume writable" "uid 1000 cannot write"
docker volume rm -f "$NAME-v" >/dev/null 2>&1

# 13. A stop must let a download in flight finish. SIGTERM would cut it off.
docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" -p "$PORT:8080" -v "$DOC:/var/www/html:ro" "$IMAGE" >/dev/null
if wait_http "http://localhost:$PORT/index.html"; then
  curl -s --limit-rate 16M -o /dev/null -w '%{size_download}' \
    "http://localhost:$PORT/big.bin" > "$CFG/dl" &
  sleep 1
  docker stop "$NAME" >/dev/null
  wait
  check "stop finishes download in flight" "$(cat "$CFG/dl")" "67108864"
else
  fail "graceful stop" "container did not serve"
fi

[ "$FAILED" -eq 0 ] && echo "PASS" || { echo "FAILED"; docker logs "$NAME" 2>&1 | tail -20; }
exit "$FAILED"
