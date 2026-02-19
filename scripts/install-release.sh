#!/usr/bin/env bash
# =============================================================================
# NASX — Install from GitHub Release
# =============================================================================
# Downloads the latest pre-built release from GitHub and installs NASX
# as a systemd service. Does NOT require Go or a build environment.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/kittyruntime/nasx/main/scripts/install-release.sh | sudo bash
#
# Or with a specific version:
#   curl -fsSL ... | sudo VERSION=v1.2.0 bash
#
# Environment overrides:
#   VERSION      Release tag to install (default: latest)
#   INSTALL_DIR  Installation directory  (default: /opt/nasx)
#   NASX_USER    System user to run as   (default: nasx)
#   BACKEND_PORT Backend API port        (default: 9001)
#   SKIP_NGINX   Set to 1 to skip nginx  (default: 0)
#   SKIP_SEED    Set to 1 to skip seed   (default: 0)
# =============================================================================

set -euo pipefail

REPO="kittyruntime/nasx"
INSTALL_DIR="${INSTALL_DIR:-/opt/nasx}"
NASX_USER="${NASX_USER:-nasx}"
BACKEND_PORT="${BACKEND_PORT:-9001}"
SKIP_NGINX="${SKIP_NGINX:-0}"
SKIP_SEED="${SKIP_SEED:-0}"

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
  echo "  Install from Release — $(date '+%Y-%m-%d %H:%M')"
  echo ""
}

# ── Must run as root ───────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash $0"

banner

# ── 1. Prerequisites ───────────────────────────────────────────────────────────
step "Checking prerequisites"

check_cmd() {
  local cmd="$1" hint="$2"
  command -v "$cmd" &>/dev/null || die "'$cmd' not found. $hint"
  success "$cmd: $(command -v "$cmd")"
}

check_cmd curl    "Install curl: apt install curl"
check_cmd node    "Install Node.js ≥ 18 from https://nodejs.org/"
check_cmd npm     "npm comes with Node.js — reinstall Node"
check_cmd openssl "Install openssl: apt install openssl"

NODE_MAJOR=$(node --version | sed 's/v\([0-9]*\).*/\1/')
[[ "$NODE_MAJOR" -ge 18 ]] \
  || die "Node.js 18+ required (found $(node --version)). Install via:\n  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt install -y nodejs"

success "All prerequisites satisfied"

# ── 2. Resolve version ─────────────────────────────────────────────────────────
step "Resolving release version"

if [[ -z "${VERSION:-}" ]]; then
  VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -oP '"tag_name":\s*"\K[^"]+')
  [[ -n "$VERSION" ]] || die "Could not fetch latest release from GitHub. Check your internet connection."
fi

TARBALL_URL="https://github.com/${REPO}/releases/download/${VERSION}/nasx-${VERSION}-linux-amd64.tar.gz"

info "Version:      $VERSION"
info "Install dir:  $INSTALL_DIR"
info "Run as user:  $NASX_USER"
info "Backend port: $BACKEND_PORT"

# ── 3. Create system user ──────────────────────────────────────────────────────
step "Setting up system user"

if id "$NASX_USER" &>/dev/null; then
  success "User '$NASX_USER' already exists"
else
  useradd -r -m -s /usr/sbin/nologin "$NASX_USER"
  success "Created system user '$NASX_USER'"
fi

# ── 4. Download & extract release ──────────────────────────────────────────────
step "Downloading $VERSION"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

TARBALL="$TMPDIR/nasx.tar.gz"
curl -fsSL --progress-bar "$TARBALL_URL" -o "$TARBALL" \
  || die "Download failed: $TARBALL_URL"
success "Downloaded"

mkdir -p "$INSTALL_DIR"
tar -xzf "$TARBALL" --strip-components=1 -C "$INSTALL_DIR"
success "Extracted to $INSTALL_DIR"

chown -R "$NASX_USER:" "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/apps/backend/bin/fs-helper"

# ── 5. Install runtime dependencies (Prisma) ───────────────────────────────────
step "Installing runtime dependencies"

# Installs @prisma/client + tsx into $INSTALL_DIR/node_modules so both the
# backend bundle and the seed script can resolve them.
npm install \
  --prefix "$INSTALL_DIR" \
  --no-save \
  --no-fund \
  --no-audit \
  @prisma/client@^6 prisma@^6 tsx@^4

success "Runtime dependencies installed"

# ── 6. Generate Prisma client ──────────────────────────────────────────────────
step "Generating Prisma client"

NODE_PATH="$INSTALL_DIR/node_modules"
PRISMA_BIN="$INSTALL_DIR/node_modules/.bin/prisma"

