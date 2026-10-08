#!/usr/bin/env bash
#
# setup-github-cicd.sh — one-time GitHub Actions CI/CD setup for a project.
#
# Run this on YOUR computer (not the server). It will:
#   1. Create (or reuse) a dedicated, passphrase-less SSH deploy key for the project
#   2. Authorize that key on the server and verify it can log in
#   3. Create the GitHub environment (e.g. Production) if it doesn't exist
#   4. Store DEPLOY_HOST / DEPLOY_USER / DEPLOY_KEY (and optionally DEPLOY_PORT)
#      as GitHub secrets, plus any extra secrets you enter
#
# Requirements: gh (logged in, with admin access to the repo), ssh, ssh-keygen
#
# Usage:
#   ./setup-github-cicd.sh             # interactive
#   ./setup-github-cicd.sh --dry-run   # prompts, then only prints what it would do
#
set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# ── helpers ──────────────────────────────────────────────────────────────────
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
run()  { if ((DRY_RUN)); then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

ask() { # ask "Prompt" "default" -> echoes answer
  local reply
  read -r -p "$1${2:+ [$2]}: " reply
  echo "${reply:-$2}"
}

ask_required() {
  local value=""
  while [[ -z "$value" ]]; do
    value="$(ask "$1" "${2:-}")"
    [[ -z "$value" ]] && warn "This value is required." >&2
  done
  echo "$value"
}

confirm() { # confirm "Question" "Y|N"
  local default="${2:-Y}" reply hint="[Y/n]"
  [[ "$default" == "N" ]] && hint="[y/N]"
  read -r -p "$1 $hint: " reply
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy] ]]
}

# ── preflight ────────────────────────────────────────────────────────────────
for cmd in gh ssh ssh-keygen; do
  command -v "$cmd" >/dev/null || die "'$cmd' is not installed."
done
gh auth status >/dev/null 2>&1 || die "gh is not logged in. Run: gh auth login"

bold "GitHub Actions CI/CD setup"
((DRY_RUN)) && warn "DRY RUN — nothing will be created, copied or uploaded."
echo

# ── project values ───────────────────────────────────────────────────────────
DEFAULT_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
REPO="$(ask_required "GitHub repository (owner/name)" "$DEFAULT_REPO")"
gh repo view "$REPO" >/dev/null 2>&1 || die "Cannot access '$REPO' with the current gh login."

ENV_NAME="$(ask "GitHub environment for the secrets (blank = repository-level secrets)" "Production")"
HOST="$(ask_required "Server host or IP")"
PORT="$(ask "SSH port" "22")"
DEPLOY_USER="$(ask "SSH user" "deploy")"

if [[ "$DEPLOY_USER" == "root" ]]; then
  echo
  warn "You chose root. Think twice:"
  echo "  - Anyone who gets this GitHub secret gets full control of the whole server."
  echo "  - Deploy commands (composer, artisan) will create root-owned files in storage/ and"
  echo "    bootstrap/cache, which the web server user can't write, so the site can start erroring."
  echo "  - Safer: create a 'deploy' user first (laravel-deploy.sh in this folder does that)."
  confirm "Continue with root anyway?" "N" || die "Aborted. Re-run with a non-root user."
fi

DEFAULT_KEY_NAME="$(basename "$REPO")-deploy-ci"
KEY_NAME="$(ask "Deploy key name (stored in ~/.ssh)" "$DEFAULT_KEY_NAME")"
KEY_PATH="$HOME/.ssh/$KEY_NAME"

ENV_ARGS=()
[[ -n "$ENV_NAME" ]] && ENV_ARGS=(--env "$ENV_NAME")

echo
bold "Summary"
echo "  Repo:        $REPO"
echo "  Secrets in:  ${ENV_NAME:-repository-level}"
echo "  Server:      $DEPLOY_USER@$HOST:$PORT"
echo "  Key file:    $KEY_PATH"
echo
confirm "Continue?" "Y" || die "Aborted."

# ── 1. environment ───────────────────────────────────────────────────────────
if [[ -n "$ENV_NAME" ]]; then
  if ((DRY_RUN)); then
    echo "  [dry-run] create GitHub environment '$ENV_NAME' on $REPO"
  elif gh api --method PUT "repos/$REPO/environments/$ENV_NAME" >/dev/null 2>&1; then
    ok "Environment '$ENV_NAME' ready"
  else
    warn "Could not create environment '$ENV_NAME' (private repos need a paid plan for environments)."
    confirm "Use repository-level secrets instead?" "Y" || die "Aborted."
    ENV_NAME=""
    ENV_ARGS=()
  fi
