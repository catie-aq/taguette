#!/usr/bin/env bash
# Create secrets and config on the REMOTE server (safe to re-run: skips existing files)
# Usage: ./scripts/setup_secrets.sh
set -euo pipefail

REMOTE_HOST="vps"
REMOTE_DIR="~/repos/taguette"

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

step() { echo -e "\n${BOLD}==> $1${RESET}"; }
ok()   { echo -e "${GREEN}    ✓ $1${RESET}"; }
skip() { echo -e "${YELLOW}    ~ $1 (already exists, skipped)${RESET}"; }
ask()  { echo -e "${CYAN}    ? $1${RESET}"; }

# ---------------------------------------------------------------------------
# Gather info interactively
# ---------------------------------------------------------------------------
step "Remote secrets setup for ${REMOTE_HOST}:${REMOTE_DIR}"

ask "Public domain (Cloudflare Tunnel hostname, e.g. taguette.example.com):"
read -r DOMAIN

ask "App name shown in the UI [Taguette]:"
read -r APP_NAME
APP_NAME="${APP_NAME:-Taguette}"

ask "Enable public registration? (y/N):"
read -r REG
REGISTRATION="False"
if [[ "$REG" =~ ^[Yy]$ ]]; then REGISTRATION="True"; fi

# ---------------------------------------------------------------------------
# Generate secrets locally
# ---------------------------------------------------------------------------
step "Generating secrets"
PG_PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
SECRET_KEY=$(python3 -c "import secrets, base64; print(base64.b64encode(secrets.token_bytes(30)).decode())")
ok "Generated postgres password and SECRET_KEY"

# ---------------------------------------------------------------------------
# Create files on remote
# Pass all variables as env vars to avoid heredoc quoting issues
# ---------------------------------------------------------------------------
step "Creating files on ${REMOTE_HOST}"

ssh "$REMOTE_HOST" \
    PG_PASSWORD="$PG_PASSWORD" \
    SECRET_KEY="$SECRET_KEY" \
    DOMAIN="$DOMAIN" \
    APP_NAME="$APP_NAME" \
    REGISTRATION="$REGISTRATION" \
    REMOTE_DIR="$REMOTE_DIR" \
    bash <<'SSHEOF'
set -euo pipefail
mkdir -p "${REMOTE_DIR}/secrets" "${REMOTE_DIR}/config"

# --- Postgres password ---
if [ ! -f "${REMOTE_DIR}/secrets/postgres_password.txt" ]; then
    printf '%s' "$PG_PASSWORD" > "${REMOTE_DIR}/secrets/postgres_password.txt"
    chmod 600 "${REMOTE_DIR}/secrets/postgres_password.txt"
    echo "  created: secrets/postgres_password.txt"
else
    echo "  skipped: secrets/postgres_password.txt (already exists)"
fi

# --- .env ---
if [ ! -f "${REMOTE_DIR}/.env" ]; then
    printf 'SECRET_KEY=%s\n' "$SECRET_KEY" > "${REMOTE_DIR}/.env"
    chmod 600 "${REMOTE_DIR}/.env"
    echo "  created: .env"
else
    echo "  skipped: .env (already exists)"
fi

# --- config.py ---
if [ ! -f "${REMOTE_DIR}/config/config.py" ]; then
    cat > "${REMOTE_DIR}/config/config.py" <<CFGEOF
import os

NAME = "${APP_NAME}"
BIND_ADDRESS = "0.0.0.0"
PORT = 7465
BASE_PATH = "/"
DOMAIN = "${DOMAIN}"

SECRET_KEY = os.environ["SECRET_KEY"]

DATABASE = "postgresql://taguette:{pwd}@postgres/taguette".format(
    pwd=open("/run/secrets/postgres_password").read().strip()
)

EMAIL = "Taguette <noreply@${DOMAIN}>"
MAIL_SERVER = {
    "ssl": False,
    "host": "localhost",
    "port": 25,
}

TOS_FILE = None
X_HEADERS = True           # Behind Cloudflare Tunnel
COOKIES_PROMPT = False
REGISTRATION_ENABLED = ${REGISTRATION}
SQLITE3_IMPORT_ENABLED = True
DEFAULT_LANGUAGE = "en_US"
CONVERT_TO_HTML_TIMEOUT = 3 * 60
CONVERT_FROM_HTML_TIMEOUT = 3 * 60
CFGEOF
    echo "  created: config/config.py"
else
    echo "  skipped: config/config.py (already exists)"
fi
SSHEOF

ok "Done"
echo ""
echo "  Postgres password : ${PG_PASSWORD}"
echo "  SECRET_KEY        : ${SECRET_KEY}"
echo ""
echo "  Save these somewhere safe — they won't be shown again."
echo "  Next step: ./scripts/deploy.sh"
