#!/bin/sh
# Prepares the mounted data directory, then hands off to supervisord.
set -eu

DATAPATH="${GROCY_DATAPATH:-/config/data}"

# grocy's PrerequisiteChecker aborts with a bare "Unable to run Grocy" if
# config.php is absent, so seed it from config-dist.php on a fresh volume.
# Existing installs are left alone -- this file is user-editable.
mkdir -p "$DATAPATH"
if [ ! -f "$DATAPATH/config.php" ]; then
    echo "[entrypoint] seeding config.php from config-dist.php"
    cp /app/www/config-dist.php "$DATAPATH/config.php"
fi

# viewcache holds compiled Blade templates and the Slim route cache; storage
# holds uploaded files. Both are created lazily by the app but only if the
# parent is writable, which it may not be on a fresh root-owned bind mount.
mkdir -p "$DATAPATH/viewcache" "$DATAPATH/storage" "$DATAPATH/plugins"

# Stale compiled templates survive an image upgrade and can reference views or
# helpers that changed underneath them. Cheap to rebuild, so clear on boot.
rm -rf "${DATAPATH:?}/viewcache/"* 2>/dev/null || true

# Only meaningful when started as root (the normal case): align ownership with
# the uid the workers run as. Skipped when the container is run with --user,
# where the chown would fail and is not ours to make.
if [ "$(id -u)" = "0" ]; then
    chown -R grocy:grocy "$DATAPATH" 2>/dev/null || \
        echo "[entrypoint] warning: could not chown $DATAPATH (read-only or foreign uid?)"
fi

exec "$@"
