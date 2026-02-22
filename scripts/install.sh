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
# Re-run to update: same command — existing data and secrets are preserved.
#
# Environment overrides:
#   BACKEND_PORT          Backend API port (default: 9001)
#   NATS_SERVER_VERSION   nats-server binary version (default: v2.10.24)
#   SKIP_NGINX            Set to 1 to skip nginx configuration
#   SKIP_SEED             Set to 1 to skip database seeding on fresh install
# =============================================================================

set -euo pipefail

# ── Colour helpers ──────────────────────────────────────────────────────────────
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

# ── Resolve runtime user ────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run with sudo: sudo $0 [BACKEND_USER]"

BACKEND_USER="${1:-${SUDO_USER:-$(logname 2>/dev/null || whoami)}}"
BACKEND_PORT="${BACKEND_PORT:-9001}"
NATS_SERVER_VERSION="${NATS_SERVER_VERSION:-v2.10.24}"
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

# ── 1. Prerequisites ────────────────────────────────────────────────────────────
step "Checking prerequisites"

check_cmd() {
  local cmd="$1" hint="$2"
  if ! command -v "$cmd" &>/dev/null; then
    die "'$cmd' not found. $hint"
  fi
  success "$cmd: $(command -v "$cmd")"
}

check_cmd node    "Install Node.js ≥ 18 from https://nodejs.org/"
check_cmd pnpm    "Install pnpm: npm install -g pnpm"
check_cmd go      "Install Go ≥ 1.21 from https://go.dev/dl/"
check_cmd openssl "Install openssl (usually: apt install openssl)"
check_cmd curl    "Install curl (usually: apt install curl)"

NODE_MAJOR=$(node --version | sed 's/v\([0-9]*\).*/\1/')
[[ "$NODE_MAJOR" -ge 18 ]] \
  || die "Node.js 18+ required, found $(node --version). Use nvm to upgrade:\n  nvm install 18 && nvm use 18"

GO_MAJOR=$(go version | grep -oP 'go\K[0-9]+')
GO_MINOR=$(go version | grep -oP 'go[0-9]+\.\K[0-9]+')
[[ "$GO_MAJOR" -gt 1 || ( "$GO_MAJOR" -eq 1 && "$GO_MINOR" -ge 21 ) ]] \
  || die "Go 1.21+ required, found $(go version | awk '{print $3}')"

success "All prerequisites satisfied"

# ── 2. Detect fresh install vs update ──────────────────────────────────────────
DB_FILE="$REPO_ROOT/packages/database/data/nasx.db"
if [[ -f "$DB_FILE" ]]; then
  IS_UPDATE=1
  warn "Existing database found — performing update"
  warn "Database will NOT be re-seeded and will NOT lose data"
else
  IS_UPDATE=0
  info "Fresh installation"
fi

# ── 3. Stop services before rebuilding (update only) ───────────────────────────
if [[ "$IS_UPDATE" -eq 1 ]]; then
  step "Stopping services before update"
  systemctl stop nasx nasx-root-worker 2>/dev/null || true
  success "Application services stopped"
fi

# ── 4. Install pnpm dependencies ────────────────────────────────────────────────
step "Installing dependencies"
sudo -u "$BACKEND_USER" bash -c "cd '$REPO_ROOT' && pnpm install --frozen-lockfile"
success "Dependencies installed"

# ── 5. Build nasx-root-worker ───────────────────────────────────────────────────
step "Building nasx-root-worker"
(
  cd "$REPO_ROOT/apps/root-worker"
  GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o nasx-root-worker .
)
install -m 755 "$REPO_ROOT/apps/root-worker/nasx-root-worker" /usr/local/bin/nasx-root-worker
success "Installed: /usr/local/bin/nasx-root-worker"

# ── 6. Database setup ────────────────────────────────────────────────────────────
step "Setting up database"
DB_DIR="$REPO_ROOT/packages/database/data"
mkdir -p "$DB_DIR"
chown "$BACKEND_USER:" "$DB_DIR"

if [[ "$IS_UPDATE" -eq 1 ]]; then
  # Apply only additive schema changes. Without --accept-data-loss, Prisma will
  # refuse if a destructive change is required — fail loudly rather than silently
  # drop data.
  sudo -u "$BACKEND_USER" bash -c "
    cd '$REPO_ROOT/packages/database'
    npx prisma db push
  "
  success "Schema updated (existing data preserved)"
