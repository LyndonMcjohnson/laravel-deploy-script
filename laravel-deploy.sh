#!/usr/bin/env bash
#
# laravel-deploy.sh — provision a fresh Ubuntu server for a Laravel app.
#
# Installs: Apache + PHP (your choice of version) + Composer + Git + your repo,
# and optionally MySQL, phpMyAdmin, Node.js, a swap file and a Let's Encrypt cert.
#
# Usage:
#   ./laravel-deploy.sh                    # interactive, prompts for everything
#   ./laravel-deploy.sh -c deploy.conf     # read answers from a config file
#   ./laravel-deploy.sh -c deploy.conf -y  # non-interactive (fails on missing required values)
#   ./laravel-deploy.sh --dump-config      # print a config template and exit
#
# Run as a normal user with sudo rights. Do NOT run with `sudo ./laravel-deploy.sh`.
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------

CONFIG_FILE=""
NON_INTERACTIVE="no"
LOG_FILE="/tmp/laravel-deploy-$(date +%Y%m%d-%H%M%S).log"

export DEBIAN_FRONTEND=noninteractive

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_BLUE=$'\033[34m'
C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'

log()   { printf '%s\n' "${C_BLUE}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '%s\n' "${C_GREEN}  ✓${C_RESET} $*"; }
warn()  { printf '%s\n' "${C_YELLOW}  !${C_RESET} $*" >&2; }
die()   { printf '%s\n' "${C_RED}  ✗ $*${C_RESET}" >&2; exit 1; }

trap 'die "Failed at line $LINENO. Full log: $LOG_FILE"' ERR

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)      CONFIG_FILE="${2:-}"; shift 2 ;;
    -y|--yes|--non-interactive) NON_INTERACTIVE="yes"; shift ;;
    --dump-config)    DUMP_CONFIG="yes"; shift ;;
    -h|--help)        usage ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Config template
# ---------------------------------------------------------------------------

dump_config() {
cat <<'CONF'
# laravel-deploy.conf — every value is optional; anything left blank is prompted for.
# Booleans accept: yes/no, y/n, true/false, 1/0.
#
# WARNING: a filled-in copy of this file contains database passwords.
# Keep it out of version control (the shipped .gitignore already excludes
# laravel-deploy.conf) and chmod 600 it on the server.

# --- PHP / Apache -----------------------------------------------------------
PHP_VERSION=8.4
INSTALL_NODE=no
NODE_MAJOR=22

# --- Application ------------------------------------------------------------
WEB_ROOT=/var/www/html
REPO_URL=https://github.com/username/reponame.git
APP_DIR_NAME=                 # defaults to the repo name
GIT_BRANCH=                   # blank = repo default branch
COMPOSER_NO_DEV=yes           # yes = composer install --no-dev --optimize-autoloader
RUN_MIGRATIONS=no
RUN_STORAGE_LINK=yes
BUILD_ASSETS=yes             # npm ci + npm run build when the repo has a package.json

# --- Git identity / SSH key -------------------------------------------------
GIT_USER_EMAIL=you@example.com
GIT_USER_NAME=Your Name
GENERATE_SSH_KEY=yes

# --- .env -------------------------------------------------------------------
APP_NAME=Laravel
APP_ENV=production
APP_DEBUG=false
APP_URL=https://example.com
EDIT_ENV_AFTER=yes            # open $EDITOR on .env at the end for a final review

# --- Database ---------------------------------------------------------------
INSTALL_MYSQL=yes
MYSQL_ROOT_PASSWORD=          # blank = generated and printed at the end
DB_DATABASE=laravel
DB_USERNAME=laravel
DB_PASSWORD=                  # blank = generated and printed at the end
INSTALL_PHPMYADMIN=no

# --- Swap -------------------------------------------------------------------
CREATE_SWAP=yes
SWAP_SIZE_MB=2048

# --- TLS --------------------------------------------------------------------
INSTALL_SSL=yes
SSL_DOMAINS=example.com,www.example.com   # comma separated; a *.domain entry switches to DNS challenge
SSL_EMAIL=you@example.com
CONF
}

if [[ "${DUMP_CONFIG:-no}" == "yes" ]]; then dump_config; exit 0; fi

if [[ -z "$CONFIG_FILE" && -f ./laravel-deploy.conf ]]; then
  CONFIG_FILE=./laravel-deploy.conf
