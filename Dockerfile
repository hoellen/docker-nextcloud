# -------------- Build-time variables --------------
ARG NEXTCLOUD_VERSION=31.0.3
ARG PHP_VERSION=8.3
ARG NGINX_VERSION=1.26

ARG ALPINE_VERSION=3.21
ARG HARDENED_MALLOC_VERSION=11
ARG SNUFFLEUPAGUS_VERSION=0.10.0

ARG UID=1000
ARG GID=1000

# nextcloud-31.0.3.tar.bz2
ARG SHA256_SUM="9283aebd8fda5ad739cda56f7cabaa835cc3bf98f79536c36dccd7309e2b305a"

# Nextcloud Security <security@nextcloud.com> (D75899B9A724937A)
ARG GPG_FINGERPRINT="2880 6A87 8AE4 23A2 8372  792E D758 99B9 A724 937A"
# ---------------------------------------------------

### Build PHP base
FROM docker.io/library/php:${PHP_VERSION}-fpm-alpine${ALPINE_VERSION} as base

ARG SNUFFLEUPAGUS_VERSION

ENV IMAGICK_SHA 28f27044e435a2b203e32675e942eb8de620ee58

RUN apk -U upgrade \
 && apk add -t build-deps \
        $PHPIZE_DEPS \
        freetype-dev \
        git \
        gmp-dev \
        icu-dev \
        libjpeg-turbo-dev \
        libpng-dev \
        libwebp-dev \
        libzip-dev \
        openldap-dev \
        postgresql-dev \
        samba-dev \
        imagemagick-dev \
        zlib-dev \
 && apk --no-cache add \
        freetype \
        gmp \
        icu \
        libjpeg-turbo \
        librsvg \
        libpq \
        libpq \
        libwebp \
        libzip \
        libsmbclient \
        openldap \
        libgomp \
        imagemagick \
        zlib \
 && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
 && docker-php-ext-configure ldap \
 && docker-php-ext-install -j "$(nproc)" \
        bcmath \
        exif \
        gd \
        bz2 \
        intl \
        ldap \
        opcache \
        pcntl \
        pdo_mysql \
        pdo_pgsql \
        sysvsem \
        zip \
        gmp \
 && pecl install smbclient \
 && pecl install APCu \
 && pecl install redis \
 && curl -L -o /tmp/imagick.tar.gz https://github.com/Imagick/imagick/archive/${IMAGICK_SHA}.tar.gz && tar --strip-components=1 -xf /tmp/imagick.tar.gz && phpize && ./configure && make && make install \
 && apk add --no-cache --virtual .imagick-runtime-deps imagemagick \
 && docker-php-ext-enable \
        smbclient \
        redis \
        imagick \
 && cd /tmp && git clone --depth 1 --branch v${SNUFFLEUPAGUS_VERSION} https://github.com/jvoisin/snuffleupagus \
 && cd snuffleupagus/src && phpize && ./configure --enable-snuffleupagus && make && make install \
 && apk del build-deps \
 && rm -rf /var/cache/apk/* /tmp/*


### Build Hardened Malloc
ARG ALPINE_VERSION
FROM docker.io/library/alpine:${ALPINE_VERSION} as build-malloc

ARG HARDENED_MALLOC_VERSION
ARG CONFIG_NATIVE=false
ARG VARIANT=light

RUN apk --no-cache add build-base git gnupg && cd /tmp \
 && wget -q https://github.com/thestinger.gpg && gpg --import thestinger.gpg \
 && git clone --depth 1 --branch ${HARDENED_MALLOC_VERSION} https://github.com/GrapheneOS/hardened_malloc \
 && cd hardened_malloc && git verify-tag $(git describe --tags) \
 && make CONFIG_NATIVE=${CONFIG_NATIVE} VARIANT=${VARIANT}


### Fetch nginx
FROM docker.io/library/nginx:${NGINX_VERSION}-alpine as nginx


### Build Nextcloud (production environemnt)
FROM base as nextcloud

COPY --from=nginx /usr/sbin/nginx /usr/sbin/nginx
COPY --from=nginx /etc/nginx /etc/nginx
COPY --from=build-malloc /tmp/hardened_malloc/out-light/libhardened_malloc-light.so /usr/local/lib/

ARG NEXTCLOUD_VERSION
ARG SHA256_SUM
ARG GPG_FINGERPRINT

ARG UID
ARG GID

ENV UPLOAD_MAX_SIZE=10G \
    APC_SHM_SIZE=128M \
    OPCACHE_MEM_SIZE=128 \
    MEMORY_LIMIT=512M \
    CRON_PERIOD=5m \
    CRON_MEMORY_LIMIT=1g \
    DB_TYPE=sqlite3 \
    DOMAIN=localhost \
    PHP_HARDENING=true \
    LD_PRELOAD="/usr/local/lib/libhardened_malloc-light.so"

RUN apk --no-cache add \
        gnupg \
        pcre2 \
        s6 \
 && NEXTCLOUD_TARBALL="nextcloud-${NEXTCLOUD_VERSION}.tar.bz2" && cd /tmp \
 && wget -q https://download.nextcloud.com/server/releases/${NEXTCLOUD_TARBALL} \
 && wget -q https://download.nextcloud.com/server/releases/${NEXTCLOUD_TARBALL}.asc \
 && wget -q https://nextcloud.com/nextcloud.asc \
 && echo "Verifying both integrity and authenticity of ${NEXTCLOUD_TARBALL}..." \
 && CHECKSUM_STATE=$(echo -n $(echo "${SHA256_SUM}  ${NEXTCLOUD_TARBALL}" | sha256sum -c) | tail -c 2) \
 && if [ "${CHECKSUM_STATE}" != "OK" ]; then echo "Error: checksum does not match" && exit 1; fi \
 && gpg --import nextcloud.asc \
 && FINGERPRINT="$(LANG=C gpg --verify ${NEXTCLOUD_TARBALL}.asc ${NEXTCLOUD_TARBALL} 2>&1 \
  | sed -n "s#Primary key fingerprint: \(.*\)#\1#p")" \
 && if [ -z "${FINGERPRINT}" ]; then echo "Error: invalid GPG signature!" && exit 1; fi \
 && if [ "${FINGERPRINT}" != "${GPG_FINGERPRINT}" ]; then echo "Error: wrong GPG fingerprint" && exit 1; fi \
 && echo "All seems good, now unpacking ${NEXTCLOUD_TARBALL}..." \
 && mkdir /nextcloud && tar xjf ${NEXTCLOUD_TARBALL} --strip 1 -C /nextcloud \
 && apk del gnupg && rm -rf /tmp/* /root/.gnupg \
 && adduser -g ${GID} -u ${UID} --disabled-password --gecos "" nextcloud \
 && chown -R nextcloud:nextcloud /nextcloud/config

COPY --chown=nextcloud:nextcloud rootfs /

RUN chmod +x /usr/local/bin/* /etc/s6.d/*/* /etc/s6.d/.s6-svscan/*

USER nextcloud

WORKDIR /nextcloud

VOLUME /data /nextcloud/config /nextcloud/apps2 /nextcloud/themes

EXPOSE 8888

LABEL org.opencontainers.image.description="All-in-one Nextcloud image, based on Alpine Linux" \
      org.opencontainers.image.version="${NEXTCLOUD_VERSION}" \
      org.opencontainers.image.authors="Hoellen <dev@hoellen.eu>" \
      org.opencontainers.image.source="https://github.com/hoellen/docker-nextcloud"

CMD ["run.sh"]