fi

# ── 2. SSH key ───────────────────────────────────────────────────────────────
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
if [[ -f "$KEY_PATH" ]]; then
  ok "Reusing existing key $KEY_PATH"
else
  run ssh-keygen -t ed25519 -C "github-actions-$(basename "$REPO")" -f "$KEY_PATH" -N "" -q
  ((DRY_RUN)) || ok "Created key $KEY_PATH"
fi

# ── 3. authorize on server + verify ──────────────────────────────────────────
SSH_OPTS=(-i "$KEY_PATH" -p "$PORT" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

if ((DRY_RUN)); then
  echo "  [dry-run] ssh-copy-id -i $KEY_PATH.pub -p $PORT $DEPLOY_USER@$HOST"
  echo "  [dry-run] test login with the new key"
else
  if ssh "${SSH_OPTS[@]}" "$DEPLOY_USER@$HOST" true 2>/dev/null; then
    ok "Key already authorized on the server"
  else
    echo
    echo "The key isn't authorized on $HOST yet. ssh-copy-id will use your existing"
    echo "access (password or another key) to add it."
    if confirm "Authorize the key on the server now?" "Y"; then
      ssh-copy-id -i "$KEY_PATH.pub" -p "$PORT" -o StrictHostKeyChecking=accept-new "$DEPLOY_USER@$HOST" \
        || warn "ssh-copy-id failed."
    fi
    if ssh "${SSH_OPTS[@]}" "$DEPLOY_USER@$HOST" true 2>/dev/null; then
      ok "Key login verified"
    else
      warn "Login with the new key does NOT work yet."
      echo "  Add this public key to ~$DEPLOY_USER/.ssh/authorized_keys on the server:"
      echo "  $(cat "$KEY_PATH.pub")"
      confirm "Set the GitHub secrets anyway?" "N" || die "Stopped before touching GitHub secrets."
    fi
  fi
fi

# ── 4. secrets ───────────────────────────────────────────────────────────────
set_secret() { # set_secret NAME  (value on stdin)
  local name="$1"
  if ((DRY_RUN)); then
    echo "  [dry-run] gh secret set $name --repo $REPO ${ENV_ARGS[*]:-}"
    cat >/dev/null
  else
    gh secret set "$name" --repo "$REPO" ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} >/dev/null && ok "Set $name"
  fi
}

echo
bold "Setting secrets"
EXISTING="$(gh secret list --repo "$REPO" ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} 2>/dev/null | awk '{print $1}' | tr '\n' ' ' || true)"
[[ -n "${EXISTING// /}" ]] && warn "Already present (will be overwritten if re-set): $EXISTING"

printf '%s' "$HOST"        | set_secret DEPLOY_HOST
printf '%s' "$DEPLOY_USER" | set_secret DEPLOY_USER
if ((DRY_RUN)); then
  echo "  [dry-run] gh secret set DEPLOY_KEY < $KEY_PATH"
else
  set_secret DEPLOY_KEY < "$KEY_PATH"
fi
if [[ "$PORT" != "22" ]]; then
  printf '%s' "$PORT" | set_secret DEPLOY_PORT
  warn "Your workflow must pass it to the SSH action: port: \${{ secrets.DEPLOY_PORT }}"
fi

# ── extra project secrets ────────────────────────────────────────────────────
echo
echo "Add any other secrets this project's workflows need (e.g. API tokens)."
echo "Values are typed hidden. Leave the name blank to finish."
while true; do
  read -r -p "Secret name: " NAME
  [[ -z "$NAME" ]] && break
  [[ "$NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { warn "Use letters, digits and underscores only."; continue; }
  read -r -s -p "Value for $NAME: " VALUE; echo
  [[ -z "$VALUE" ]] && { warn "Empty value, skipped."; continue; }
  printf '%s' "$VALUE" | set_secret "$NAME"
  unset VALUE
done

# ── done ─────────────────────────────────────────────────────────────────────
echo
bold "Done"
echo "  Verify:   gh secret list --repo $REPO ${ENV_ARGS[*]:-}"
echo "  Next:     re-run the failed workflow from the Actions tab, or push a commit."
echo "  Keep:     $KEY_PATH is the private key. Never commit or share it."
