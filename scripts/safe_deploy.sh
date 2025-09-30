#!/usr/bin/env bash
set -Eeuo pipefail

# --- helpers ---
die(){ echo "[✖] $*" >&2; exit 1; }
log(){ printf "[%(%Y-%m-%dT%H-%M-%SZ)T] %s\n" -1 "$*"; }  # UTC timestamp (no colons)

# --- load config ---
[[ -f ".env" ]] || die "Missing .env"
# shellcheck disable=SC1091
source ".env"

# --- sanity checks ---
command -v curl >/dev/null || die "curl required"
[[ -d "$SITE_SRC" ]] || die "SITE_SRC not found: $SITE_SRC"
[[ -n "${RELEASES_DIR:-}" && -n "${CURRENT_LINK:-}" ]] || die "Bad .env"

# --- prepare ---
STAMP=$(date -u +%Y-%m-%dT%H-%M-%SZ)
RELEASE_DIR="${RELEASES_DIR}/${APP_NAME}-${STAMP}"
TARBALL="/tmp/${APP_NAME}-${STAMP}.tar.gz"

# --- package artifact ---
log "Packaging $SITE_SRC -> $TARBALL"
tar -C "$(dirname "$SITE_SRC")" -czf "$TARBALL" "$(basename "$SITE_SRC")"

# --- install to new release dir ---
sudo mkdir -p "$RELEASE_DIR"
log "Unpacking to $RELEASE_DIR"
sudo tar -xzf "$TARBALL" -C "$RELEASE_DIR" --strip-components=1

# meta + checksum (nice touch for audits)
echo "version=$STAMP" | sudo tee "$RELEASE_DIR/release_meta.txt" >/dev/null
( cd "$RELEASE_DIR" && sudo find . -type f -print0 | sudo xargs -0 sha256sum | sudo tee "$RELEASE_DIR/sha256sums.txt" >/dev/null )

# --- remember previous target for rollback ---
PREV_TARGET=""
if [[ -L "$CURRENT_LINK" ]]; then
  PREV_TARGET=$(readlink -f "$CURRENT_LINK" || true)
fi

# --- switch traffic (symlink swap) ---
log "Pointing $CURRENT_LINK -> $RELEASE_DIR"
sudo ln -sfn "$RELEASE_DIR" "$CURRENT_LINK"

# --- reload web server (no downtime) ---
if [[ -n "${RELOAD_CMD:-}" ]]; then
  log "Reload: $RELOAD_CMD"
  bash -c "$RELOAD_CMD"
fi

# --- health check with retries ---
ATTEMPTS=10
SLEEP=1
ok=false
for i in $(seq 1 "$ATTEMPTS"); do
  if curl -fsS --max-time 2 "$HEALTH_URL" >/dev/null; then
    log "Health OK on attempt $i"
    ok=true; break
  else
    log "Health not ready (attempt $i/$ATTEMPTS) ..."
    sleep "$SLEEP"
  fi
done

# --- rollback if health failed ---
if [[ "$ok" != true ]]; then
  log "Health FAILED. Rolling back."
  if [[ -n "$PREV_TARGET" && -d "$PREV_TARGET" ]]; then
    sudo ln -sfn "$PREV_TARGET" "$CURRENT_LINK"
    [[ -n "${RELOAD_CMD:-}" ]] && bash -c "$RELOAD_CMD" || true
    die "Rolled back to previous release."
  else
    die "No previous release to roll back to."
  fi
fi

# --- retention policy ---
log "Pruning old releases (keep last $KEEP_RELEASES)"
sudo bash -c "
  ls -1dt ${RELEASES_DIR}/${APP_NAME}-* 2>/dev/null | tail -n +$((KEEP_RELEASES+1)) | xargs -r rm -rf
"

log "Deploy complete: $RELEASE_DIR"

