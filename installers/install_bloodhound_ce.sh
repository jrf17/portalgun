#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# BloodHound CE Installation Script
# Installs BloodHound Community Edition via Docker
# ═══════════════════════════════════════════════════════════════════

set -e

# Configuration
BLOODHOUND_PORT=1338
INSTALL_DIR="/opt/bloodhound-ce"
SEED_DIR="${SEED_DIR:-/home/kali/portalgun/seeds/bloodhound_seed}"
COMPOSE_PROJECT="bloodhound-ce"
CLI_VERSION="v0.2.1"
CLI_URL="https://github.com/SpecterOps/bloodhound-cli/releases/download/${CLI_VERSION}/bloodhound-cli-linux-amd64.tar.gz"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[+]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[-]${NC} $1"; }

# ───────────────────────────────────────────────────────────────────
# Pre-flight checks
# ───────────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    print_error "Please run as root (sudo)"
    exit 1
fi

if ! command -v docker &> /dev/null; then
    print_error "Docker is not installed. Please install docker first."
    exit 1
fi

if ! docker info &> /dev/null; then
    print_error "Docker daemon is not running"
    exit 1
fi

# Detect docker compose command (plugin vs standalone)
if docker compose version &>/dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    print_error "Neither 'docker compose' nor 'docker-compose' found. Install docker-compose."
    exit 1
fi
print_status "Using: $DOCKER_COMPOSE"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "           BloodHound CE Installation"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Configuration:"
echo "  Port:     $BLOODHOUND_PORT"
echo "  Install:  $INSTALL_DIR"
echo "  Seed:     $SEED_DIR"
echo ""

# ───────────────────────────────────────────────────────────────────
# Create install directory
# ───────────────────────────────────────────────────────────────────
print_status "Creating install directory..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ───────────────────────────────────────────────────────────────────
# Download bloodhound-cli
# ───────────────────────────────────────────────────────────────────
if [ ! -f "$INSTALL_DIR/bloodhound-cli" ]; then
    print_status "Downloading bloodhound-cli ${CLI_VERSION}..."
    curl -sL "$CLI_URL" -o /tmp/bloodhound-cli.tar.gz
    tar xzf /tmp/bloodhound-cli.tar.gz -C "$INSTALL_DIR"
    rm -f /tmp/bloodhound-cli.tar.gz
    chmod +x "$INSTALL_DIR/bloodhound-cli"
    print_success "bloodhound-cli downloaded"
else
    print_success "bloodhound-cli already exists"
fi

# ───────────────────────────────────────────────────────────────────
# Create custom docker-compose with port 1338
# ───────────────────────────────────────────────────────────────────
print_status "Creating docker-compose configuration..."

cat > "$INSTALL_DIR/docker-compose.yml" << 'EOF'
services:
  app-db:
    image: docker.io/library/postgres:16
    environment:
      POSTGRES_USER: bloodhound
      POSTGRES_PASSWORD: bloodhoundcommunityedition
      POSTGRES_DB: bloodhound
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U bloodhound -d bloodhound"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    restart: unless-stopped

  graph-db:
    image: docker.io/library/neo4j:4.4.42
    environment:
      NEO4J_AUTH: neo4j/bloodhoundcommunityedition
      NEO4J_dbms_allow__upgrade: "true"
    volumes:
      - neo4j-data:/data
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://localhost:7474 || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    restart: unless-stopped

  bloodhound:
    image: docker.io/specterops/bloodhound:${BLOODHOUND_TAG:-latest}
    environment:
      bhe_disable_cypher_qc: "false"
      bhe_database_connection: user=bloodhound password=bloodhoundcommunityedition dbname=bloodhound host=app-db
      bhe_neo4j_connection: neo4j://neo4j:bloodhoundcommunityedition@graph-db:7687/
    ports:
      - ${BLOODHOUND_HOST:-0.0.0.0}:${BLOODHOUND_PORT:-1338}:8080
    depends_on:
      app-db:
        condition: service_healthy
      graph-db:
        condition: service_healthy
    restart: unless-stopped

volumes:
  postgres-data:
  neo4j-data:
EOF

# Create .env file
cat > "$INSTALL_DIR/.env" << EOF
BLOODHOUND_HOST=0.0.0.0
BLOODHOUND_PORT=${BLOODHOUND_PORT}
BLOODHOUND_TAG=latest
EOF

print_success "Docker configuration created"

# ───────────────────────────────────────────────────────────────────
# Create bloodhound-ce command wrapper
# ───────────────────────────────────────────────────────────────────
print_status "Creating bloodhound-ce command..."

cat > /usr/local/bin/bloodhound-ce << 'WRAPPER'
#!/bin/bash
# BloodHound CE wrapper script

INSTALL_DIR="/opt/bloodhound-ce"
cd "$INSTALL_DIR"

