# laravel-deploy

One interactive script that takes a bare Ubuntu server to a running Laravel app.

Installs Apache, the PHP version you pick, Composer and Git, clones your repo,
writes `.env`, sets permissions and configures the virtual host. MySQL,
phpMyAdmin, Node.js, a swap file and a Let's Encrypt certificate are optional
prompts. It is safe to re-run: existing packages, keys, swap files and clones
are detected and skipped rather than clobbered.

A companion script, [`setup-github-cicd.sh`](#github-actions-cicd-setup), runs on
your own computer afterwards and gives GitHub Actions the SSH access it needs to
deploy to the server.

## Requirements

- Ubuntu (tested on 24.04 and 26.04). PHP comes from the distro repos when they
  carry the version you asked for, otherwise from `ppa:ondrej/php`, otherwise
  from `packages.sury.org` — the PPA has no builds from 25.10 onward.
- A non-root user with `sudo` rights — or root plus `--bootstrap-user` (below)
- A Laravel repo containing a `.env.example`

## Usage

```bash
curl -fsSLO https://raw.githubusercontent.com/LyndonMcjohnson/laravel-deploy-script/main/laravel-deploy.sh
chmod +x laravel-deploy.sh
./laravel-deploy.sh
```

Run it as your normal user. **Do not** run it with `sudo ./laravel-deploy.sh` —
it calls `sudo` itself where it needs to, and running the whole thing as root
would leave your app files owned by root.

### Servers where root is the only account

Many images (Hetzner, OVH, plain Debian) give you root and nothing else. Running
the whole provision as root would leave every application file root-owned, so
the script refuses. Instead, as root:

```bash
./laravel-deploy.sh --bootstrap-user deploy
```

That creates `deploy`, adds it to `sudo` with a validated `NOPASSWD` rule, copies
`/root/.ssh/authorized_keys` across so the key you are already using works for
the new account, and re-executes itself as that user. A `-c` config is copied to
the new user's home at mode 600, since root's home is normally unreadable to
anyone else. Re-running it is harmless if the user already exists.

If sshd is configured to require a password *as well as* a key
(`AuthenticationMethods publickey,password`), the new account is created with no
password and could not log in, so the script offers to set one while you still
have a root shell.

### Unattended runs

```bash
./laravel-deploy.sh --dump-config > laravel-deploy.conf
$EDITOR laravel-deploy.conf
./laravel-deploy.sh -c laravel-deploy.conf -y
```

Any value present in the config is used as-is; anything missing is prompted for,
unless `-y` is passed, in which case a missing value with no built-in default is
a hard error. A filled-in config contains database passwords — it's in
`.gitignore`, and you should `chmod 600` it on the server.

| Flag | Effect |
| --- | --- |
| `-c, --config FILE` | Read answers from `FILE` (defaults to `./laravel-deploy.conf` if present) |
| `-y, --yes` | Never prompt; fail on a missing required value |
| `--dump-config` | Print a commented config template and exit |
| `--bootstrap-user NAME` | As root: create `NAME`, give it root's SSH key and passwordless sudo, then re-run as it |
| `-h, --help` | Usage |

## What it does, in order

1. `apt-get update` and base packages
2. Apache, with `mod_rewrite` and `mod_headers`
3. PHP from the first source that has your version — distro repos, then
   `ppa:ondrej/php`, then `packages.sury.org` — set as both the CLI default and
   the only enabled Apache PHP module; `index.php` moved to the front of
   `DirectoryIndex`. A dead PHP apt source from an earlier attempt is removed
   rather than left to break every later `apt-get update`.
4. Composer, installed to `/usr/local/bin/composer` and verified against the
   official SHA-384 signature
5. Git identity, plus an ed25519 SSH key — the public key is printed in full, and
   for an `ssh://` remote the script waits for you to add it to your Git host
6. A database server (optional): MySQL/MariaDB, or PostgreSQL. Either way it
   creates the app database and a dedicated app user. Skip it and point
   `DB_HOST` at an existing server (RDS, a managed instance, another box)
7. Redis (optional), pinned to loopback and verified with a PING
8. phpMyAdmin (optional), preseeded so `apt` doesn't prompt
9. Node.js from NodeSource (optional)
10. A swap file (optional), persisted in `/etc/fstab`
11. `git clone` into the web root — or `git pull` if the repo is already there
12. `.env` from `.env.example`, with app and database values filled in; an
    existing `.env` is backed up before it's touched
13. PHP extensions the app actually declares — `ext-*` is read out of
    `composer.json` and `composer.lock`, including transitive requires, and the
    matching apt packages are installed
14. `composer install`, `php artisan key:generate`, then `npm ci` and
    `npm run build` when the repo has a `package.json` (Node is installed
    automatically if it isn't already), permissions, and optionally
    `storage:link` and `migrate --force`
15. A dedicated Apache virtual host pointed at `public/`, config-tested before
    the restart
16. Queue workers under Supervisor (optional), laid out as the Laravel queue
    docs describe, and verified to reach RUNNING
17. certbot via snap and a certificate (optional), including the manual DNS
    challenge path for wildcard domains
18. A `ufw` firewall (optional): SSH on its detected port, plus 80 and 443.
    Runs last, once certbot is done with port 80
19. Production config/route/view caches, and a summary of every generated
    credential

Verbose output goes to `/tmp/laravel-deploy-<timestamp>.log`; the console shows
only the step checklist.

## GitHub Actions CI/CD setup

`setup-github-cicd.sh` is the other half of a deploy pipeline: once the server
exists, it creates the SSH key and GitHub secrets a workflow needs to log in and
deploy. It works for any project, not just Laravel. Run it **on your own
computer**, not on the server.

```bash
cd path/to/your/project          # optional: makes the repo the default answer
/path/to/deployment/setup-github-cicd.sh --dry-run   # preview, changes nothing
/path/to/deployment/setup-github-cicd.sh             # for real
```

Requires `gh` (logged in with admin access to the repo), `ssh` and `ssh-keygen`.
The server needs a non-root deploy user first — `laravel-deploy.sh
--bootstrap-user deploy` creates one.

### What it asks

| Prompt | Default |
| --- | --- |
| GitHub repository (`owner/name`) | The repo of the current folder |
| GitHub environment for the secrets | `Production` (blank = repository-level secrets) |
| Server host or IP | — |
| SSH port | `22` |
| SSH user | `deploy` |
| Deploy key name (stored in `~/.ssh`) | `<repo>-deploy-ci` |

### What it does

1. Creates the GitHub environment if it doesn't exist. On a private repo without
   a paid plan, environments aren't available, so it offers repository-level
   secrets instead.
2. Generates a dedicated passphrase-less ed25519 key in `~/.ssh` — or reuses one
   with the same name. A passphrase would be pointless, since Actions can't type it.
3. Adds the public key to the server with `ssh-copy-id` (using your existing
   password or key), then checks that the new key can log in. If the login still
   fails it prints the public key to add by hand and asks before going on.
4. Sets the secrets below. Names that already exist are listed and overwritten.
5. Lets you add extra project secrets (API tokens and so on). Values are typed
   hidden; nothing secret is ever printed.

| Secret | Value |
| --- | --- |
| `DEPLOY_HOST` | Server host or IP |
| `DEPLOY_USER` | SSH user |
| `DEPLOY_KEY` | The private key |
| `DEPLOY_PORT` | Only set when the port isn't 22 |

### Using the secrets in a workflow

The job's `environment:` must match the environment you chose, or it won't see
the secrets:

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: Production
    steps:
      - uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.DEPLOY_HOST }}
          username: ${{ secrets.DEPLOY_USER }}
          key: ${{ secrets.DEPLOY_KEY }}
          # port: ${{ secrets.DEPLOY_PORT }}   # only if you use a non-standard port
          script: |
            cd /var/www/html/your-app
            git pull origin main
