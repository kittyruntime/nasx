#!/usr/bin/env bash
# =============================================================================
# NASX — Build & Install Script
# =============================================================================
# Builds everything from source and installs NASX as a systemd service.
#
# Usage (run as root or with sudo):
#   sudo ./scripts/install.sh [BACKEND_USER]
#
#   BACKEND_USER  Linux user the backend runs as.
#                 Defaults to the user who invoked sudo (or current user).
#
# Environment overrides:
#   BACKEND_PORT   Backend API port (default: 9001)
#   SKIP_NGINX     Set to 1 to skip nginx configuration
#   SKIP_SEED      Set to 1 to skip database seeding (useful for updates)
# =============================================================================

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "  ${CYAN}··${NC}  $*"; }
success() { echo -e "  ${GREEN}✓${NC}   $*"; }
warn()    { echo -e "  ${YELLOW}!${NC}   $*"; }
die()     { echo -e "\n  ${RED}✗ error:${NC} $*\n" >&2; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}▶ $*${NC}"; }
banner()  {
  echo -e "${BOLD}"
  echo "  ███╗   ██╗ █████╗ ███████╗██╗  ██╗"
  echo "  ████╗  ██║██╔══██╗██╔════╝╚██╗██╔╝"
  echo "  ██╔██╗ ██║███████║███████╗ ╚███╔╝ "
  echo "  ██║╚██╗██║██╔══██║╚════██║ ██╔██╗ "
  echo "  ██║ ╚████║██║  ██║███████║██╔╝ ██╗"
  echo "  ╚═╝  ╚═══╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝"
  echo -e "${NC}"
  echo "  Build & Install — $(date '+%Y-%m-%d %H:%M')"
  echo ""
}

# ── Resolve runtime user ───────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run with sudo: sudo $0 [BACKEND_USER]"

BACKEND_USER="${1:-${SUDO_USER:-$(logname 2>/dev/null || whoami)}}"
BACKEND_PORT="${BACKEND_PORT:-9001}"
SKIP_NGINX="${SKIP_NGINX:-0}"
SKIP_SEED="${SKIP_SEED:-0}"

id "$BACKEND_USER" &>/dev/null \
  || die "User '$BACKEND_USER' does not exist. Create it first:\n  useradd -r -m -s /bin/bash $BACKEND_USER"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

banner

info "Repo:         $REPO_ROOT"
info "Backend user: $BACKEND_USER"
info "Backend port: $BACKEND_PORT"

# ── 1. Prerequisites ───────────────────────────────────────────────────────────
step "Checking prerequisites"

check_cmd() {
  local cmd="$1" hint="$2"
  if ! command -v "$cmd" &>/dev/null; then
    die "'$cmd' not found. $hint"
  fi
  success "$cmd: $(command -v "$cmd")"
}

check_cmd node   "Install Node.js ≥ 18 from https://nodejs.org/"
check_cmd pnpm   "Install pnpm: npm install -g pnpm"
check_cmd go     "Install Go ≥ 1.21 from https://go.dev/dl/"
check_cmd openssl "Install openssl (usually: apt install openssl)"

NODE_MAJOR=$(node --version | sed 's/v\([0-9]*\).*/\1/')
[[ "$NODE_MAJOR" -ge 18 ]] \
  || die "Node.js 18+ required, found $(node --version). Use nvm to upgrade:\n  nvm install 18 && nvm use 18"

GO_MAJOR=$(go version | grep -oP 'go\K[0-9]+')
GO_MINOR=$(go version | grep -oP 'go[0-9]+\.\K[0-9]+')
[[ "$GO_MAJOR" -gt 1 || ( "$GO_MAJOR" -eq 1 && "$GO_MINOR" -ge 21 ) ]] \
  || die "Go 1.21+ required, found $(go version | awk '{print $3}')"

success "All prerequisites satisfied"

# ── 2. Install pnpm dependencies ───────────────────────────────────────────────
step "Installing dependencies"
sudo -u "$BACKEND_USER" bash -c "cd '$REPO_ROOT' && pnpm install --frozen-lockfile"
success "Dependencies installed"