else
  # Fresh install — no data to protect.
  sudo -u "$BACKEND_USER" bash -c "
    cd '$REPO_ROOT/packages/database'
    npx prisma db push --accept-data-loss
  "
  success "Schema created"

  if [[ "$SKIP_SEED" != "1" ]]; then
    sudo -u "$BACKEND_USER" bash -c "
      cd '$REPO_ROOT/packages/database'
      npx tsx prisma/seed.ts
    "
    success "Database seeded (admin / admin)"
  fi
fi

# ── 7. Generate secrets ──────────────────────────────────────────────────────────
step "Generating secrets"
ENV_FILE="$REPO_ROOT/.env"

if [[ -f "$ENV_FILE" ]]; then
  warn ".env already exists — keeping existing secrets"
else
  JWT_SECRET=$(openssl rand -hex 32)
  printf 'NODE_ENV=production\nJWT_SECRET=%s\n' "$JWT_SECRET" > "$ENV_FILE"
  chown "$BACKEND_USER:" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  success "Generated JWT secret → $ENV_FILE"
fi

# ── 8. Build backend ─────────────────────────────────────────────────────────────
step "Building backend"
mkdir -p "$REPO_ROOT/apps/backend/dist"

sudo -u "$BACKEND_USER" bash -c "
  cd '$REPO_ROOT/apps/backend'
  pnpm dlx esbuild src/server.ts \
    --bundle \
    --platform=node \
    --target=node18 \
    --format=esm \
    --outfile=dist/server.js \
    --external:@prisma/client \
    --external:@prisma/engines \
    --external:fsevents \
    --banner:js=\"import { createRequire } from 'module'; const require = createRequire(import.meta.url);\" \
    --log-level=warning
"
success "Backend bundled → apps/backend/dist/server.js"

# ── 9. Build dashboard ───────────────────────────────────────────────────────────
step "Building dashboard"

if [[ "$SKIP_NGINX" != "1" ]] && command -v nginx &>/dev/null; then
  VITE_API_URL="/trpc"
else
  SERVER_IP=$(hostname -I | awk '{print $1}')
  VITE_API_URL="http://${SERVER_IP}:${BACKEND_PORT}/trpc"
  warn "nginx not found — dashboard will connect directly to :${BACKEND_PORT}"
fi

printf 'VITE_API_URL=%s\n' "$VITE_API_URL" \
  > "$REPO_ROOT/apps/dashboard/.env.production"

sudo -u "$BACKEND_USER" bash -c "
  cd '$REPO_ROOT/apps/dashboard'
  pnpm build
"
success "Dashboard built → apps/dashboard/dist/"

# ── 10. Install NATS server ──────────────────────────────────────────────────────
step "Installing NATS server ($NATS_SERVER_VERSION)"

if command -v nats-server &>/dev/null && \
   nats-server --version 2>/dev/null | grep -qF "${NATS_SERVER_VERSION#v}"; then
  success "nats-server $NATS_SERVER_VERSION already installed"
else
  NATS_TMP=$(mktemp -d)
  NATS_DL="https://github.com/nats-io/nats-server/releases/download/${NATS_SERVER_VERSION}/nats-server-${NATS_SERVER_VERSION}-linux-amd64.tar.gz"
  curl -fsSL --progress-bar "$NATS_DL" -o "$NATS_TMP/nats.tar.gz" \
    || { rm -rf "$NATS_TMP"; die "Failed to download nats-server from $NATS_DL"; }
  tar -xzf "$NATS_TMP/nats.tar.gz" -C "$NATS_TMP" --strip-components=1
  # Stop NATS before replacing its binary.
  systemctl stop nasx-nats 2>/dev/null || true
  install -m 755 "$NATS_TMP/nats-server" /usr/local/bin/nats-server
  rm -rf "$NATS_TMP"
  success "Installed: /usr/local/bin/nats-server"
fi

# Create nats system user
if ! id "nats" &>/dev/null; then
  useradd -r -s /usr/sbin/nologin nats
  success "Created system user 'nats'"
fi

