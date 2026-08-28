# laravel-deploy

One interactive script that takes a bare Ubuntu server to a running Laravel app.

Installs Apache, the PHP version you pick, Composer and Git, clones your repo,
writes `.env`, sets permissions and configures the virtual host. MySQL,
phpMyAdmin, Node.js, a swap file and a Let's Encrypt certificate are optional
prompts. It is safe to re-run: existing packages, keys, swap files and clones
are detected and skipped rather than clobbered.

## Requirements

- Ubuntu (tested on 22.04 and 24.04; other Debian derivatives will likely work
  but the PHP packages come from the `ppa:ondrej/php` PPA, which is Ubuntu-only)
- A non-root user with `sudo` rights
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
| `-h, --help` | Usage |

## What it does, in order

1. `apt-get update` and base packages
2. Apache, with `mod_rewrite` and `mod_headers`
3. PHP from `ppa:ondrej/php` with the extensions Laravel needs, set as both the
   CLI default and the only enabled Apache PHP module; `index.php` moved to the
   front of `DirectoryIndex`
4. Composer, installed to `/usr/local/bin/composer` and verified against the
   official SHA-384 signature
5. Git identity, plus an ed25519 SSH key — the public key is printed in full, and
   for an `ssh://` remote the script waits for you to add it to your Git host
6. MySQL (optional): sets a root password, creates the app database and a
   dedicated app user
7. phpMyAdmin (optional), preseeded so `apt` doesn't prompt
8. Node.js from NodeSource (optional)
9. A swap file (optional), persisted in `/etc/fstab`
10. `git clone` into the web root — or `git pull` if the repo is already there
11. `.env` from `.env.example`, with app and database values filled in; an
    existing `.env` is backed up before it's touched
12. `composer install`, `php artisan key:generate`, permissions, and optionally
    `storage:link` and `migrate --force`
13. A dedicated Apache virtual host pointed at `public/`, config-tested before
    the restart
14. certbot via snap and a certificate (optional), including the manual DNS
    challenge path for wildcard domains
15. Production config/route/view caches, and a summary of every generated
    credential

Verbose output goes to `/tmp/laravel-deploy-<timestamp>.log`; the console shows
only the step checklist.

## Notes on the choices made here

- **Permissions.** `storage/` and `bootstrap/cache` end up `775`, owned
  `$USER:www-data`, with the setgid bit set on directories, and your user is
  added to the `www-data` group. This is deliberately not the `chmod -R 777`
  that a lot of Laravel guides suggest.
- **MySQL auth.** `mysql_native_password` was removed in MySQL 8.4, so the
  script checks which plugins the server actually has active and falls back to
  `caching_sha2_password`.
- **Database user.** The app gets its own MySQL user scoped to its own database.
  The root password is set but never written into `.env`.
- **Virtual host.** A dedicated file in `sites-available` with `AllowOverride
  All` scoped to the app's `public/` directory, rather than editing
  `000-default.conf` or loosening `apache2.conf` globally.
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
