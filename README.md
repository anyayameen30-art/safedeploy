# SafeDeploy — Zero‑Downtime Blue/Green Deployer (Bash)

A tiny, production‑style deploy script in **pure Bash** that ships a new version of a site with **zero downtime**, runs a **health check**, and **automatically rolls back** if something looks wrong. It also keeps your releases tidy with a simple **retention policy**.

---

## Features

- **Blue/Green swap** using a `current` symlink (instant switch)
- **Health checks** with retries after the switch
- **Automatic rollback** to the previous release on failure
- **Release retention** (keeps last _N_ versions)
- **Checksums & metadata** (`sha256sums.txt`, `release_meta.txt`) for auditability
- Works locally or on any Linux box with a web server (Nginx shown here)

---

## How it works

```
[ dev box ] -> (tar.gz) ->  /srv/site/releases/<APP_NAME>-<TIMESTAMP>
                                   |
                             /srv/site/current  <-- web server serves this
                                   |
                         health check -> ok? keep : rollback
```

The script **packages** your site, **unpacks** it into a new timestamped release directory, **flips** the `current` symlink to the new version, **reloads** Nginx (no downtime), **verifies** health, and **rolls back** to the previous release if the health check fails. Old releases beyond your retention window are pruned.

---

## Requirements

- Linux with **bash**, **tar**, **curl**, **sha256sum**
- A web server pointing its document root to the **`/srv/site/current`** symlink  
  (Example config below for Nginx)
- Ability to `sudo` for creating/updating `/srv/site/*` and reloading the web server

---

## Quickstart

### 1) Web server (Nginx) one‑time setup

```bash
sudo dnf -y install nginx
sudo mkdir -p /srv/site/releases
```

Create `/etc/nginx/conf.d/site.conf`:

```nginx
server {
  listen 80;
  server_name _;

  root /srv/site/current;
  index index.html;

  location /healthz {
    default_type text/plain;
    return 200 "ok\n";
  }
}
```

Then enable & verify:

```bash
sudo nginx -t && sudo systemctl enable --now nginx
```

> **Tip:** Any server that serves whatever `current` points to will work (Apache, Caddy, etc.). Just adapt the reload command in your `.env`.

---

### 2) Project setup

Clone your repo (or copy these files into an existing one) and create minimal content:

```bash
mkdir -p site scripts
printf "Hello from SafeDeploy\n" > site/index.html
```

Create a `.env` in the project root:

```bash
APP_NAME="site"
SITE_SRC="./site"
RELEASES_DIR="/srv/site/releases"
CURRENT_LINK="/srv/site/current"
KEEP_RELEASES=5
HEALTH_URL="http://localhost/healthz"
RELOAD_CMD="sudo systemctl reload nginx"
```

> The script expects `.env` to be next to it when you run it from the project root.

Add the deploy script (save as `scripts/safe_deploy.sh`) and make it executable:

```bash
chmod +x scripts/safe_deploy.sh
```

> Your deploy script should use a **safe timestamp** (no `/` or `:`): `date -u +%Y-%m-%dT%H-%M-%SZ` and package with `tar -czf`.

---

### 3) First deploy

From the project root:

```bash
./scripts/safe_deploy.sh
```

Verify:

```bash
curl -s http://localhost | head
readlink -f /srv/site/current
ls -1dt /srv/site/releases | head
```

You should see the newest timestamped release and the `current` symlink pointing to it.

---

### 4) Rollback demo (for screenshots)

Edit `.env` temporarily:

```bash
HEALTH_URL="http://localhost/badpath"
```

Run a deploy again:

```bash
./scripts/safe_deploy.sh
```

You’ll see the script report **Health FAILED** and **roll back** to the previous release automatically.  
Revert `.env` when done:

```bash
HEALTH_URL="http://localhost/healthz"
```

---

## Configuration

| Variable        | Purpose                                                                 | Example                               |
|-----------------|-------------------------------------------------------------------------|---------------------------------------|
| `APP_NAME`      | Prefix for release directories & archive names                          | `site`                                |
| `SITE_SRC`      | Path to the content to deploy (directory)                               | `./site`                              |
| `RELEASES_DIR`  | Where timestamped releases are stored                                   | `/srv/site/releases`                  |
| `CURRENT_LINK`  | Symlink the web server serves                                           | `/srv/site/current`                   |
| `KEEP_RELEASES` | Number of most‑recent releases to keep                                  | `5`                                   |
| `HEALTH_URL`    | Endpoint that must return HTTP 200 for success                          | `http://localhost/healthz`            |
| `RELOAD_CMD`    | Command to reload the web server (no downtime on reload)                | `sudo systemctl reload nginx`         |

---

## What the script does (step by step)

1. **Sanity checks**: tools present, `.env` loaded, source dir exists.  
2. **Package** the site into `/tmp/<APP_NAME>-<STAMP>.tar.gz` using `tar -czf`.  
3. **Create** a new release directory: `${RELEASES_DIR}/${APP_NAME}-${STAMP}`.  
4. **Unpack** the tarball there (`--strip-components=1` to drop the top‑level folder).  
5. **Write metadata** (`release_meta.txt`) and **checksums** (`sha256sums.txt`).  
6. **Remember** the previously live directory (`readlink -f "$CURRENT_LINK"`).  
7. **Point** `current -> new release` with `ln -sfn` (instant switch).  
8. **Reload** web server (`$RELOAD_CMD`).  
9. **Health check** `$HEALTH_URL` with retries.  
10. If unhealthy, **roll back** the symlink to the previous release and reload.  
11. **Prune** old releases: keep `KEEP_RELEASES`, delete the rest.

---

## Directory layout

```
/srv/site/
├── current -> /srv/site/releases/site-2025-10-01T01-23-45Z
└── releases/
    ├── site-2025-09-30T23-59-10Z/
    │   ├── index.html
    │   ├── release_meta.txt
    │   └── sha256sums.txt
    └── site-2025-10-01T01-23-45Z/
        ├── index.html
        ├── release_meta.txt
        └── sha256sums.txt
```

---

## Troubleshooting

- **`curl` health check fails but site loads in browser**  
  Confirm the exact path/port in `HEALTH_URL`. Try `curl -v http://localhost/healthz`. Check `sudo nginx -t` and `journalctl -u nginx`.

- **Permission denied under `/srv`**  
  Create the directories with `sudo` and ensure the user running the script can `ln -sfn` into `/srv/site`. You may choose to run the script with `sudo` if your environment requires it.

- **“No previous release to roll back to.”**  
  Expected on your very first deploy. Rollback only works after you have at least one previous release.

- **Long dashes (`—`) vs double hyphens (`--`)**  
  If you copy from rich text, ensure CLI flags like `--max-time` use ASCII `--`.

---

## FAQ

**Q: Does this work with Apache or Caddy?**  
Yes. Point the doc root to the `current` symlink and adjust `RELOAD_CMD` to that server’s reload command.

**Q: Can I deploy more than static files?**  
Yes. Any folder of content works. For app servers, you’d still flip `current` and run a graceful reload for the app service.

**Q: What timestamp format do releases use?**  
UTC ISO‑like: `YYYY‑MM‑DDTHH‑MM‑SSZ` (safe for file paths).

**Q: Why a symlink instead of replacing files in place?**  
Atomic switch, easy rollback, and always‑consistent releases.

---

## Roadmap (optional ideas)

- `--dry-run` and `--verbose` flags
- Slack/Discord webhook notifications
- Multi‑host deploy wrapper with `rsync + ssh`
- GitHub Actions: `shellcheck` + basic tests

---

## License

MIT — see `LICENSE` (or choose your preferred license for your repo).
