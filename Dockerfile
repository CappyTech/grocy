# syntax=docker/dockerfile:1
#
# Grocy image built from source (CappyTech fork).
#
# Upstream ships no Dockerfile; the community images (e.g. linuxserver/grocy)
# bundle a release tarball. This builds the app from this repo instead, so
# patches carried on this fork end up in the running image.
#
# Two things are NOT in git and must be built (both are gitignored):
#   /packages        - composer vendor-dir (grocy overrides it from "vendor")
#   /public/packages - yarn modules-folder, set in .yarnrc
#
# Data lives outside the image. Point GROCY_DATAPATH at a mounted directory;
# it is created and seeded from config-dist.php on first start.

########################  composer dependencies  ########################
# php:8.5 to match composer.json's "php": "8.5.*" so version resolution is
# real rather than bypassed with --ignore-platform-reqs.
FROM php:8.5-cli-alpine AS vendor

# git: composer.json declares two VCS repositories (berrnd/lessql and
# berrnd/php-gettext), which composer clones rather than fetching from packagist.
RUN apk add --no-cache git unzip
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /src
COPY composer.json composer.lock ./

# Autoloader generation is deferred: composer.json's autoload maps psr-4 roots
# (services/, controllers/, ...) and a "files" entry that must exist on disk,
# and those are not present yet at this layer. Splitting it this way keeps the
# dependency download cached against composer.json/lock alone.
# ext-gd (gumlet/php-image-resize) and ext-intl (mike42/escpos-php) are runtime
# requirements; this stage only downloads and extracts packages, so compiling
# them here would cost build time to satisfy a check that proves nothing. They
# are installed in the runtime stage and asserted there, which is where a
# missing extension would actually break.
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist --no-interaction \
        --ignore-platform-req=ext-gd --ignore-platform-req=ext-intl

COPY . .
RUN composer dump-autoload --no-dev --optimize --no-interaction

########################  frontend dependencies  ########################
FROM node:24-alpine AS assets

# git: package.json pulls @danielfarrell/bootstrap-combobox straight from a
# git URL. The image already bundles yarn 1.22.x, which is what we want --
# .yarnrc uses v1 flag syntax (--modules-folder, --install.production) that
# Berry does not understand. Pin the base image tag to keep it that way.
RUN apk add --no-cache git

WORKDIR /src
COPY package.json yarn.lock .yarnrc ./

# .yarnrc redirects installation into public/packages and sets
# production/ignore-scripts/ignore-optional, so no flags are needed here.
RUN yarn install --frozen-lockfile

########################  runtime  ########################
FROM php:8.5-fpm-alpine AS runtime

# The base image already provides mbstring, pdo_sqlite, curl, openssl, xml and
# opcache. Only these four are missing relative to a working grocy install.
RUN set -eux; \
    apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS freetype-dev libjpeg-turbo-dev libpng-dev \
        icu-dev openldap-dev libzip-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" gd intl ldap zip; \
    apk del --no-network .build-deps; \
    apk add --no-cache freetype libjpeg-turbo libpng icu-libs libldap libzip \
        nginx supervisor tzdata; \
    # Fail the build here rather than at runtime if an extension did not load.
    # This is the check the vendor stage deliberately skips.
    php -r '$r=["gd","intl","ldap","zip","pdo_sqlite","mbstring"]; \
            $m=array_values(array_filter($r,fn($e)=>!extension_loaded($e))); \
            if($m){fwrite(STDERR,"missing php extensions: ".implode(", ",$m)."\n");exit(1);} \
            echo "php extensions ok: ".implode(", ",$r)."\n";'

# uid/gid 1000 matches the host user that owns the bind-mounted data directory,
# so the database stays writable without a chown-on-boot dance.
RUN addgroup -g 1000 grocy && adduser -u 1000 -G grocy -D -H grocy

WORKDIR /app/www

COPY --chown=grocy:grocy . .
COPY --from=vendor --chown=grocy:grocy /src/packages ./packages
COPY --from=assets --chown=grocy:grocy /src/public/packages ./public/packages

COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY docker/php.ini /usr/local/etc/php/conf.d/grocy.ini
COPY docker/php-fpm.conf /usr/local/etc/php-fpm.d/zz-grocy.conf
COPY docker/supervisord.conf /etc/supervisord.conf
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && rm -rf /app/www/docker /app/www/.github /app/www/.devtools \
    && mkdir -p /var/lib/nginx/tmp /var/log/nginx /run/nginx \
    && chown -R grocy:grocy /var/lib/nginx /var/log/nginx /run/nginx

ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=$GIT_COMMIT \
    GROCY_DATAPATH=/config/data

VOLUME ["/config"]
EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD php -r 'exit(@file_get_contents("http://127.0.0.1/login") === false ? 1 : 0);'

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisord.conf"]