# Detect docker compose command
if docker compose version &>/dev/null; then
    DC="docker compose"
elif command -v docker-compose &>/dev/null; then
    DC="docker-compose"
else
    echo "Error: docker-compose not found"
    exit 1
fi

case "$1" in
    start)
        echo "Starting BloodHound CE on port 1338..."
        $DC up -d
        echo ""
        echo "BloodHound CE started!"
        echo "  URL: http://$(hostname -I | awk '{print $1}'):1338"
        echo "  Login: admin / <use your existing admin password>"
        ;;
    stop)
        echo "Stopping BloodHound CE..."
        $DC down
        ;;
    restart)
        echo "Restarting BloodHound CE..."
        $DC restart
        ;;
    status)
        $DC ps
        ;;
    logs)
        $DC logs -f bloodhound
        ;;
    resetpwd)
        "$INSTALL_DIR/bloodhound-cli" -f "$INSTALL_DIR/docker-compose.yml" resetpwd
        ;;
    update)
        echo "Updating BloodHound CE..."
        $DC pull
        $DC up -d
        ;;
    *)
        echo "BloodHound CE Management"
        echo ""
        echo "Usage: bloodhound-ce <command>"
        echo ""
        echo "Commands:"
        echo "  start      Start BloodHound CE"
        echo "  stop       Stop BloodHound CE"
        echo "  restart    Restart BloodHound CE"
        echo "  status     Show container status"
        echo "  logs       Follow BloodHound logs"
        echo "  resetpwd   Reset admin password"
        echo "  update     Update to latest version"
        echo ""
        echo "URL: http://localhost:1338"
        echo "Login: admin / <your admin password>"
        ;;
esac
WRAPPER

chmod +x /usr/local/bin/bloodhound-ce
print_success "bloodhound-ce command created"

# ───────────────────────────────────────────────────────────────────
# Pull images
# ───────────────────────────────────────────────────────────────────
print_status "Pulling Docker images (this may take a few minutes)..."
cd "$INSTALL_DIR"
$DOCKER_COMPOSE pull

# ───────────────────────────────────────────────────────────────────
# Restore from seed (preserves admin password from prior install)
# ───────────────────────────────────────────────────────────────────
PG_SEED="$SEED_DIR/postgres-data.tgz"
N4J_SEED="$SEED_DIR/neo4j-data.tgz"
PG_VOL="${COMPOSE_PROJECT}_postgres-data"
N4J_VOL="${COMPOSE_PROJECT}_neo4j-data"

if [ -f "$PG_SEED" ] && [ -f "$N4J_SEED" ]; then
    print_status "Seed found at $SEED_DIR — restoring volumes..."

    print_status "  resetting named volumes..."
    docker volume rm -f "$PG_VOL" "$N4J_VOL" >/dev/null 2>&1 || true
    docker volume create "$PG_VOL" >/dev/null
    docker volume create "$N4J_VOL" >/dev/null

    print_status "  restoring postgres-data ($(du -h "$PG_SEED" | cut -f1))..."
    docker run --rm -v "$PG_VOL":/data -v "$SEED_DIR":/backup:ro busybox \
        tar xzf /backup/postgres-data.tgz -C /data

    print_status "  restoring neo4j-data ($(du -h "$N4J_SEED" | cut -f1))..."
    docker run --rm -v "$N4J_VOL":/data -v "$SEED_DIR":/backup:ro busybox \
        tar xzf /backup/neo4j-data.tgz -C /data

    print_success "Seed restored — admin password preserved from prior install"
    SEEDED=1
else
    print_warning "No seed at $SEED_DIR — bloodhound will generate a random initial password"
    SEEDED=0
fi

# ───────────────────────────────────────────────────────────────────
# Start
# ───────────────────────────────────────────────────────────────────
print_status "Starting BloodHound CE..."
$DOCKER_COMPOSE up -d

print_status "Waiting for services to start..."
sleep 15

# ───────────────────────────────────────────────────────────────────
# Done
# ───────────────────────────────────────────────────────────────────
IP=$(hostname -I | awk '{print $1}')

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "           ${GREEN}BloodHound CE Installation Complete!${NC}"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Access:"
echo "  URL:      http://${IP}:${BLOODHOUND_PORT}"
echo "  Username: admin"
if [ "$SEEDED" = "1" ]; then
    echo "  Password: <preserved from seed>"
else
    echo "  Password: see logs — 'bloodhound-ce logs | grep \"Initial Password\"'"
fi
echo ""
echo "Commands:"
echo "  bloodhound-ce start    - Start BloodHound"
echo "  bloodhound-ce stop     - Stop BloodHound"
echo "  bloodhound-ce status   - Check status"
echo "  bloodhound-ce logs     - View logs"
echo ""

exit 0