fi
if [[ -n "$CONFIG_FILE" ]]; then
  [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"
  # shellcheck disable=SC1090
  set -a; source "$CONFIG_FILE"; set +a
  ok "Loaded config from $CONFIG_FILE"
fi

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------

ask() {  # ask VAR "Prompt" [default]
  local var="$1" prompt="$2" default="${3:-}" reply
  if [[ -n "${!var:-}" ]]; then return 0; fi
  if [[ "$NON_INTERACTIVE" == "yes" ]]; then
    [[ -n "$default" ]] || die "Missing required value '$var' (non-interactive mode)"
    printf -v "$var" '%s' "$default"; return 0
  fi
  if [[ -n "$default" ]]; then read -rp "  $prompt [$default]: " reply || true
  else                      read -rp "  $prompt: " reply || true; fi
  printf -v "$var" '%s' "${reply:-$default}"
}

# ask_secret VAR "Prompt" [generate]
#   generate=yes (default): blank input creates a strong password. Only correct
#   when this script is the thing creating the account.
#   generate=no: the credential already exists elsewhere, so a generated value
#   would be silently wrong — keep asking until we get one.
ask_secret() {
  local var="$1" prompt="$2" generate="${3:-yes}" reply
  if [[ -n "${!var:-}" ]]; then return 0; fi
  if [[ "$NON_INTERACTIVE" == "yes" ]]; then
    [[ "$generate" == "yes" ]] || die "Missing required value '$var' (non-interactive mode)"
    printf -v "$var" '%s' "$(gen_password)"; return 0
  fi
  if [[ "$generate" == "yes" ]]; then
    read -rsp "  $prompt (blank = generate one): " reply || true; echo
    printf -v "$var" '%s' "${reply:-$(gen_password)}"
  else
    while [[ -z "${reply:-}" ]]; do
      read -rsp "  $prompt: " reply || true; echo
      [[ -n "${reply:-}" ]] || warn "This database already exists, so there is nothing to generate — enter its password."
    done
    printf -v "$var" '%s' "$reply"
  fi
}

ask_yn() {  # ask_yn VAR "Prompt" [y|n]
  local var="$1" prompt="$2" default="${3:-n}"
  if [[ -z "${!var:-}" ]]; then
    if [[ "$NON_INTERACTIVE" == "yes" ]]; then
      printf -v "$var" '%s' "$default"
    else
      local reply
      local hint='y/N'; if [[ $default == y* ]]; then hint='Y/n'; fi
      read -rp "  $prompt [$hint]: " reply || true
      printf -v "$var" '%s' "${reply:-$default}"
    fi
  fi
  case "$(printf '%s' "${!var}" | tr '[:upper:]' '[:lower:]')" in
    y|yes|true|1)  printf -v "$var" 'yes' ;;
    n|no|false|0)  printf -v "$var" 'no'  ;;
    *) die "Invalid yes/no value for $var: ${!var}" ;;
  esac
}

gen_password() {  # 24 chars, alnum only (safe in .env, MySQL and shell quoting)
  local pool
  pool=$(LC_ALL=C tr -dc 'A-Za-z0-9' < <(head -c 2048 /dev/urandom))
  printf '%s' "${pool:0:24}"
}

pause() {
  [[ "$NON_INTERACTIVE" == "yes" ]] && return 0
  read -rp "  ${1:-Press Enter to continue...} " _ || true
}

# Match a regex against a command's output WITHOUT a pipeline.
#
# `cmd | grep -q PATTERN` is broken under `set -o pipefail`: grep -q exits the
# moment it matches, cmd is killed by SIGPIPE, the pipeline reports 141, and the
# test reads as "no match" precisely when there WAS one. Capture, then match.
out_matches() {  # out_matches REGEX CMD [ARGS...]
  local re="$1"; shift
  local out
  out=$("$@" 2>/dev/null) || true
  [[ "$out" =~ $re ]]
}

first_line() { local out; out=$("$@" 2>/dev/null) || true; printf '%s' "${out%%$'\n'*}"; }

apt_install() { sudo apt-get install -y -o Dpkg::Options::=--force-confold "$@" >>"$LOG_FILE" 2>&1; }

# `apt-get update` fails as a whole if any single source 404s, and a dead
# third-party PHP source would then break every apt call for the rest of the
# run. Drop it and retry rather than aborting.
apt_update() {
  if sudo apt-get update >>"$LOG_FILE" 2>&1; then return 0; fi
  if grep -rqs "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
    warn "The ondrej/php apt source has no build for this release — removing it"
    sudo add-apt-repository -y --remove ppa:ondrej/php >>"$LOG_FILE" 2>&1 || true
    sudo rm -f /etc/apt/sources.list.d/ondrej-*.list \
               /etc/apt/sources.list.d/ondrej-*.sources 2>/dev/null || true
    sudo apt-get update >>"$LOG_FILE" 2>&1 && return 0
  fi
  warn "Some apt sources failed to refresh — continuing (details in $LOG_FILE)"
  return 0
}

# Set/replace a key in a .env-style file, handling commented-out and missing keys.
set_env() {
  local key="$1" val="$2" file="$3" esc
  [[ "$val" =~ ^[A-Za-z0-9_./:@-]*$ ]] || val="\"$val\""
  esc=$(printf '%s' "$val" | sed -e 's/[\\|&]/\\&/g')
  if grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "$file"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}=.*|${key}=${esc}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >>"$file"
  fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

[[ $EUID -ne 0 ]] || die "Run this as a normal user with sudo rights, not as root."
command -v sudo >/dev/null || die "sudo is required."
[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || warn "Tested on Ubuntu; detected '${PRETTY_NAME:-unknown}'. Continuing anyway."

echo
printf '%s\n' "${C_BOLD}Laravel server provisioner${C_RESET}  —  log: $LOG_FILE"
echo

log "Checking sudo access"
# Probe with `sudo -n true` rather than `sudo -v`: on a passwordless-sudo host
# (the usual cloud-image setup, and sudo-rs on recent Ubuntu) `sudo -v` still
# prompts for a password the account may not even have.
if sudo -n true 2>/dev/null; then
  SUDO_NEEDS_PASSWORD="no"
  ok "Passwordless sudo available"
else
  SUDO_NEEDS_PASSWORD="yes"
  info "sudo wants your Linux account password — not your SSH key passphrase."
  sudo -v || die "sudo authentication failed."
  ok "sudo authenticated"
fi

# Only worth a keepalive when there is a timestamp that can expire mid-run.
if [[ "$SUDO_NEEDS_PASSWORD" == "yes" ]]; then
  ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null || true; sleep 50; done ) &
  SUDO_KEEPALIVE_PID=$!
