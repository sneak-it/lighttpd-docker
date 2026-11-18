# syntax=docker/dockerfile:1
ARG LIGHTTPD_VERSION

FROM alpine:3 AS build
ARG LIGHTTPD_VERSION
ARG SRC=https://download.lighttpd.net/lighttpd
# Upstream checksums come from the same server as the tarball, so only the signature adds trust.
ARG SIGNING_FPR=649D0DD767FF206202A76C5158F14A786FE198C8
RUN apk add --no-cache build-base meson ninja-build pkgconf ca-certificates curl gnupg xz tar \
      pcre2-dev zlib-dev brotli-dev zstd-dev libdeflate-dev libmaxminddb-dev openssl-dev lua5.5-dev
COPY lighttpd-signing-key.asc /tmp/
WORKDIR /tmp/src
RUN url="$SRC/releases-${LIGHTTPD_VERSION%.*}.x/lighttpd-$LIGHTTPD_VERSION.tar.xz" \
 && curl -fsSLO "$url" \
 && curl -fsSLO "$url.asc" \
 && export GNUPGHOME=$(mktemp -d) \
 && gpg --batch --import /tmp/lighttpd-signing-key.asc \
 && { gpg --batch --status-fd 1 --verify "lighttpd-$LIGHTTPD_VERSION.tar.xz.asc" \
        "lighttpd-$LIGHTTPD_VERSION.tar.xz" > /tmp/sig.txt || true; } \
 && { grep -q '^\[GNUPG:\] GOODSIG ' /tmp/sig.txt \
   && grep -q "^\[GNUPG:\] VALIDSIG .* $SIGNING_FPR\$" /tmp/sig.txt \
   || { echo "no good signature from $SIGNING_FPR:"; cat /tmp/sig.txt; exit 1; }; } \
 && tar xf "lighttpd-$LIGHTTPD_VERSION.tar.xz"
# Option types are inconsistent upstream: pcre2/lua/openssl are boolean, the rest are features.
# No db, ldap, kerberos, webdav or bzip2 backends: large dependency chains or no HTTP client wants them.
RUN cd "lighttpd-$LIGHTTPD_VERSION" \
 && meson setup build --buildtype=release --prefix=/usr/local \
      -Dwith_pcre2=true -Dwith_lua=true -Dwith_openssl=true \
      -Dwith_zlib=enabled -Dwith_brotli=enabled -Dwith_zstd=enabled \
      -Dwith_libdeflate=enabled -Dwith_maxminddb=enabled \
 && ninja -C build \
 && DESTDIR=/out ninja -C build install \
 && cp doc/config/conf.d/mime.conf /out/mime.conf

FROM alpine:3
# apk add leaves installed packages alone, so base-image packages need the upgrade.
RUN apk upgrade --no-cache \
 && apk add --no-cache pcre2 zlib brotli-libs zstd-libs libdeflate libmaxminddb \
      libssl3 libcrypto3 lua5.5-libs \
 && mkdir -p /var/www/html /etc/lighttpd/conf.d /var/cache/lighttpd/compress \
 && chown 1000:1000 /var/cache/lighttpd/compress
COPY --from=build /out/usr/local /usr/local
COPY --from=build /out/mime.conf /etc/lighttpd/mime.conf
COPY lighttpd.conf /etc/lighttpd/lighttpd.conf
RUN mkdir -p /usr/local/share/lighttpd/health \
 && echo ok > /usr/local/share/lighttpd/health/healthz \
 && /usr/local/sbin/lighttpd -V
ENV PORT=8080 SERVER_ROOT=/var/www/html SERVER_NAME=localhost ACCESS_LOG=/dev/stderr \
    HEALTH_PORT=8081
USER 1000:1000
EXPOSE 8080
# SIGINT is lighttpd's graceful shutdown; SIGTERM exits at once and cuts off responses.
STOPSIGNAL SIGINT
# The internal listener proves lighttpd reads a file off disk and returns it. The bare
# connect applies only when a mounted config drops the listener, never when it fails.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s \
  CMD if nc -w2 -z 127.0.0.1 "$HEALTH_PORT"; then \
        wget -qT2 -O- "http://127.0.0.1:$HEALTH_PORT/healthz" | grep -qx ok; \
      else nc -w2 -z 127.0.0.1 "$PORT"; fi
CMD ["/usr/local/sbin/lighttpd", "-D", "-f", "/etc/lighttpd/lighttpd.conf"]
