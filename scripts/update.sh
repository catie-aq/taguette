#!/usr/bin/env bash
# Update Taguette on the VPS: pull latest code, migrate DB, restart service.
# Run from your LOCAL machine: ./scripts/update.sh
# Or run directly ON the server: bash scripts/update.sh --local
set -euo pipefail

REMOTE_HOST="vps"
REMOTE_DIR="~/repos/taguette"

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

step() { echo -e "\n${BOLD}==> $1${RESET}"; }
ok()   { echo -e "${GREEN}    ✓ $1${RESET}"; }
warn() { echo -e "${YELLOW}    ! $1${RESET}"; }

LOCAL=0
if [[ "${1:-}" == "--local" ]]; then
    LOCAL=1
fi

run() {
    if [[ "$LOCAL" -eq 1 ]]; then
        bash -c "$1"
    else
        ssh "$REMOTE_HOST" bash <<EOF
set -euo pipefail
cd ${REMOTE_DIR}
$1
EOF
    fi
}

# ---------------------------------------------------------------------------
# 1. Push local changes to GitHub (only when running from local machine)
# ---------------------------------------------------------------------------
if [[ "$LOCAL" -eq 0 ]]; then
    step "Pushing local changes to GitHub"
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    git push origin "${CURRENT_BRANCH}"
    ok "Pushed ${CURRENT_BRANCH}"
fi

# ---------------------------------------------------------------------------
# 2. Pull latest code on server
# ---------------------------------------------------------------------------
step "Pulling latest code"
run "git pull origin \$(git rev-parse --abbrev-ref HEAD)"
ok "Code up to date"

# ---------------------------------------------------------------------------
# 3. Rebuild Docker image
# ---------------------------------------------------------------------------
step "Building Docker image"
run "docker compose build --quiet taguette"
ok "Image built"

# ---------------------------------------------------------------------------
# 4. Run DB migration (before restarting the app)
# ---------------------------------------------------------------------------
step "Running database migration"
run "docker compose run --rm \
    -e SECRET_KEY=\$(grep SECRET_KEY .env | cut -d= -f2- | tr -d '\"' | tr -d \"'\") \
    taguette migrate /config/config.py 2>&1 | tail -5 || true"
ok "Migration done (or already up to date)"

# ---------------------------------------------------------------------------
# 5. Restart service
# ---------------------------------------------------------------------------
step "Restarting service"
run "docker compose up -d --remove-orphans taguette"
ok "Service restarted"

# ---------------------------------------------------------------------------
# 6. Health check
# ---------------------------------------------------------------------------
step "Waiting for service to be ready"
run "
for i in \$(seq 1 15); do
    if docker compose exec -T taguette true 2>/dev/null; then
        STATUS=\$(docker compose ps --format json taguette 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[\"State\"])' 2>/dev/null || echo unknown)
        if [[ \"\$STATUS\" == \"running\" ]]; then
            echo \"    Service is running\"
            break
        fi
    fi
    echo \"    Waiting... (\$i/15)\"
    sleep 2
done
docker compose ps taguette
"
ok "Done"

echo -e "\n${GREEN}${BOLD}Update complete!${RESET}"