fi
trap 'kill "${SUDO_KEEPALIVE_PID:-}" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# Gather answers
# ---------------------------------------------------------------------------

log "Configuration"
ask      PHP_VERSION       "PHP version to install (e.g. 8.2, 8.3, 8.4)" "8.4"
[[ "$PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || die "PHP version must look like 8.4"

ask      WEB_ROOT          "Web root" "/var/www/html"
ask      REPO_URL          "Git repository URL (https:// or git@)"
[[ -n "${REPO_URL:-}" ]] || die "A repository URL is required."
DEFAULT_APP_DIR=$(basename "${REPO_URL%.git}")
ask      APP_DIR_NAME      "Directory name to clone into" "$DEFAULT_APP_DIR"
ask      GIT_BRANCH        "Branch to check out (blank = default)" " "
GIT_BRANCH=$(printf '%s' "$GIT_BRANCH" | tr -d '[:space:]')

ask      GIT_USER_EMAIL    "Git user.email"
ask      GIT_USER_NAME     "Git user.name" "$(id -un)"

case "$REPO_URL" in
  git@*|ssh://*) CLONE_PROTO="ssh" ;;
  *)             CLONE_PROTO="https" ;;
esac
if [[ "$CLONE_PROTO" == "ssh" ]]; then
  GENERATE_SSH_KEY="${GENERATE_SSH_KEY:-yes}"
fi
ask_yn   GENERATE_SSH_KEY  "Generate an SSH key for GitHub/Bitbucket" "y"

ask      APP_NAME          "APP_NAME" "Laravel"
ask      APP_ENV           "APP_ENV" "production"
ask      APP_URL           "APP_URL" "http://localhost"
ask      APP_DEBUG         "APP_DEBUG" "$( [[ "$APP_ENV" == "production" ]] && echo false || echo true )"
ask_yn   EDIT_ENV_AFTER    "Open .env in an editor before finishing" "y"

ask_yn   INSTALL_MYSQL     "Install MySQL server" "y"
if [[ "$INSTALL_MYSQL" == "yes" ]]; then
  ask_secret MYSQL_ROOT_PASSWORD "MySQL root password"
  ask      DB_DATABASE     "Application database name" "${APP_DIR_NAME//[^A-Za-z0-9_]/_}"
  ask      DB_USERNAME     "Application database user" "$DB_DATABASE"
  ask_secret DB_PASSWORD   "Application database password"
  ask_yn   INSTALL_PHPMYADMIN "Install phpMyAdmin" "n"
else
  INSTALL_PHPMYADMIN="${INSTALL_PHPMYADMIN:-no}"; ask_yn INSTALL_PHPMYADMIN "Install phpMyAdmin anyway" "n"
  info "No MySQL install — these must match the database you already have."
  ask      DB_HOST_INPUT   "DB_HOST for .env" "127.0.0.1"
  ask      DB_DATABASE     "DB_DATABASE for .env" "laravel"
  ask      DB_USERNAME     "DB_USERNAME for .env" "laravel"
  ask_secret DB_PASSWORD   "DB_PASSWORD for .env" "no"
fi

ask_yn   INSTALL_NODE      "Install Node.js" "n"
[[ "$INSTALL_NODE" == "yes" ]] && ask NODE_MAJOR "Node major version" "22"

ask_yn   CREATE_SWAP       "Create a swap file" "y"
[[ "$CREATE_SWAP" == "yes" ]] && ask SWAP_SIZE_MB "Swap size in MB" "2048"

ask_yn   INSTALL_SSL       "Install a Let's Encrypt certificate" "n"
if [[ "$INSTALL_SSL" == "yes" ]]; then
  ask    SSL_DOMAINS       "Domains (comma separated, e.g. example.com,www.example.com)"
  ask    SSL_EMAIL         "Email for Let's Encrypt notices" "$GIT_USER_EMAIL"
fi

ask_yn   COMPOSER_NO_DEV   "composer install without dev dependencies" "$( [[ "$APP_ENV" == "production" ]] && echo y || echo n )"
ask_yn   RUN_MIGRATIONS    "Run php artisan migrate --force after install" "n"
ask_yn   RUN_STORAGE_LINK  "Run php artisan storage:link" "y"
ask_yn   BUILD_ASSETS      "Build front-end assets with npm if the repo has a package.json" "y"

APP_DIR="${WEB_ROOT%/}/${APP_DIR_NAME}"
PRIMARY_DOMAIN=$(printf '%s' "${SSL_DOMAINS:-}" | cut -d, -f1)
[[ -z "$PRIMARY_DOMAIN" ]] && PRIMARY_DOMAIN=$(printf '%s' "$APP_URL" | sed -E 's#^https?://##; s#/.*$##')
[[ -z "$PRIMARY_DOMAIN" ]] && PRIMARY_DOMAIN="localhost"

echo
info "PHP $PHP_VERSION · app at $APP_DIR · ServerName $PRIMARY_DOMAIN"
info "MySQL: $INSTALL_MYSQL · phpMyAdmin: $INSTALL_PHPMYADMIN · Node: $INSTALL_NODE · swap: $CREATE_SWAP · SSL: $INSTALL_SSL"
echo
pause "Press Enter to start provisioning (Ctrl-C to abort)..."

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------

log "Updating package lists"
apt_update
apt_install software-properties-common ca-certificates curl gnupg lsb-release unzip git
ok "Base packages installed"

# ---------------------------------------------------------------------------
# 2. Apache
# ---------------------------------------------------------------------------

log "Installing Apache"
apt_install apache2
sudo a2enmod rewrite headers >>"$LOG_FILE" 2>&1
ok "Apache installed, mod_rewrite enabled"

# ---------------------------------------------------------------------------
# 3. PHP
# ---------------------------------------------------------------------------

log "Installing PHP $PHP_VERSION"

# Is the requested version installable right now, from whatever sources are configured?
php_available() {
  # Log what apt actually thinks, so a failure here is diagnosable from the log.
  { echo "--- apt-cache policy php${PHP_VERSION}-cli ---"
    apt-cache policy "php${PHP_VERSION}-cli" 2>&1; } >>"$LOG_FILE"
  out_matches 'Candidate:[[:space:]]+[0-9]' apt-cache policy "php${PHP_VERSION}-cli"
}

drop_ondrej_ppa() {
  sudo add-apt-repository -y --remove ppa:ondrej/php >>"$LOG_FILE" 2>&1 || true
  sudo rm -f /etc/apt/sources.list.d/ondrej-*.list \
             /etc/apt/sources.list.d/ondrej-*.sources >>"$LOG_FILE" 2>&1 || true
}

add_ondrej_ppa() {
  info "Trying the ondrej/php PPA"
  sudo add-apt-repository -y ppa:ondrej/php >>"$LOG_FILE" 2>&1 || return 1
  # A PPA with no build for this release 404s here; that is not fatal, we just check below.
  apt_update
  php_available
}

add_sury_repo() {
  info "Trying packages.sury.org"
  apt_install apt-transport-https ca-certificates curl gnupg || return 1
  curl -fsSL https://packages.sury.org/php/apt.gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/deb.sury.org-php.gpg 2>>"$LOG_FILE" || return 1
  echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ ${PHP_REPO_CODENAME} main" \
    | sudo tee /etc/apt/sources.list.d/sury-php.list >/dev/null
  apt_update
  php_available
}

PHP_REPO_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"

if php_available; then
  ok "php${PHP_VERSION} is in the distribution repositories — no third-party repo needed"
elif add_ondrej_ppa; then
  ok "php${PHP_VERSION} available via ondrej/php"
else
  # The PPA has no build for this release (it 404s from Ubuntu 25.10 "questing"
  # onward, where upstream has moved to sury). Clear it out before trying sury,
  # or its dead source keeps breaking every later apt-get update.
  drop_ondrej_ppa
  if [[ -z "$PHP_REPO_CODENAME" ]]; then
    die "Cannot determine the release codename; add a PHP repository manually."
  fi
  if add_sury_repo; then
    ok "php${PHP_VERSION} available via packages.sury.org"
  else
    warn "php${PHP_VERSION} is not installable from the distro, ondrej/php, or sury."
    info "Versions this server can currently install:"
    apt-cache search --names-only '^php[0-9]+\.[0-9]+-cli$' 2>/dev/null \
      | sed -E 's/^php([0-9]+\.[0-9]+)-cli.*/      \1/' | sort -u || true
    die "Pick one of the versions above and re-run."
  fi
fi

PHP_PKGS=(
  "php${PHP_VERSION}"
  "php${PHP_VERSION}-cli"    "php${PHP_VERSION}-common"  "php${PHP_VERSION}-curl"
  "php${PHP_VERSION}-gd"     "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-intl"
  "php${PHP_VERSION}-mysql"  "php${PHP_VERSION}-xml"     "php${PHP_VERSION}-zip"
  "php${PHP_VERSION}-bcmath" "php${PHP_VERSION}-opcache"
  "libapache2-mod-php${PHP_VERSION}"
)
apt_install "${PHP_PKGS[@]}"

# Make the chosen version the CLI default and the only enabled Apache module.
sudo update-alternatives --set php "/usr/bin/php${PHP_VERSION}" >>"$LOG_FILE" 2>&1 || true
for mod in /etc/apache2/mods-enabled/php*.load; do
  [[ -e "$mod" ]] || continue
  m=$(basename "$mod" .load)
  [[ "$m" == "php${PHP_VERSION}" ]] || sudo a2dismod "$m" >>"$LOG_FILE" 2>&1 || true
done
sudo a2enmod "php${PHP_VERSION}" >>"$LOG_FILE" 2>&1
ok "PHP $(php -r 'echo PHP_VERSION;') active"

log "Putting index.php first in DirectoryIndex"
sudo sed -i -E 's|^(\s*)DirectoryIndex\s+.*|\1DirectoryIndex index.php index.html index.cgi index.pl index.xhtml index.htm|' \
  /etc/apache2/mods-available/dir.conf
ok "dir.conf updated"

# ---------------------------------------------------------------------------
# 4. Composer
# ---------------------------------------------------------------------------

log "Installing Composer"
if command -v composer >/dev/null; then
  sudo composer self-update >>"$LOG_FILE" 2>&1 || true
  ok "Composer already present ($(first_line composer --version))"
else
  tmp=$(mktemp -d)
  expected=$(curl -fsSL https://composer.github.io/installer.sig)
  curl -fsSL https://getcomposer.org/installer -o "$tmp/composer-setup.php"
  actual=$(php -r "echo hash_file('sha384', '$tmp/composer-setup.php');")
  [[ "$expected" == "$actual" ]] || die "Composer installer checksum mismatch — aborting."
  sudo php "$tmp/composer-setup.php" --install-dir=/usr/local/bin --filename=composer >>"$LOG_FILE" 2>&1
  rm -rf "$tmp"
  ok "Composer installed ($(first_line composer --version))"
fi

# ---------------------------------------------------------------------------
# 5. Git identity + SSH key
# ---------------------------------------------------------------------------

log "Configuring Git"
[[ -n "${GIT_USER_EMAIL:-}" ]] && git config --global user.email "$GIT_USER_EMAIL"
[[ -n "${GIT_USER_NAME:-}"  ]] && git config --global user.name  "$GIT_USER_NAME"
git config --global init.defaultBranch main
ok "Git identity set to ${GIT_USER_NAME:-?} <${GIT_USER_EMAIL:-?}>"

SSH_KEY="$HOME/.ssh/id_ed25519"
if [[ "$GENERATE_SSH_KEY" == "yes" ]]; then
  log "SSH key"
  if [[ -f "$SSH_KEY" ]]; then
    ok "Existing key found at $SSH_KEY"
  else
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -C "${GIT_USER_EMAIL:-$(id -un)@$(hostname)}" -f "$SSH_KEY" -N "" >>"$LOG_FILE" 2>&1
    ok "Generated $SSH_KEY"
  fi
  echo
  printf '%s\n' "${C_BOLD}────────── PUBLIC KEY — add this to GitHub/Bitbucket ──────────${C_RESET}"
  cat "${SSH_KEY}.pub"
  printf '%s\n' "${C_BOLD}───────────────────────────────────────────────────────────────${C_RESET}"
  info "GitHub: Settings → SSH and GPG keys → New SSH key"
  echo
  ssh-keyscan -H github.com bitbucket.org gitlab.com >>"$HOME/.ssh/known_hosts" 2>/dev/null || true
  sort -u -o "$HOME/.ssh/known_hosts" "$HOME/.ssh/known_hosts" 2>/dev/null || true
  [[ "$CLONE_PROTO" == "ssh" ]] && pause "Press Enter once the key is added to your Git host..."
fi

# ---------------------------------------------------------------------------
# 6. MySQL
# ---------------------------------------------------------------------------

if [[ "$INSTALL_MYSQL" == "yes" ]]; then
  log "Installing MySQL"
  apt_install mysql-server
  sudo systemctl enable --now mysql >>"$LOG_FILE" 2>&1

  # mysql_native_password is gone in MySQL 8.4+ — pick whatever this server supports.
  AUTH_PLUGIN="caching_sha2_password"
  if out_matches '1' sudo mysql -N -B -e \
      "SELECT 1 FROM information_schema.PLUGINS WHERE PLUGIN_NAME='mysql_native_password' AND PLUGIN_STATUS='ACTIVE'"; then
    AUTH_PLUGIN="mysql_native_password"
  fi

  sudo mysql <<SQL >>"$LOG_FILE" 2>&1
ALTER USER 'root'@'localhost' IDENTIFIED WITH ${AUTH_PLUGIN} BY '${MYSQL_ROOT_PASSWORD}';
CREATE DATABASE IF NOT EXISTS \`${DB_DATABASE}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USERNAME}'@'localhost' IDENTIFIED WITH ${AUTH_PLUGIN} BY '${DB_PASSWORD}';
ALTER USER '${DB_USERNAME}'@'localhost' IDENTIFIED WITH ${AUTH_PLUGIN} BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_DATABASE}\`.* TO '${DB_USERNAME}'@'localhost';
FLUSH PRIVILEGES;
SQL
  ok "MySQL ready — root auth: $AUTH_PLUGIN, database: $DB_DATABASE, user: $DB_USERNAME"
fi

if [[ "$INSTALL_PHPMYADMIN" == "yes" ]]; then
  log "Installing phpMyAdmin"
  sudo debconf-set-selections <<'SEL'
phpmyadmin phpmyadmin/dbconfig-install boolean false
phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2
SEL
  apt_install phpmyadmin
  if ! grep -q "phpmyadmin/apache.conf" /etc/apache2/apache2.conf; then
    echo "Include /etc/phpmyadmin/apache.conf" | sudo tee -a /etc/apache2/apache2.conf >>"$LOG_FILE"
  fi
  ok "phpMyAdmin installed at /phpmyadmin"
  warn "phpMyAdmin is publicly reachable — consider restricting it by IP or basic auth."
fi

# ---------------------------------------------------------------------------
# 7. Node.js
# ---------------------------------------------------------------------------

install_node() {
  log "Installing Node.js ${NODE_MAJOR}.x"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash - >>"$LOG_FILE" 2>&1
  apt_install nodejs
  ok "Node $(node -v), npm $(npm -v)"
}

if [[ "$INSTALL_NODE" == "yes" ]]; then
  install_node
fi

# ---------------------------------------------------------------------------
# 8. Swap
# ---------------------------------------------------------------------------

if [[ "$CREATE_SWAP" == "yes" ]]; then
  log "Configuring swap (${SWAP_SIZE_MB}MB)"
  if out_matches '/swapfile' swapon --show; then
    ok "Swap already active"
  else
    sudo fallocate -l "${SWAP_SIZE_MB}M" /swapfile 2>>"$LOG_FILE" \
      || sudo dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_SIZE_MB" >>"$LOG_FILE" 2>&1
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile >>"$LOG_FILE" 2>&1
    sudo swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >>"$LOG_FILE"
    ok "Swap active and persisted in /etc/fstab"
  fi
fi

# ---------------------------------------------------------------------------
# 9. Clone the application
# ---------------------------------------------------------------------------

log "Cloning application"
sudo mkdir -p "$WEB_ROOT"
sudo chown -R "$USER":"$USER" "$WEB_ROOT"

if [[ -d "$APP_DIR/.git" ]]; then
  ok "Repo already present at $APP_DIR — pulling latest"
  git -C "$APP_DIR" pull --ff-only >>"$LOG_FILE" 2>&1 || warn "git pull failed; leaving the working tree as-is"
else
  if [[ -n "$GIT_BRANCH" ]]; then
    git clone --branch "$GIT_BRANCH" "$REPO_URL" "$APP_DIR" >>"$LOG_FILE" 2>&1
  else
    git clone "$REPO_URL" "$APP_DIR" >>"$LOG_FILE" 2>&1
  fi
  ok "Cloned into $APP_DIR"
fi
cd "$APP_DIR"

# ---------------------------------------------------------------------------
# 10. .env
# ---------------------------------------------------------------------------

log "Writing .env"
if [[ ! -f .env ]]; then
  [[ -f .env.example ]] || die "No .env or .env.example in the repo — cannot continue."
  cp .env.example .env
  ok "Created .env from .env.example"
else
  cp .env ".env.backup-$(date +%s)"
  ok "Existing .env found — backed up before editing"
fi

set_env APP_NAME    "$APP_NAME"    .env
set_env APP_ENV     "$APP_ENV"     .env
set_env APP_DEBUG   "$APP_DEBUG"   .env
set_env APP_URL     "$APP_URL"     .env
set_env DB_CONNECTION "mysql"      .env
set_env DB_HOST     "${DB_HOST_INPUT:-127.0.0.1}" .env
set_env DB_PORT     "3306"         .env
set_env DB_DATABASE "$DB_DATABASE" .env
set_env DB_USERNAME "$DB_USERNAME" .env
set_env DB_PASSWORD "$DB_PASSWORD" .env
ok "Application and database values written"

# ---------------------------------------------------------------------------
# 11. PHP extensions this particular app needs
# ---------------------------------------------------------------------------

# A fixed extension list can never match every app, so read the ext-* requirements
# out of composer.json and composer.lock (transitive deps included — pdo_sqlite
# typically arrives via a package you never named) and install what is missing.
log "Checking PHP extensions required by the app"

# required_extensions [include_dev]
# Dev requirements are excluded by default — otherwise a package's require-dev
# on ext-xdebug would install a profiler onto a production box.
required_extensions() {
  INCLUDE_DEV="${1:-no}" php -r '
    $dev  = getenv("INCLUDE_DEV") === "yes";
    $keys = $dev ? ["require", "require-dev"] : ["require"];
    $sets = $dev ? ["packages", "packages-dev"] : ["packages"];
    $exts = [];
    foreach (["composer.json", "composer.lock"] as $f) {
      if (!is_file($f)) continue;
      $j = json_decode((string) file_get_contents($f), true);
      if (!is_array($j)) continue;
      $blocks = [];
      foreach ($keys as $k)
        if (!empty($j[$k]) && is_array($j[$k])) $blocks[] = $j[$k];
      foreach ($sets as $k)
        if (!empty($j[$k]) && is_array($j[$k]))
          foreach ($j[$k] as $p)
            foreach ($keys as $rk)
              if (!empty($p[$rk]) && is_array($p[$rk])) $blocks[] = $p[$rk];
      foreach ($blocks as $b)
        foreach (array_keys($b) as $name)
          if (stripos($name, "ext-") === 0) $exts[strtolower(substr($name, 4))] = true;
    }
    // One per line WITH a trailing newline: without it `read` drops the last entry.
    foreach (array_keys($exts) as $e) echo $e, "\n";
  ' 2>/dev/null
}

# Map a PHP extension name to the apt package that ships it. Returning 1 means
# "compiled in or part of the base package" — nothing to install.
apt_pkg_for_ext() {
  case "$1" in
    core|standard|spl|date|json|ctype|tokenizer|fileinfo|filter|hash|pcre|random|reflection|session|pdo) return 1 ;;
    openssl|zlib|libxml|iconv|phar|pcntl|posix|sodium|calendar|exif|ffi|ftp|gettext|shmop|sockets|sysvmsg|sysvsem|sysvshm) return 1 ;;
    pdo_sqlite|sqlite|sqlite3)          echo "php${PHP_VERSION}-sqlite3" ;;
    pdo_mysql|mysqli|mysqlnd)           echo "php${PHP_VERSION}-mysql" ;;
    pdo_pgsql|pgsql)                    echo "php${PHP_VERSION}-pgsql" ;;
    dom|simplexml|xml|xmlreader|xmlwriter|xsl) echo "php${PHP_VERSION}-xml" ;;
    *)                                  echo "php${PHP_VERSION}-$1" ;;
  esac
}

MISSING_EXT_PKGS=()
UNAVAILABLE_EXTS=()
while read -r ext || [[ -n "$ext" ]]; do
  [[ -n "$ext" ]] || continue
  php -r "exit(extension_loaded('$ext') ? 0 : 1);" 2>/dev/null && continue
  pkg=$(apt_pkg_for_ext "$ext") || continue
  if out_matches 'Candidate:[[:space:]]+[0-9]' apt-cache policy "$pkg"; then
    MISSING_EXT_PKGS+=("$pkg")
  else
    UNAVAILABLE_EXTS+=("$ext")
  fi
done < <(required_extensions "$( [[ "$COMPOSER_NO_DEV" == "yes" ]] && echo no || echo yes )")

if [[ ${#MISSING_EXT_PKGS[@]} -gt 0 ]]; then
  # shellcheck disable=SC2207
  MISSING_EXT_PKGS=($(printf '%s\n' "${MISSING_EXT_PKGS[@]}" | sort -u))
  info "Installing: ${MISSING_EXT_PKGS[*]}"
  apt_install "${MISSING_EXT_PKGS[@]}"
  ok "Extensions installed"
else
  ok "All required extensions already present"
fi
[[ ${#UNAVAILABLE_EXTS[@]} -eq 0 ]] || \
  warn "No apt package found for: ${UNAVAILABLE_EXTS[*]} — composer may refuse to install"

# ---------------------------------------------------------------------------
# 12. Composer install + Laravel bootstrap
# ---------------------------------------------------------------------------

log "Installing PHP dependencies"
COMPOSER_ARGS=(install --no-interaction --prefer-dist)
[[ "$COMPOSER_NO_DEV" == "yes" ]] && COMPOSER_ARGS+=(--no-dev --optimize-autoloader)
COMPOSER_ALLOW_SUPERUSER=0 composer "${COMPOSER_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE" | tail -5

if ! grep -qE '^APP_KEY=.+' .env; then
  php artisan key:generate --force >>"$LOG_FILE" 2>&1
  ok "APP_KEY generated"
fi

# --- Front-end assets ------------------------------------------------------
# A Laravel app with a package.json almost certainly builds its CSS/JS with Vite
# or Mix. Skipping this leaves no public/build/manifest.json, and every page dies
# with "Unable to locate file in Vite manifest" — a broken deploy that looks like
# a PHP problem. Runs before the permissions pass so public/build is covered.

if [[ "$BUILD_ASSETS" == "yes" && -f package.json ]]; then
  if ! command -v npm >/dev/null 2>&1; then
    info "package.json found but Node is not installed — installing it to build assets"
    install_node
  fi

  log "Building front-end assets"
  if [[ -f package-lock.json ]]; then
    npm ci 2>&1 | tee -a "$LOG_FILE" | tail -3
  else
    npm install 2>&1 | tee -a "$LOG_FILE" | tail -3
  fi
  ok "npm dependencies installed"

  npm_script_exists() {
    php -r '
      $j = json_decode((string) file_get_contents("package.json"), true);
      exit(!empty($j["scripts"][$argv[1]]) ? 0 : 1);
    ' "$1" 2>/dev/null
  }

  NPM_BUILD_SCRIPT=""
  for s in build production prod; do
    if npm_script_exists "$s"; then NPM_BUILD_SCRIPT="$s"; break; fi
  done

  if [[ -n "$NPM_BUILD_SCRIPT" ]]; then
    npm run "$NPM_BUILD_SCRIPT" 2>&1 | tee -a "$LOG_FILE" | tail -5
    ok "Assets built (npm run $NPM_BUILD_SCRIPT)"
  else
    warn "No build/production/prod script in package.json — nothing to build"
  fi
elif [[ -f package.json ]]; then
  warn "package.json found but BUILD_ASSETS=no — remember to build assets yourself"
fi

log "Setting permissions"
sudo usermod -aG www-data "$USER"
sudo chown -R "$USER":www-data "$APP_DIR"
sudo chmod -R 775 storage bootstrap/cache
# setgid so files Apache and you create later keep the www-data group
sudo find storage bootstrap/cache -type d -exec chmod g+s {} \;
chmod +x artisan
ok "storage/ and bootstrap/cache are group-writable by www-data (775, not 777)"
info "You were added to the www-data group — log out and back in for that to apply to new shells."

[[ "$RUN_STORAGE_LINK" == "yes" ]] && { php artisan storage:link >>"$LOG_FILE" 2>&1 || warn "storage:link failed"; ok "storage:link done"; }
if [[ "$RUN_MIGRATIONS" == "yes" ]]; then
  php artisan migrate --force >>"$LOG_FILE" 2>&1 && ok "Migrations run" || warn "Migrations failed — check $LOG_FILE"
fi

# ---------------------------------------------------------------------------
# 12. Apache virtual host
# ---------------------------------------------------------------------------

log "Configuring the virtual host"
VHOST="/etc/apache2/sites-available/${APP_DIR_NAME}.conf"
SERVER_ALIASES=""
if [[ -n "${SSL_DOMAINS:-}" ]]; then
  for d in ${SSL_DOMAINS//,/ }; do
    if [[ "$d" == "$PRIMARY_DOMAIN" || "$d" == \** ]]; then continue; fi
    SERVER_ALIASES+=" $d"
  done
fi
ALIAS_LINE=""
if [[ -n "$SERVER_ALIASES" ]]; then ALIAS_LINE="    ServerAlias${SERVER_ALIASES}"; fi

sudo tee "$VHOST" >/dev/null <<VHOSTCONF
<VirtualHost *:80>
    ServerName ${PRIMARY_DOMAIN}
${ALIAS_LINE}
    DocumentRoot ${APP_DIR}/public

    <Directory ${APP_DIR}/public>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog  \${APACHE_LOG_DIR}/${APP_DIR_NAME}-error.log
    CustomLog \${APACHE_LOG_DIR}/${APP_DIR_NAME}-access.log combined
</VirtualHost>
VHOSTCONF

sudo a2ensite "${APP_DIR_NAME}.conf" >>"$LOG_FILE" 2>&1
sudo a2dissite 000-default.conf >>"$LOG_FILE" 2>&1 || true
sudo apache2ctl configtest >>"$LOG_FILE" 2>&1 || die "Apache config test failed — see $LOG_FILE"
sudo systemctl restart apache2
ok "Serving ${APP_DIR}/public as $PRIMARY_DOMAIN"

# ---------------------------------------------------------------------------
# 13. TLS
# ---------------------------------------------------------------------------

if [[ "$INSTALL_SSL" == "yes" ]]; then
  log "Installing certbot"
  sudo snap install core >>"$LOG_FILE" 2>&1 || true
  sudo snap refresh core >>"$LOG_FILE" 2>&1 || true
  sudo snap install --classic certbot >>"$LOG_FILE" 2>&1
  sudo ln -sf /snap/bin/certbot /usr/bin/certbot
  ok "certbot installed"

  CERT_ARGS=()
  for d in ${SSL_DOMAINS//,/ }; do CERT_ARGS+=(-d "$d"); done

  if [[ "$SSL_DOMAINS" == *"*"* ]]; then
    warn "Wildcard domain detected — certbot needs a DNS TXT record; this step is interactive."
    sudo certbot certonly \
      --server https://acme-v02.api.letsencrypt.org/directory \
      --manual --preferred-challenges dns \
      -m "$SSL_EMAIL" --agree-tos "${CERT_ARGS[@]}"
    info "Point SSLCertificateFile in your vhost at /etc/letsencrypt/live/${PRIMARY_DOMAIN}/"
  else
    sudo certbot --apache --non-interactive --agree-tos --redirect \
      -m "$SSL_EMAIL" "${CERT_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE" | tail -5
    sudo certbot renew --dry-run >>"$LOG_FILE" 2>&1 \
      && ok "Certificate installed; auto-renewal dry run passed" \
      || warn "Renewal dry run failed — check $LOG_FILE"
  fi
fi

# ---------------------------------------------------------------------------
# 14. Final review + summary
# ---------------------------------------------------------------------------

if [[ "$EDIT_ENV_AFTER" == "yes" && "$NON_INTERACTIVE" != "yes" ]]; then
  log "Opening .env for a final review"
  "${EDITOR:-vi}" "$APP_DIR/.env"
  php artisan config:clear >>"$LOG_FILE" 2>&1 || true
fi

if [[ "$APP_ENV" == "production" ]]; then
  php artisan config:cache >>"$LOG_FILE" 2>&1 || true
  php artisan route:cache  >>"$LOG_FILE" 2>&1 || true
  php artisan view:cache   >>"$LOG_FILE" 2>&1 || true
  ok "Production caches warmed"
fi

echo
printf '%s\n' "${C_GREEN}${C_BOLD}Done.${C_RESET}"
echo
printf '  %-22s %s\n' "App directory:"  "$APP_DIR"
printf '  %-22s %s\n' "Document root:"  "$APP_DIR/public"
printf '  %-22s %s\n' "PHP:"            "$(php -r 'echo PHP_VERSION;')"
printf '  %-22s %s\n' "URL:"            "$APP_URL"
printf '  %-22s %s\n' "Vhost:"          "$VHOST"
if [[ "$INSTALL_MYSQL" == "yes" ]]; then
  printf '  %-22s %s\n' "MySQL root pass:" "$MYSQL_ROOT_PASSWORD"
  printf '  %-22s %s\n' "DB / user / pass:" "$DB_DATABASE / $DB_USERNAME / $DB_PASSWORD"
fi
[[ "$GENERATE_SSH_KEY" == "yes" ]] && printf '  %-22s %s\n' "SSH public key:" "${SSH_KEY}.pub"
printf '  %-22s %s\n' "Log:"            "$LOG_FILE"
echo
warn "Save the passwords above now — they are only printed once."
echo
