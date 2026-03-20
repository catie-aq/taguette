#!/usr/bin/env bash
# Deploy Taguette to VPS
# Usage: ./scripts/deploy.sh
set -euo pipefail

REMOTE_HOST="vps"
REMOTE_DIR="~/repos/taguette"
GITHUB_REMOTE="git@github.com:catie-aq/taguette.git"

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

step() { echo -e "\n${BOLD}==> $1${RESET}"; }
ok()   { echo -e "${GREEN}    ✓ $1${RESET}"; }
warn() { echo -e "${YELLOW}    ! $1${RESET}"; }

# ---------------------------------------------------------------------------
# 1. Local git setup
# ---------------------------------------------------------------------------
step "Setting up local git remotes"

CURRENT_ORIGIN=$(git remote get-url origin 2>/dev/null || echo "")
if [ "$CURRENT_ORIGIN" != "$GITHUB_REMOTE" ]; then
    warn "Renaming current 'origin' to 'upstream' (upstream = GitLab)"
    git remote rename origin upstream 2>/dev/null || true
    git remote add origin "$GITHUB_REMOTE"
    ok "origin set to $GITHUB_REMOTE"
else
    ok "origin already points to $GITHUB_REMOTE"
fi

# Ensure upstream still points to GitLab
if ! git remote get-url upstream &>/dev/null; then
    git remote add upstream "https://gitlab.com/remram44/taguette.git"
    ok "upstream set to GitLab"
fi

# Set default tracking branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
git branch --set-upstream-to="origin/${CURRENT_BRANCH}" "${CURRENT_BRANCH}" 2>/dev/null || true
ok "Tracking branch: origin/${CURRENT_BRANCH}"

# ---------------------------------------------------------------------------
# 2. Push to GitHub
# ---------------------------------------------------------------------------
step "Pushing to GitHub (origin)"
git push origin "${CURRENT_BRANCH}"
ok "Pushed ${CURRENT_BRANCH}"

# ---------------------------------------------------------------------------
# 3. Prepare remote directory
# ---------------------------------------------------------------------------
step "Preparing remote directory on ${REMOTE_HOST}"
ssh "$REMOTE_HOST" "mkdir -p ${REMOTE_DIR}"
ok "Directory ready: ${REMOTE_DIR}"

# ---------------------------------------------------------------------------
# 4. Rsync source (excluding secrets, cache, git internals)
# ---------------------------------------------------------------------------
step "Syncing files to ${REMOTE_HOST}:${REMOTE_DIR}"
rsync -az --delete \
    --exclude='.git/' \
    --exclude='secrets/' \
    --exclude='.env' \
    --exclude='config/config.py' \
    --exclude='__pycache__/' \
    --exclude='*.py[co]' \
    --exclude='taguette/l10n/' \
    --exclude='.venv/' \
    --filter=':- .gitignore' \
    ./ "${REMOTE_HOST}:${REMOTE_DIR}/"
ok "Files synced"

# ---------------------------------------------------------------------------
# 5. Remote git setup
# ---------------------------------------------------------------------------
step "Setting up git on remote"
ssh "$REMOTE_HOST" bash <<EOF
set -euo pipefail
cd ${REMOTE_DIR}

# Init git if not already done
if [ ! -d .git ]; then
    git init -b master
fi

# Set remotes
git remote remove origin    2>/dev/null || true
git remote remove upstream  2>/dev/null || true
git remote add origin    "${GITHUB_REMOTE}"
git remote add upstream  "https://gitlab.com/remram44/taguette.git"

# Point HEAD to the synced content without fetching
# (no GitHub credentials needed on server at this point)
git add -A
git commit -m "deploy: sync from local $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --allow-empty 2>/dev/null || true

echo "  remotes: origin=${GITHUB_REMOTE}"
echo "           upstream=https://gitlab.com/remram44/taguette.git"
EOF
ok "Git configured on remote"

# ---------------------------------------------------------------------------
# 6. Check secrets exist on remote
# ---------------------------------------------------------------------------
step "Checking secrets on remote"
MISSING_SECRETS=0
ssh "$REMOTE_HOST" bash <<'EOF'
set -euo pipefail
cd ~/repos/taguette

check_file() {
    if [ ! -f "$1" ]; then
        echo "  MISSING: $1"
        return 1
    else
        echo "  OK:      $1"
        return 0
    fi
}

MISSING=0
check_file "secrets/postgres_password.txt" || MISSING=1
check_file ".env"                           || MISSING=1
check_file "config/config.py"              || MISSING=1

if [ "$MISSING" -eq 1 ]; then
    echo ""
    echo "  --> See scripts/setup_secrets.sh to create them"
    exit 1
fi
EOF
ok "All secrets present"

# ---------------------------------------------------------------------------
# 7. Start / restart service
# ---------------------------------------------------------------------------
step "Starting service with Docker Compose"
ssh "$REMOTE_HOST" bash <<EOF
set -euo pipefail
cd ${REMOTE_DIR}
docker compose pull --quiet 2>/dev/null || true
docker compose up -d --build --remove-orphans
docker compose ps
EOF
ok "Service started"

echo -e "\n${GREEN}${BOLD}Deploy complete!${RESET}"