# ── 3. Build fs-helper (Go binary) ────────────────────────────────────────────
step "Building fs-helper"
mkdir -p "$REPO_ROOT/apps/backend/bin"
sudo -u "$BACKEND_USER" bash -c "
  cd '$REPO_ROOT/apps/backend/fs-helper'
  go build -o ../bin/fs-helper .
"
chmod +x "$REPO_ROOT/apps/backend/bin/fs-helper"
FS_HELPER_PATH="$(realpath "$REPO_ROOT/apps/backend/bin/fs-helper")"
success "Built: $FS_HELPER_PATH"

# ── 4. Database setup ──────────────────────────────────────────────────────────
step "Setting up database"
DB_DIR="$REPO_ROOT/packages/database/data"
mkdir -p "$DB_DIR"
chown "$BACKEND_USER:" "$DB_DIR"

sudo -u "$BACKEND_USER" bash -c "
  cd '$REPO_ROOT/packages/database'
  npx prisma db push --accept-data-loss
"
success "Schema applied"

if [[ "$SKIP_SEED" != "1" ]]; then
  sudo -u "$BACKEND_USER" bash -c "
    cd '$REPO_ROOT/packages/database'
    npx tsx prisma/seed.ts
  "
  success "Database seeded (admin / admin)"
fi

# ── 5. Generate secrets ────────────────────────────────────────────────────────
step "Generating secrets"
ENV_FILE="$REPO_ROOT/.env"

if [[ -f "$ENV_FILE" ]]; then
  warn ".env already exists — keeping existing secrets"
else
  JWT_SECRET=$(openssl rand -hex 32)
  cat > "$ENV_FILE" <<EOF
NODE_ENV=production
JWT_SECRET=$JWT_SECRET
FS_HELPER_PATH=$FS_HELPER_PATH
EOF
  chown "$BACKEND_USER:" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  success "Generated JWT secret → $ENV_FILE"
fi

# Ensure FS_HELPER_PATH is always up-to-date (binary may have moved)
if grep -q "^FS_HELPER_PATH=" "$ENV_FILE"; then
  sed -i "s|^FS_HELPER_PATH=.*|FS_HELPER_PATH=$FS_HELPER_PATH|" "$ENV_FILE"
else
  echo "FS_HELPER_PATH=$FS_HELPER_PATH" >> "$ENV_FILE"
fi

# ── 6. Build backend ───────────────────────────────────────────────────────────
step "Building backend"
mkdir -p "$REPO_ROOT/apps/backend/dist"

# esbuild bundles the entire TS monorepo into a single ESM file,
# excluding only native packages (Prisma uses its own query engine binary).
sudo -u "$BACKEND_USER" bash -c "
  cd '$REPO_ROOT/apps/backend'
  node_modules/.bin/esbuild src/server.ts \
    --bundle \
    --platform=node \
    --target=node18 \
    --format=esm \
    --outfile=dist/server.js \
    --external:@prisma/client \
    --external:@prisma/engines \
    --external:fsevents \
    --log-level=warning
"
success "Backend bundled → apps/backend/dist/server.js"

# ── 7. Build dashboard ─────────────────────────────────────────────────────────
step "Building dashboard"

# Decide the API URL: relative (/trpc) when nginx proxies, absolute otherwise
if [[ "$SKIP_NGINX" != "1" ]] && command -v nginx &>/dev/null; then
  VITE_API_URL="/trpc"
else
  # Fall back to the server's primary IP
  SERVER_IP=$(hostname -I | awk '{print $1}')
  VITE_API_URL="http://${SERVER_IP}:${BACKEND_PORT}/trpc"
  warn "nginx not found — dashboard will connect directly to :${BACKEND_PORT}"
fi

DASHBOARD_ENV="$REPO_ROOT/apps/dashboard/.env.production"
cat > "$DASHBOARD_ENV" <<EOF
VITE_API_URL=$VITE_API_URL
EOF

sudo -u "$BACKEND_USER" bash -c "
  cd '$REPO_ROOT/apps/dashboard'
  pnpm build