sudo -u "$NASX_USER" bash -c "
  cd '$INSTALL_DIR/packages/database'
  PATH='$INSTALL_DIR/node_modules/.bin:\$PATH' \
  NODE_PATH='$NODE_PATH' \
    '$PRISMA_BIN' generate
"
success "Prisma client generated"

# ── 7. Database setup ──────────────────────────────────────────────────────────
step "Setting up database"

DB_DIR="$INSTALL_DIR/packages/database/data"
mkdir -p "$DB_DIR"
chown "$NASX_USER:" "$DB_DIR"

sudo -u "$NASX_USER" bash -c "
  cd '$INSTALL_DIR/packages/database'
  PATH='$INSTALL_DIR/node_modules/.bin:\$PATH' \
  NODE_PATH='$NODE_PATH' \
    '$PRISMA_BIN' db push --accept-data-loss
"
success "Schema applied"

if [[ "$SKIP_SEED" != "1" ]]; then
  TSX_BIN="$INSTALL_DIR/node_modules/.bin/tsx"
  sudo -u "$NASX_USER" bash -c "
    cd '$INSTALL_DIR/packages/database'
    PATH='$INSTALL_DIR/node_modules/.bin:\$PATH' \
    NODE_PATH='$NODE_PATH' \
      '$TSX_BIN' prisma/seed.ts
  "
  success "Database seeded (admin / admin)"
fi

# ── 8. Generate secrets ────────────────────────────────────────────────────────
step "Generating secrets"

ENV_FILE="$INSTALL_DIR/.env"
FS_HELPER_PATH="$INSTALL_DIR/apps/backend/bin/fs-helper"

if [[ -f "$ENV_FILE" ]]; then
  warn ".env already exists — keeping existing secrets"
else
  JWT_SECRET=$(openssl rand -hex 32)
  cat > "$ENV_FILE" <<EOF
NODE_ENV=production
JWT_SECRET=$JWT_SECRET
FS_HELPER_PATH=$FS_HELPER_PATH
EOF
  chown "$NASX_USER:" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  success "Generated JWT secret → $ENV_FILE"
fi

# Ensure FS_HELPER_PATH stays current (e.g. after update)
if grep -q "^FS_HELPER_PATH=" "$ENV_FILE"; then
  sed -i "s|^FS_HELPER_PATH=.*|FS_HELPER_PATH=$FS_HELPER_PATH|" "$ENV_FILE"
else
  echo "FS_HELPER_PATH=$FS_HELPER_PATH" >> "$ENV_FILE"
fi

# ── 9. Sudoers ─────────────────────────────────────────────────────────────────
step "Configuring sudo rules"
"$INSTALL_DIR/scripts/setup-sudo.sh" "$NASX_USER"

# ── 10. Systemd service ────────────────────────────────────────────────────────
step "Installing systemd service"

NODE_BIN="$(command -v node)"
BACKEND_DIR="$INSTALL_DIR/apps/backend"
SERVICE_FILE="/etc/systemd/system/nasx.service"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=NASX NAS Backend
Documentation=https://github.com/${REPO}
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=$NASX_USER
WorkingDirectory=$BACKEND_DIR
EnvironmentFile=$ENV_FILE
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
ReadWritePaths=$INSTALL_DIR/packages/database/data

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nasx
systemctl restart nasx
success "Service installed and started"

# ── 11. nginx (optional) ───────────────────────────────────────────────────────
if [[ "$SKIP_NGINX" != "1" ]] && command -v nginx &>/dev/null; then
  step "Configuring nginx"

  DASHBOARD_DIST="$INSTALL_DIR/apps/dashboard/dist"
  NGINX_CONF="/etc/nginx/sites-available/nasx"

  cat > "$NGINX_CONF" <<EOF
# NASX — generated by install-release.sh on $(date)
server {
    listen 80;
    server_name _;

    root $DASHBOARD_DIST;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

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
  echo -e "  ${BOLD}Dashboard:${NC}  ${YELLOW}(serve $INSTALL_DIR/apps/dashboard/dist/ with a web server)${NC}"
  echo -e "  ${BOLD}API:${NC}        http://$SERVER_IP:$BACKEND_PORT/trpc"
fi

echo ""
echo -e "  ${BOLD}Version:${NC}        $VERSION"
echo -e "  ${BOLD}Default login:${NC}  admin / admin"
echo -e "  ${YELLOW}!! Change the admin password immediately after first login !!${NC}"
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "    systemctl status nasx          # service status"
echo -e "    journalctl -u nasx -f          # live logs"
echo ""
echo -e "  ${BOLD}To update to a newer version:${NC}"
echo -e "    curl -fsSL https://raw.githubusercontent.com/${REPO}/main/scripts/install-release.sh | sudo bash"
echo ""