```

### Notes

- **Avoid `root` as the SSH user.** The script warns and defaults to aborting.
  Anyone who obtains that secret gets full control of the server, and deploy
  commands (`composer`, `artisan`) run as root leave root-owned files in
  `storage/` and `bootstrap/cache` that the web server user can't write, which
  breaks the site. Create a deploy user first.
- **One key per project.** A dedicated key means a leaked secret can be revoked
  without touching your own login.
- **Re-running** with an existing key name reuses the key and overwrites the
  secrets, so it is also how you rotate them.
- **Never commit or share the private key** (the file in `~/.ssh` without
  `.pub`). GitHub secrets can't be read back once set.
- `--dry-run` still asks every question and makes read-only `gh` calls, but
  creates no key, environment, server login or secret.

## Notes on the choices made here

- **Permissions.** `storage/` and `bootstrap/cache` end up `775`, owned
  `$USER:www-data`, with the setgid bit set on directories, and your user is
  added to the `www-data` group. This is deliberately not the `chmod -R 777`
  that a lot of Laravel guides suggest.
- **MySQL auth.** `mysql_native_password` was removed in MySQL 8.4, so the
  script checks which plugins the server actually has active and falls back to
  `caching_sha2_password`.
- **Database user.** The app gets its own database user scoped to its own
  database. The MySQL root password is set but never written into `.env`.
- **Drivers.** `DB_CONNECTION` accepts `mysql`, `mariadb`, `pgsql` or `sqlite`.
  The port defaults to the driver's (3306 / 5432) unless you set `DB_PORT`, and
  the matching PDO extension (`php-mysql`, `php-pgsql`, `php-sqlite3`) is
  installed — Laravel apps rarely declare `ext-pgsql` in `composer.json`, so the
  composer scan would not catch it. On PostgreSQL 15+ the app role is granted
  `ALL ON SCHEMA public`, without which migrations cannot create tables.
- **Connection strings.** Set `USE_DATABASE_URL=yes` and give a
  `driver://user:pass@host:port/database` URL. Laravel's default config reads
  `DATABASE_URL` first and ignores the individual `DB_*` keys when it is
  present, so the script writes one or the other, never both.