# ── 11. Configure NATS ───────────────────────────────────────────────────────────
step "Configuring NATS"

NASX_CONF_DIR="/etc/nasx"
NATS_DATA_DIR="/var/lib/nasx/nats"
NATS_CONF="$NASX_CONF_DIR/nats.conf"
WORKER_ENV="$NASX_CONF_DIR/worker.env"

mkdir -p "$NASX_CONF_DIR" "$NATS_DATA_DIR"
chown nats: "$NATS_DATA_DIR"

# Generate credentials once; reuse on updates.
if [[ ! -f "$NASX_CONF_DIR/.nats-credentials" ]]; then
  NATS_BACKEND_PASS=$(openssl rand -hex 32)
  NATS_WORKER_PASS=$(openssl rand -hex 32)
  printf 'NATS_BACKEND_PASS=%s\nNATS_WORKER_PASS=%s\n' \
    "$NATS_BACKEND_PASS" "$NATS_WORKER_PASS" \
    > "$NASX_CONF_DIR/.nats-credentials"
  chmod 600 "$NASX_CONF_DIR/.nats-credentials"
  success "Generated NATS credentials → $NASX_CONF_DIR/.nats-credentials"
else
  warn "NATS credentials already exist — reusing"
fi

# shellcheck source=/dev/null
source "$NASX_CONF_DIR/.nats-credentials"

cat > "$NATS_CONF" <<EOF
# NASX NATS configuration — generated by install.sh on $(date)
max_payload: 67108864  # 64 MB

jetstream {
  store_dir: "$NATS_DATA_DIR"
}

authorization {
  users: [
    {
      user: "backend"
      password: "$NATS_BACKEND_PASS"
      permissions: {
        publish:   [ "nasx.root.>", "_INBOX.>", "\$JS.>" ]
        subscribe: [ "nasx.events.>", "_INBOX.>", "\$JS.>" ]
      }
    }
    {
      user: "worker"
      password: "$NATS_WORKER_PASS"
      permissions: {
        publish:   [ "nasx.events.>", "_INBOX.>", "\$JS.>" ]
        subscribe: [ "nasx.root.>", "_INBOX.>", "\$JS.>" ]
      }
    }
  ]
}
EOF
chmod 640 "$NATS_CONF"
chown root:nats "$NATS_CONF"
success "NATS config → $NATS_CONF"

cat > "$WORKER_ENV" <<EOF
NATS_URL=nats://127.0.0.1:4222
NATS_USER=worker
NATS_PASS=$NATS_WORKER_PASS
EOF
chmod 600 "$WORKER_ENV"
success "Worker env → $WORKER_ENV"

# Keep backend .env in sync with NATS credentials (idempotent).
for VAR in NATS_URL NATS_USER NATS_PASS; do
  sed -i "/^${VAR}=/d" "$ENV_FILE"
done
cat >> "$ENV_FILE" <<EOF
NATS_URL=nats://127.0.0.1:4222
NATS_USER=backend
NATS_PASS=$NATS_BACKEND_PASS
EOF
success "Backend NATS credentials → $ENV_FILE"

cat > /etc/systemd/system/nasx-nats.service <<EOF
[Unit]
Description=NASX NATS JetStream Server
After=network.target

[Service]
ExecStart=/usr/local/bin/nats-server --config $NATS_CONF
# Wait until port 4222 is accepting connections before systemd marks this
# service active.  This makes After=nasx-nats.service a true readiness gate
# for the dependent nasx and nasx-root-worker units.
ExecStartPost=/bin/bash -c 'for i in \$(seq 1 30); do bash -c "echo >/dev/tcp/127.0.0.1/4222" 2>/dev/null && exit 0; sleep 1; done; exit 1'
User=nats
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=nasx-nats

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nasx-nats
systemctl restart nasx-nats
success "nasx-nats service started"

# ── 12. Install worker service ───────────────────────────────────────────────────
step "Installing nasx-root-worker service"

cat > /etc/systemd/system/nasx-root-worker.service <<EOF
[Unit]
Description=NASX Root Worker
After=network.target nasx-nats.service
Requires=nasx-nats.service

[Service]
ExecStart=/usr/local/bin/nasx-root-worker
User=root
EnvironmentFile=$WORKER_ENV
PrivateTmp=yes
NoNewPrivileges=no
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=nasx-root-worker

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nasx-root-worker
systemctl restart nasx-root-worker
success "nasx-root-worker service started"

