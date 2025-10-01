#!/usr/bin/env bash
set -Eeuo pipefail # safer script settings: stop on errors, unset vars, or failed pipes

#Helpers
die(){ echo "[✖] $*" >&2; exit 1; } # die: print an error message and exit the script
log(){ printf "[%(%Y-%m-%dT%H-%M-%SZ)T] %s\n" -1 "$*"; }  # log: print message with UTC timestamp

# Load Config
[[ -f ".env" ]] || die "Missing .env" # make sure .env file exists
# shellcheck disable=SC1091
source ".env" # load environment variables from .env

#Double Check
command -v curl >/dev/null || die "curl required"     # curl must be installed
[[ -d "$SITE_SRC" ]] || die "SITE_SRC not found: $SITE_SRC"   # site source folder must exist
[[ -n "${RELEASES_DIR:-}" && -n "${CURRENT_LINK:-}" ]] || die "Bad .env"    # required vars not empty

#Prepare
STAMP=$(date -u +%Y/%m/%dT%H:%M:%SZ)
RELEASE_DIR="${RELEASES_DIR}/${APP_NAME}-${STAMP}"   # full path for new release folder
TARBALL="/tmp/${APP_NAME}-${STAMP}.tar.gz"            # temp archive name for packaging

#Package Artifact 
log "Packaging $SITE_SRC --> $TARBALL"    # log what’s being packaged
tar -C "$(dirname "$SITE_SRC")" -czf "$TARBALL" "$(basename "$SITE_SRC")"
# -C change to parent dir, only include the site folder

#Install to new release dir
sudo mkdir -p "$RELEASE_DIR"
log "Unpacking to $RELEASE_DIR"
sudo tar -xzf "$TARBALL" -C "$RELEASE_DIR" --strip-components=1   # extract tarball into release dir, strip top folder so files go directly inside

#Meta + Checksum 
echo "version=$STAMP" | sudo tee "$RELEASE_DIR/release_meta.txt" >/dev/null
( cd "$RELEASE_DIR" && sudo find . -type f -print0 | sudo xargs -0 sha256sum | sudo tee "$RELEASE_DIR/sha256sums.txt" >/dev/null )

#Remember previous target for rollback 
PREV_TARGET=""      # default: no previous release
if [[ -L "$CURRENT_LINK" ]]; then
  PREV_TARGET=$(readlink -f "$CURRENT_LINK" || true)    # resolve old "current" symlink if it exists
fi

#Switch traffic (symlink swap)
log "Pointing $CURRENT_LINK -> $RELEASE_DIR"       # log what we’re switching to
sudo ln -sfn "$RELEASE_DIR" "$CURRENT_LINK"        # update symlink to point at new release

#Reload web server (no downtime)
if [[ -n "${RELOAD_CMD:-}" ]]; then
  log "Reload: $RELOAD_CMD"    # log reload command
  bash -c "$RELOAD_CMD"        # run reload (e.g. nginx reload)
fi

#Health check with retries
ATTEMPTS=10
SLEEP=1
ok=false
for i in $(seq 1 "$ATTEMPTS"); do
  if curl -fsS --max-time 2 "$HEALTH_URL" >/dev/null; then
    log "Health OK on attempt $i"    # success, site is healthy
    ok=true; break
  else
    log "Health not ready (attempt $i/$ATTEMPTS) ..."
    sleep "$SLEEP"
  fi
done

#Rollback if health failed
if [[ "$ok" != true ]]; then
  log "Health FAILED. Rolling back."
  if [[ -n "$PREV_TARGET" && -d "$PREV_TARGET" ]]; then
    sudo ln -sfn "$PREV_TARGET" "$CURRENT_LINK"   # point back to previous release
    [[ -n "${RELOAD_CMD:-}" ]] && bash -c "$RELOAD_CMD" || true   # reload web server if needed
    die "Rolled back to previous release."    # exit with rollback message
  else
    die "No previous release to roll back to."    # exit with error if no fallback exists
  fi
fi

#Retention policy
log "Pruning old releases (keep last $KEEP_RELEASES)"
sudo bash -c "
  ls -1dt ${RELEASES_DIR}/${APP_NAME}-* 2>/dev/null | tail -n +$((KEEP_RELEASES+1)) | xargs -r rm -rf
"
# list all releases newest first, skip the most recent KEEP_RELEASES, delete the rest
log "Deploy complete: $RELEASE_DIR"

