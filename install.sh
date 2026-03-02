#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  Coolify Installer for GitHub Codespaces
#  (Docker-outside-of-Docker compatible)
# ─────────────────────────────────────────────

COOLIFY_BASE="/workspaces/coolify"
COOLIFY_SOURCE="${COOLIFY_BASE}/source"

# ── Colors ────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}==> $*${NC}"; }

# ── Dependency check ──────────────────────────
header "Checking dependencies"
for cmd in docker openssl ssh-keygen; do
  command -v "$cmd" &>/dev/null && success "$cmd found" || error "$cmd is required but not installed."
done

docker info &>/dev/null || error "Docker daemon is not accessible. Make sure docker-outside-docker is configured."
success "Docker daemon reachable"

# ─────────────────────────────────────────────
#  User prompts
# ─────────────────────────────────────────────
header "Configuration"

echo ""
echo -e "${BOLD}Coolify runs on port 8080 inside the container.${NC}"
echo -e "Your Codespace must forward a port to ${BOLD}8080${NC} and expose a public URL for it."
echo ""
read -rp "$(echo -e "${CYAN}?${NC} Enter the App URL (e.g. https://xxxx-8080.app.github.dev): ")" APP_URL
APP_URL="${APP_URL%/}"  # strip trailing slash

echo ""
echo -e "${BOLD}The real-time (WebSocket) service runs on port 6001.${NC}"
echo -e "Your Codespace must forward a port to ${BOLD}6001${NC} and expose a public URL for it."
echo ""
read -rp "$(echo -e "${CYAN}?${NC} Enter the Realtime (WebSocket) URL (e.g. https://xxxx-6001.app.github.dev): ")" REALTIME_URL
REALTIME_URL="${REALTIME_URL%/}"

# Determine pusher scheme and host from the realtime URL
if [[ "$REALTIME_URL" == https://* ]]; then
  PUSHER_SCHEME="https"
  PUSHER_PORT="443"
else
  PUSHER_SCHEME="http"
  PUSHER_PORT="6001"
fi
# Strip scheme from URL to get host
PUSHER_HOST="${REALTIME_URL#https://}"
PUSHER_HOST="${PUSHER_HOST#http://}"

echo ""

# ─────────────────────────────────────────────
#  Create directory structure
# ─────────────────────────────────────────────
header "Creating directory structure under ${COOLIFY_BASE}"

dirs=(
  "${COOLIFY_SOURCE}"
  "${COOLIFY_BASE}/ssh/keys"
  "${COOLIFY_BASE}/ssh/mux"
  "${COOLIFY_BASE}/applications"
  "${COOLIFY_BASE}/databases/postgresql"
  "${COOLIFY_BASE}/databases/redis"
  "${COOLIFY_BASE}/backups"
  "${COOLIFY_BASE}/services"
  "${COOLIFY_BASE}/proxy/dynamic"
  "${COOLIFY_BASE}/webhooks-during-maintenance"
)

for dir in "${dirs[@]}"; do
  mkdir -p "$dir"
  success "Created $dir"
done

# ─────────────────────────────────────────────
#  Permissions
# ─────────────────────────────────────────────
header "Setting permissions"

chmod -R 755 "${COOLIFY_BASE}"
chmod 700 "${COOLIFY_BASE}/ssh/keys"
chmod 700 "${COOLIFY_BASE}/ssh/mux"
chown -R 9999:9999 "${COOLIFY_BASE}/ssh"
success "Permissions set"

# ─────────────────────────────────────────────
#  Generate SSH key
# ─────────────────────────────────────────────
header "Generating SSH key"

SSH_KEY_PATH="${COOLIFY_BASE}/ssh/keys/id.root@host.docker.internal"

if [[ -f "$SSH_KEY_PATH" ]]; then
  warn "SSH key already exists at ${SSH_KEY_PATH}, skipping generation"
else
  ssh-keygen -t ed25519 -a 100 \
    -f "$SSH_KEY_PATH" \
    -q -N "" \
    -C "root@coolify"
  success "SSH key generated at ${SSH_KEY_PATH}"
fi

# Add public key to authorized_keys
AUTHORIZED_KEYS="${HOME}/.ssh/authorized_keys"
mkdir -p "${HOME}/.ssh"
touch "$AUTHORIZED_KEYS"
chmod 700 "${HOME}/.ssh"
chmod 600 "$AUTHORIZED_KEYS"

PUB_KEY=$(cat "${SSH_KEY_PATH}.pub")
if grep -qF "$PUB_KEY" "$AUTHORIZED_KEYS" 2>/dev/null; then
  warn "SSH public key already in authorized_keys, skipping"
else
  echo "$PUB_KEY" >> "$AUTHORIZED_KEYS"
  success "SSH public key added to authorized_keys"
fi

# ─────────────────────────────────────────────
#  Generate secrets
# ─────────────────────────────────────────────
header "Generating secrets"

APP_KEY="base64:$(openssl rand -base64 32)"
DB_PASSWORD="$(openssl rand -hex 16)"
REDIS_PASSWORD="$(openssl rand -hex 16)"
PUSHER_APP_KEY="$(openssl rand -hex 16)"
PUSHER_APP_SECRET="$(openssl rand -hex 16)"
APP_ID="coolify$(openssl rand -hex 4)"

success "App key, DB/Redis passwords and Pusher secrets generated"

# ─────────────────────────────────────────────
#  Write .env
# ─────────────────────────────────────────────
header "Writing .env"

cat > "${COOLIFY_SOURCE}/.env" <<EOF
APP_ID=${APP_ID}
APP_KEY=${APP_KEY}
APP_NAME=Coolify
APP_ENV=production
APP_DEBUG=false
APP_URL=${APP_URL}

DB_CONNECTION=pgsql
DB_HOST=coolify-db
DB_PORT=5432
DB_DATABASE=coolify
DB_USERNAME=coolify
DB_PASSWORD=${DB_PASSWORD}

REDIS_HOST=coolify-redis
REDIS_PORT=6379
REDIS_PASSWORD=${REDIS_PASSWORD}

PUSHER_HOST=${PUSHER_HOST}
PUSHER_PORT=${PUSHER_PORT}
PUSHER_SCHEME=${PUSHER_SCHEME}
PUSHER_APP_ID=coolify
PUSHER_APP_KEY=${PUSHER_APP_KEY}
PUSHER_APP_SECRET=${PUSHER_APP_SECRET}

COOLIFY_APP_ID=${APP_ID}
SSH_MUX_PERSIST_TIME=3600

COOLIFY_CONF_PATH=${COOLIFY_BASE}
EOF

chmod 600 "${COOLIFY_SOURCE}/.env"
success ".env written to ${COOLIFY_SOURCE}/.env"

# ─────────────────────────────────────────────
#  Write docker-compose.yml
# ─────────────────────────────────────────────
header "Writing docker-compose.yml"

cat > "${COOLIFY_SOURCE}/docker-compose.yml" <<'COMPOSE'
services:
  coolify:
    image: ghcr.io/coollabsio/coolify:latest
    container_name: coolify
    restart: always
    working_dir: /var/www/html
    environment:
      - APP_ID=${APP_ID}
      - APP_KEY=${APP_KEY}
      - APP_NAME=${APP_NAME}
      - APP_ENV=${APP_ENV}
      - APP_DEBUG=${APP_DEBUG}
      - APP_URL=${APP_URL}
      - DB_CONNECTION=${DB_CONNECTION}
      - DB_HOST=${DB_HOST}
      - DB_PORT=${DB_PORT}
      - DB_DATABASE=${DB_DATABASE}
      - DB_USERNAME=${DB_USERNAME}
      - DB_PASSWORD=${DB_PASSWORD}
      - REDIS_HOST=${REDIS_HOST}
      - REDIS_PORT=${REDIS_PORT}
      - REDIS_PASSWORD=${REDIS_PASSWORD}
      - PUSHER_HOST=${PUSHER_HOST}
      - PUSHER_PORT=${PUSHER_PORT}
      - PUSHER_SCHEME=${PUSHER_SCHEME}
      - PUSHER_APP_ID=${PUSHER_APP_ID}
      - PUSHER_APP_KEY=${PUSHER_APP_KEY}
      - PUSHER_APP_SECRET=${PUSHER_APP_SECRET}
      - COOLIFY_APP_ID=${COOLIFY_APP_ID}
      - SSH_MUX_PERSIST_TIME=${SSH_MUX_PERSIST_TIME}
    ports:
      - "8080:8080"
    volumes:
      - ${COOLIFY_CONF_PATH}/ssh/keys:/var/www/html/storage/app/ssh/keys
      - ${COOLIFY_CONF_PATH}/ssh/mux:/var/www/html/storage/app/ssh/mux
      - ${COOLIFY_CONF_PATH}/applications:/var/www/html/storage/app/applications
      - ${COOLIFY_CONF_PATH}/databases:/var/www/html/storage/app/databases
      - ${COOLIFY_CONF_PATH}/backups:/var/www/html/storage/app/backups
      - ${COOLIFY_CONF_PATH}/services:/var/www/html/storage/app/services
      - ${COOLIFY_CONF_PATH}/proxy:/var/www/html/storage/app/proxy
      - ${COOLIFY_CONF_PATH}/webhooks-during-maintenance:/var/www/html/storage/app/webhooks-during-maintenance
      - /var/run/docker.sock:/var/run/docker.sock
    extra_hosts:
      - host.docker.internal:host-gateway
    depends_on:
      coolify-db:
        condition: service_healthy
      coolify-redis:
        condition: service_healthy
      coolify-realtime:
        condition: service_started
    networks:
      - coolify

  coolify-db:
    image: postgres:15-alpine
    container_name: coolify-db
    restart: always
    environment:
      - POSTGRES_DB=${DB_DATABASE}
      - POSTGRES_USER=${DB_USERNAME}
      - POSTGRES_PASSWORD=${DB_PASSWORD}
    volumes:
      - ${COOLIFY_CONF_PATH}/databases/postgresql:/var/lib/postgresql/data
    networks:
      - coolify
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USERNAME} -d ${DB_DATABASE}"]
      interval: 5s
      timeout: 5s
      retries: 10

  coolify-redis:
    image: redis:7-alpine
    container_name: coolify-redis
    restart: always
    command: redis-server --requirepass ${REDIS_PASSWORD} --save 20 1 --loglevel warning
    volumes:
      - ${COOLIFY_CONF_PATH}/databases/redis:/data
    networks:
      - coolify
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 5s
      timeout: 5s
      retries: 10

  coolify-realtime:
    image: ghcr.io/coollabsio/coolify-realtime:latest
    container_name: coolify-realtime
    restart: always
    environment:
      - PUSHER_APP_ID=${PUSHER_APP_ID}
      - PUSHER_APP_KEY=${PUSHER_APP_KEY}
      - PUSHER_APP_SECRET=${PUSHER_APP_SECRET}
    ports:
      - "6001:6001"
      - "6002:6002"
    extra_hosts:
      - host.docker.internal:host-gateway
    networks:
      - coolify

networks:
  coolify:
    name: coolify
    external: true
COMPOSE

success "docker-compose.yml written to ${COOLIFY_SOURCE}/docker-compose.yml"

# ─────────────────────────────────────────────
#  Create Docker network
# ─────────────────────────────────────────────
header "Setting up Docker network"

if docker network inspect coolify &>/dev/null; then
  warn "Docker network 'coolify' already exists, reusing it"
else
  docker network create coolify
  success "Docker network 'coolify' created"
fi

# ─────────────────────────────────────────────
#  Pull images
# ─────────────────────────────────────────────
header "Pulling Docker images (this may take a moment...)"
docker compose --env-file "${COOLIFY_SOURCE}/.env" \
  -f "${COOLIFY_SOURCE}/docker-compose.yml" pull
success "Images pulled"

# ─────────────────────────────────────────────
#  Start services
# ─────────────────────────────────────────────
header "Starting Coolify services"
docker compose --env-file "${COOLIFY_SOURCE}/.env" \
  -f "${COOLIFY_SOURCE}/docker-compose.yml" up -d
success "Services started"

# ─────────────────────────────────────────────
#  Wait for Coolify to be healthy
# ─────────────────────────────────────────────
header "Waiting for Coolify to become healthy"
RETRIES=30
until docker inspect --format='{{.State.Health.Status}}' coolify 2>/dev/null | grep -q "healthy"; do
  RETRIES=$((RETRIES - 1))
  if [[ $RETRIES -le 0 ]]; then
    warn "Coolify did not become healthy in time. Check logs: docker logs coolify"
    break
  fi
  echo -ne "  Waiting... (${RETRIES} retries left)\r"
  sleep 3
done
echo ""
success "Coolify is healthy"

# ─────────────────────────────────────────────
#  Done — Summary
# ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║        Coolify Installation Complete! 🎉          ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Dashboard URL:${NC}       ${APP_URL}"
echo -e "  ${BOLD}Realtime URL:${NC}        ${REALTIME_URL}"
echo ""
echo -e "  ${BOLD}Config directory:${NC}    ${COOLIFY_BASE}"
echo -e "  ${BOLD}Compose file:${NC}        ${COOLIFY_SOURCE}/docker-compose.yml"
echo -e "  ${BOLD}Environment file:${NC}    ${COOLIFY_SOURCE}/.env"
echo -e "  ${BOLD}SSH key:${NC}             ${COOLIFY_BASE}/ssh/keys/id.root@host.docker.internal"
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "  • View logs:    docker logs -f coolify"
echo -e "  • Stop:         docker compose --env-file ${COOLIFY_SOURCE}/.env -f ${COOLIFY_SOURCE}/docker-compose.yml down"
echo -e "  • Restart:      docker compose --env-file ${COOLIFY_SOURCE}/.env -f ${COOLIFY_SOURCE}/docker-compose.yml restart"
echo -e "  • Update:       docker compose --env-file ${COOLIFY_SOURCE}/.env -f ${COOLIFY_SOURCE}/docker-compose.yml pull && docker compose ... up -d"
echo ""
echo -e "  ${YELLOW}Note:${NC} Make sure ports ${BOLD}8080${NC} and ${BOLD}6001${NC} are forwarded and set to ${BOLD}Public${NC} in your Codespace Ports tab."
echo ""