# ── 13. Systemd service (backend) ───────────────────────────────────────────────
step "Installing nasx backend service"

NODE_BIN="$(command -v node)"
BACKEND_DIR="$REPO_ROOT/apps/backend"
SERVICE_FILE="/etc/systemd/system/nasx.service"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=NASX NAS Backend
Documentation=https://github.com/your-org/nasx
After=network.target nasx-nats.service nasx-root-worker.service
Requires=nasx-nats.service nasx-root-worker.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=$BACKEND_USER
WorkingDirectory=$BACKEND_DIR
EnvironmentFile=$REPO_ROOT/.env
Environment=DASHBOARD_PATH=$REPO_ROOT/apps/dashboard/dist
ExecStart=$NODE_BIN $BACKEND_DIR/dist/server.js
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=nasx

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$REPO_ROOT/packages/database/data /tmp

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nasx
systemctl restart nasx
success "Service installed and started (systemctl status nasx)"

# ── 14. nginx (optional) ─────────────────────────────────────────────────────────
if [[ "$SKIP_NGINX" != "1" ]] && command -v nginx &>/dev/null; then
  step "Configuring nginx"

  DASHBOARD_DIST="$REPO_ROOT/apps/dashboard/dist"
  NGINX_CONF="/etc/nginx/sites-available/nasx"

  cat > "$NGINX_CONF" <<EOF
# NASX — generated by install.sh on $(date)
server {
    listen 80;
    server_name _;

    location /trpc {
        proxy_pass         http://127.0.0.1:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }

    location /files {
        proxy_pass              http://127.0.0.1:$BACKEND_PORT;
        proxy_http_version      1.1;
        proxy_set_header        Host          \$host;
        proxy_set_header        X-Real-IP     \$remote_addr;
        client_max_body_size    100m;
        proxy_request_buffering off;
        proxy_read_timeout      300s;
    }

    location /health {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
    }

    location / {
        root $DASHBOARD_DIST;
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

  SITES_ENABLED="/etc/nginx/sites-enabled"
  if [[ -d "$SITES_ENABLED" ]]; then
    rm -f "$SITES_ENABLED/nasx"
    ln -s "$NGINX_CONF" "$SITES_ENABLED/nasx"
  fi

  if [[ -f "$SITES_ENABLED/default" ]]; then
    warn "Disabling nginx default site (conflicts on port 80)"
    rm -f "$SITES_ENABLED/default"
  fi

  nginx -t && systemctl reload nginx
  success "nginx configured → $NGINX_CONF"
fi

# ── Summary ──────────────────────────────────────────────────────────────────────
echo ""
if [[ "$IS_UPDATE" -eq 1 ]]; then
  echo -e "${BOLD}${GREEN}╔═══════════════════════════════════╗"
  echo -e "║   NASX updated successfully!     ║"
  echo -e "╚═══════════════════════════════════╝${NC}"
else
  echo -e "${BOLD}${GREEN}╔═══════════════════════════════════╗"
  echo -e "║   NASX installed successfully!   ║"
  echo -e "╚═══════════════════════════════════╝${NC}"
fi
echo ""

SERVER_IP=$(hostname -I | awk '{print $1}')

if [[ "$SKIP_NGINX" != "1" ]] && command -v nginx &>/dev/null; then
  echo -e "  ${BOLD}Access NASX:${NC}  http://$SERVER_IP"
else
  echo -e "  ${BOLD}Access NASX:${NC}  http://$SERVER_IP:$BACKEND_PORT"
fi

echo ""

if [[ "$IS_UPDATE" -eq 0 ]]; then
  echo -e "  ${BOLD}Default login:${NC}  admin / admin"
  echo -e "  ${YELLOW}!! Change the admin password immediately after first login !!${NC}"
  echo ""
fi

echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "    systemctl status nasx               # backend"
echo -e "    systemctl status nasx-root-worker   # privilege worker"
echo -e "    systemctl status nasx-nats          # message bus"
echo -e "    journalctl -u nasx -f               # live logs"
echo -e "    sudo $0 $BACKEND_USER        # re-run to update"
echo ""
