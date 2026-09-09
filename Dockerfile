# syntax=docker/dockerfile:1
ARG LIGHTTPD_VERSION

FROM alpine:3 AS build
ARG LIGHTTPD_VERSION
ARG SRC=https://download.lighttpd.net/lighttpd/releases-1.4.x
# Releases ship no checksum file, so the signature is the only integrity check.
ARG SIGNING_FPR=649D0DD767FF206202A76C5158F14A786FE198C8
RUN apk add --no-cache build-base meson ninja-build pkgconf ca-certificates curl gnupg xz tar \
      pcre2-dev zlib-dev brotli-dev zstd-dev libdeflate-dev libmaxminddb-dev openssl-dev lua5.5-dev
COPY lighttpd-signing-key.asc /tmp/
WORKDIR /tmp/src
RUN curl -fsSLO "$SRC/lighttpd-$LIGHTTPD_VERSION.tar.xz" \
 && curl -fsSLO "$SRC/lighttpd-$LIGHTTPD_VERSION.tar.xz.asc" \
 && export GNUPGHOME=$(mktemp -d) \
 && gpg --batch --import /tmp/lighttpd-signing-key.asc \
 && gpg --batch --list-keys --with-colons "$SIGNING_FPR" > /tmp/key.txt \
 && awk -F: '/^pub/ && $2=="e" { print "pinned signing key has expired"; exit 1 }' /tmp/key.txt \
 && gpg --batch --verify "lighttpd-$LIGHTTPD_VERSION.tar.xz.asc" "lighttpd-$LIGHTTPD_VERSION.tar.xz" \
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
RUN apk add --no-cache pcre2 zlib brotli-libs zstd-libs libdeflate libmaxminddb \
      libssl3 libcrypto3 lua5.5-libs \
 && mkdir -p /var/www/html /etc/lighttpd/conf.d
COPY --from=build /out/usr/local /usr/local
COPY --from=build /out/mime.conf /etc/lighttpd/mime.conf
COPY lighttpd.conf /etc/lighttpd/lighttpd.conf
RUN /usr/local/sbin/lighttpd -V
ENV PORT=8080 SERVER_ROOT=/var/www/html SERVER_NAME=localhost ACCESS_LOG=/dev/stderr
USER 1000:1000
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s \
  CMD wget -qS -O /dev/null "http://127.0.0.1:$PORT/" 2>&1 | grep -q '^  HTTP/'
CMD ["/usr/local/sbin/lighttpd", "-D", "-f", "/etc/lighttpd/lighttpd.conf"]