"
success "Dashboard built → apps/dashboard/dist/"

# ── 8. Sudoers ─────────────────────────────────────────────────────────────────
step "Configuring sudo rules"
"$SCRIPT_DIR/setup-sudo.sh" "$BACKEND_USER"

# ── 9. Systemd service ─────────────────────────────────────────────────────────
step "Installing systemd service"

NODE_BIN="$(command -v node)"
BACKEND_DIR="$REPO_ROOT/apps/backend"
SERVICE_FILE="/etc/systemd/system/nasx.service"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=NASX NAS Backend
Documentation=https://github.com/your-org/nasx
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=$BACKEND_USER
WorkingDirectory=$BACKEND_DIR
EnvironmentFile=$REPO_ROOT/.env
ExecStart=$NODE_BIN $BACKEND_DIR/dist/server.js
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=nasx

# Basic hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$REPO_ROOT/packages/database/data

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nasx
systemctl restart nasx
success "Service installed and started (systemctl status nasx)"

# ── 10. nginx (optional) ───────────────────────────────────────────────────────
if [[ "$SKIP_NGINX" != "1" ]] && command -v nginx &>/dev/null; then
  step "Configuring nginx"

  DASHBOARD_DIST="$REPO_ROOT/apps/dashboard/dist"
  NGINX_CONF="/etc/nginx/sites-available/nasx"

  cat > "$NGINX_CONF" <<EOF
# NASX — generated by install.sh on $(date)
server {
    listen 80;
    server_name _;

    # ── Dashboard (SPA) ──────────────────────────────────────────────────────
    root $DASHBOARD_DIST;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # ── Backend API ──────────────────────────────────────────────────────────
    location /trpc {
        proxy_pass         http://127.0.0.1:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded-for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }

    # ── File routes (chunked upload — large body) ────────────────────────────
    location /files {
        proxy_pass              http://127.0.0.1:$BACKEND_PORT;
        proxy_http_version      1.1;
        proxy_set_header        Host            \$host;
        proxy_set_header        X-Real-IP       \$remote_addr;
        client_max_body_size    100m;
        proxy_request_buffering off;
        proxy_read_timeout      300s;
    }

    # ── Health check ─────────────────────────────────────────────────────────
    location /health {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
    }
}
EOF

  # Enable site
  SITES_ENABLED="/etc/nginx/sites-enabled"
  if [[ -d "$SITES_ENABLED" ]]; then
    rm -f "$SITES_ENABLED/nasx"
    ln -s "$NGINX_CONF" "$SITES_ENABLED/nasx"
  fi

  # Remove default site if it would conflict on port 80
  if [[ -f "$SITES_ENABLED/default" ]]; then
    warn "Disabling nginx default site (conflicts on port 80)"
    rm -f "$SITES_ENABLED/default"
  fi

  nginx -t && systemctl reload nginx
  success "nginx configured → $NGINX_CONF"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔═══════════════════════════════════╗"
echo -e "║   NASX installed successfully!   ║"
echo -e "╚═══════════════════════════════════╝${NC}"
echo ""

SERVER_IP=$(hostname -I | awk '{print $1}')

if [[ "$SKIP_NGINX" != "1" ]] && command -v nginx &>/dev/null; then
  echo -e "  ${BOLD}Dashboard:${NC}  http://$SERVER_IP"
  echo -e "  ${BOLD}API:${NC}        http://$SERVER_IP/trpc"
else
  echo -e "  ${BOLD}Dashboard:${NC}  ${YELLOW}(serve apps/dashboard/dist/ with a web server)${NC}"
  echo -e "  ${BOLD}API:${NC}        http://$SERVER_IP:$BACKEND_PORT/trpc"
fi

echo ""
echo -e "  ${BOLD}Default login:${NC}  admin / admin"
echo -e "  ${YELLOW}!! Change the admin password immediately after first login !!${NC}"
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "    systemctl status nasx          # service status"
echo -e "    journalctl -u nasx -f          # live logs"
echo -e "    sudo $0 $BACKEND_USER    # re-run to update"
echo ""