- **Virtual host.** A dedicated file in `sites-available` with `AllowOverride
  All` scoped to the app's `public/` directory, rather than editing
  `000-default.conf` or loosening `apache2.conf` globally.
- **Asset builds.** A Laravel app with a `package.json` gets `npm ci` (or
  `npm install`) and its `build` / `production` / `prod` script run before the
  permissions pass. Without it there is no `public/build/manifest.json` and a
  Vite app answers every request with "Unable to locate file in Vite manifest",
  which reads like a PHP fault. Set `BUILD_ASSETS=no` to skip.
- **Firewall.** `ufw` defaults to deny-incoming and allows only SSH, 80 and 443.
  The SSH port is detected from your live session (`SSH_CONNECTION`), falling
  back to `sshd -T` and then `sshd_config`, and the script refuses to enable
  anything unless it can prove the SSH rule was added — enabling a default-deny
  firewall without one locks you out of a remote box permanently. Set
  `SSH_ALLOW_FROM` to an IP or CIDR to restrict SSH to it; left as `any`, SSH
  stays open but rate-limited to 6 connections per 30 seconds per source.
  On a cloud host your provider's own firewall (an EC2 security group, say)
  still applies independently — this does not replace it.
- **Queue workers.** `supervisor` runs `queue:work` with `numprocs` from
  `QUEUE_WORKERS`, and the script checks the program actually reaches `RUNNING`
  rather than trusting `supervisorctl start`, which returns success even for a
  process that dies immediately. `stopwaitsecs` defaults to `QUEUE_TIMEOUT + 30`
  and the run aborts if you configure it lower — Supervisor sends SIGTERM then
  SIGKILL after that window, so a shorter value kills jobs mid-flight. Deploys
  end with `php artisan queue:restart`, since workers hold the old code in
  memory until told to exit. With `QUEUE_CONNECTION=database` the `jobs` table
  must exist, so the script warns when migrations are turned off.
- **Redis.** Optional, and installed alongside `php-redis`. The server is
  pinned to `bind 127.0.0.1 -::1` with `protected-mode yes`, then the script
  checks with `ss` that nothing is listening on a public address — an
  internet-reachable Redis is found by scanners within hours and an
  unauthenticated one hands an attacker arbitrary file writes. Only lines that
  are already active directives get rewritten, so the commented examples in the
  shipped `redis.conf` are left alone rather than being uncommented into
  conflicting `bind` lines. `REDIS_FOR_CACHE` and `REDIS_FOR_SESSION` are
  opt-in; the cache key is written as `CACHE_STORE` or `CACHE_DRIVER` depending
  on which one the app's `.env` already uses, since Laravel 11 renamed it.
- **Generated passwords.** Blank password prompts generate 24 alphanumeric
  characters and print them once, in the closing summary. Save them then.

## Caveats

- The script is written for a single-app server. Running it twice with different
  `APP_DIR_NAME` values will create a second virtual host but will also switch
  the server-wide PHP version and MySQL root password to the second run's
  answers.
- phpMyAdmin, if installed, is reachable at `/phpmyadmin` with no extra
  restriction. Put it behind an IP allowlist or basic auth before you rely on it.
- Wildcard certificates require a DNS TXT record, so that step is interactive
  even under `-y`.

## License

MIT — see [LICENSE](LICENSE).
