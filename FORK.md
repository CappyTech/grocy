# CappyTech fork of grocy

Fork of [grocy/grocy](https://github.com/grocy/grocy) (MIT), carrying local
patches and building its own container image.

Runs at `food.cappylabs.uk` on the Heron CS server. Deployment matches the other
CappyTech services: CI builds an image, pushes it to GHCR, and the server pulls
it. Editing a checkout changes nothing that is running.

## Why this fork exists

Upstream ships no Dockerfile, and the community images bundle a release tarball,
so there is no way to run patched grocy source without building it. Everything
here is additive — no upstream file is modified except the patches listed below,
which keeps `git merge upstream/master` close to conflict-free.

## Patches carried

| Commit | What | Why |
| --- | --- | --- |
| `Fix en_GB dates falling back to US MM/DD/YYYY` | `localization/en_GB/component_translations.po`: `moment_locale` `"x"` → `"en-gb"` | Upstream's en_GB declares no moment locale, so moment keeps its built-in US formatting and en_GB users get MM/DD/YYYY, Sunday-first weeks and 12-hour times. `en-gb.js` is already bundled. Worth upstreaming. |

Files added by this fork (not upstream, so they never conflict):
`Dockerfile`, `.dockerignore`, `docker/`, `.github/workflows/ci.yml`, `FORK.md`.

## Image

`ghcr.io/cappytech/grocy`, tagged `latest` (master), `sha-<short sha>`, and the
grocy version from `version.json` (e.g. `4.6.0`).

Built from source in three stages: composer deps (`packages/`), yarn deps
(`public/packages/` — both are gitignored upstream and must be built), then a
`php:8.5-fpm-alpine` runtime with nginx and supervisor.

### Configuration

Data lives outside the image; mount a volume and point `GROCY_DATAPATH` at it
(defaults to `/config/data`). `config.php` is seeded from `config-dist.php` on
first start.

Any grocy setting can be overridden with a `GROCY_`-prefixed environment
variable — see the header of `config-dist.php`. The deployment uses:

```yaml
GROCY_BASE_URL: https://food.cappylabs.uk   # must be absolute: TLS terminates
                                            # upstream and X-Forwarded-Proto does
                                            # not survive the tunnel, so grocy
                                            # would emit http:// asset URLs
GROCY_DEFAULT_LOCALE: en_GB
GROCY_CURRENCY: GBP                         # display only; grocy converts nothing
GROCY_CALENDAR_FIRST_DAY_OF_WEEK: "1"       # Sunday=0
```

## Merging upstream

```bash
git fetch upstream
git merge upstream/master
```

Then check the patch table above still applies — in particular whether upstream
has fixed `moment_locale` for en_GB, in which case that commit can be dropped.
CI's smoke test asserts `en-gb.js` is still referenced, so a silent regression
fails the build rather than quietly reverting your date format.

## CI

`.github/workflows/ci.yml` builds, **smoke tests, then pushes** — in that order,
deliberately: the server deploys from `:latest`, so an image that does not boot
must never reach that tag. The smoke test boots the container on an empty data
directory and asserts it serves HTTP 200, applies `GROCY_CURRENCY`, and still
references and serves `en-gb.js`.
