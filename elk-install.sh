#!/usr/bin/env bash
# =============================================================================
# elk-install.sh
# ELK Stack Lab - Full Install Script
# THM: Elastic Setting up a SOC Lab | Kali ARM64 | Elastic 9.2.4
#
# Usage:
#   chmod +x elk-install.sh
#   ./elk-install.sh           # fresh install
#   ./elk-install.sh --wipe    # tear down everything and reinstall from scratch
#   ./elk-install.sh --restart # just restart containers (no API calls)
#   ./elk-install.sh --help    # usage
#
# Run as your normal user - NOT root. Uses sudo internally where needed.
# =============================================================================

set -euo pipefail

# --- Colours -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()    { echo -e "${GREEN}[+]${NC} $*"; }
info()   { echo -e "${CYAN}[*]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}========== $* ==========${NC}"; }

# --- Config ------------------------------------------------------------------
STACK_VERSION="9.2.4"
ELASTIC_PASSWORD="Change_me!"     # <------Change this!
KIBANA_PASSWORD="Change_me!"      # <------Change this!
ENCRYPTION_KEY="soc-lab-training-key-32chars-long!"
LAB_DIR="$HOME/elk-lab"
COMPOSE_TIMEOUT=200

# --- Argument parsing --------------------------------------------------------
MODE="install"
for arg in "$@"; do
    case $arg in
        --wipe)    MODE="wipe" ;;
        --restart) MODE="restart" ;;
        --help|-h)
            echo "Usage: $0 [--wipe | --restart | --help]"
            echo ""
            echo "  (no flag)   Full install on fresh VM"
            echo "  --wipe      Tear down stack + volumes, reinstall from scratch"
            echo "  --restart   Just restart containers (no API calls, uses existing .env)"
            exit 0
            ;;
        *) error "Unknown argument: $arg. Use --help for usage." ;;
    esac
done

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

header "Pre-flight Checks"

# Check default passwords have been changed
if [ "$ELASTIC_PASSWORD" = "Change_me!" ]; then
    echo ""
    echo -e "${RED}[!] You must change the default passwords before running this script.${NC}"
    echo -e "${RED}    Edit lines 35-36 in elk-install.sh and set your own passwords.${NC}"
    echo ""
    exit 1
fi

# Must NOT be root
if [ "$EUID" -eq 0 ]; then
    error "Do not run as root. Run as your normal user - sudo is used internally where needed."
fi
log "Running as user: $USER"

# sudo check
if ! sudo -n true 2>/dev/null; then
    info "This script needs sudo for some steps. You may be prompted for your password."
    sudo true || error "sudo failed - ensure $USER has sudo privileges"
fi
log "sudo access confirmed"

# Docker group check
DOCKER_WORKS=false
if docker info &>/dev/null 2>&1; then
    DOCKER_WORKS=true
fi

if $DOCKER_WORKS; then
    log "Docker socket accessible"
    DOCKER_CMD="docker"
    COMPOSE_CMD="docker-compose"
else
    if groups "$USER" | grep -q '\bdocker\b'; then
        echo ""
        echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  Docker socket permission denied                         ║${NC}"
        echo -e "${RED}║                                                          ║${NC}"
        echo -e "${RED}║  You are in the docker group but the session has not     ║${NC}"
        echo -e "${RED}║  picked it up yet. Fix with ONE of these options:        ║${NC}"
        echo -e "${RED}║                                                          ║${NC}"
        echo -e "${RED}║  Option A (recommended): log out and back in, then       ║${NC}"
        echo -e "${RED}║    re-run this script                                    ║${NC}"
        echo -e "${RED}║                                                          ║${NC}"
        echo -e "${RED}║  Option B (this session only):                           ║${NC}"
        echo -e "${RED}║    newgrp docker                                         ║${NC}"
        echo -e "${RED}║    ./elk-install.sh $*                                   ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        exit 1
    else
        warn "User $USER is NOT in the docker group"
        warn "Docker commands will use sudo for this session"
        warn "After install: log out and back in so group takes effect"
        DOCKER_CMD="sudo docker"
        COMPOSE_CMD="sudo docker-compose"
    fi
fi

# Disk space check - auto-clean apt cache if under 8GB
AVAIL_GB=$(df -BG "$HOME" | awk 'NR==2 {gsub("G",""); print $4}')
if [ "$AVAIL_GB" -lt 8 ]; then
    warn "Disk space: ${AVAIL_GB}GB available - running apt-get clean to free cache..."
    sudo apt-get clean
    sudo apt-get autoremove -y -qq 2>/dev/null || true
    AVAIL_GB=$(df -BG "$HOME" | awk 'NR==2 {gsub("G",""); print $4}')
    log "Disk space after cleanup: ${AVAIL_GB}GB available"
else
    log "Disk space: ${AVAIL_GB}GB available"
fi
if [ "$AVAIL_GB" -lt 5 ]; then
    error "Insufficient disk space: ${AVAIL_GB}GB free. Need at least 5GB. Free space manually and retry."
fi

# =============================================================================
# --restart MODE
# =============================================================================

if [ "$MODE" = "restart" ]; then
    header "Restart Mode"

    [ -f "$LAB_DIR/docker-compose.yml" ] || error "No docker-compose.yml in $LAB_DIR. Run without --restart for fresh install."
    [ -f "$LAB_DIR/.env" ]               || error "No .env in $LAB_DIR. Run without --restart for fresh install."

    cd "$LAB_DIR"

    grep -q "FLEET_TOKEN=PLACEHOLDER\|FLEET_TOKEN=REPLACE_ME" .env \
        && error "FLEET_TOKEN not set in .env. Run a full install first."
    grep -q "AGENT_ENROLLMENT_TOKEN=PLACEHOLDER\|AGENT_ENROLLMENT_TOKEN=REPLACE_ME" .env \
        && error "AGENT_ENROLLMENT_TOKEN not set. Run a full install first."

    log "Setting vm.max_map_count..."
    sudo sysctl -w vm.max_map_count=262144 > /dev/null

    log "Starting all containers..."
    COMPOSE_HTTP_TIMEOUT=$COMPOSE_TIMEOUT $COMPOSE_CMD up -d

    info "Waiting for stack (~90 sec)..."
    sleep 30
    $COMPOSE_CMD ps

    echo ""
    echo -e "${BOLD}${GREEN}Stack restarted.${NC}"
    echo -e "  Kibana:  http://localhost:5601  (elastic / ${ELASTIC_PASSWORD})"
    echo -e "  ES:      http://localhost:9200"
    echo -e "  Fleet:   http://localhost:8220"
    exit 0
fi

# =============================================================================
# --wipe MODE
# =============================================================================

if [ "$MODE" = "wipe" ]; then
    header "Wipe Mode"

    warn "This will DESTROY all containers, volumes, and data in $LAB_DIR"
    read -rp "Are you sure? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

    if [ -f "$LAB_DIR/docker-compose.yml" ]; then
        cd "$LAB_DIR"
        log "Tearing down stack and wiping volumes..."
        COMPOSE_HTTP_TIMEOUT=$COMPOSE_TIMEOUT $COMPOSE_CMD down -v 2>/dev/null || true
    fi

    for name in elasticsearch kibana fleet-server elastic-agent; do
        $DOCKER_CMD rm -f "$name" 2>/dev/null || true
    done
    for vol in elk-lab_es-data elk-lab_kibana-data elk-lab_fleet-data elk-lab_agent-data; do
        $DOCKER_CMD volume rm "$vol" 2>/dev/null || true
    done

    log "Wipe complete - proceeding with fresh install"
    MODE="wipe_install"
fi

# =============================================================================
# PHASE 1 - Prerequisites
# =============================================================================

header "PHASE 1 - Prerequisites"

sudo sysctl -w vm.max_map_count=262144 > /dev/null
log "vm.max_map_count=262144 set"

if ! grep -q "vm.max_map_count" /etc/sysctl.conf 2>/dev/null; then
    echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf > /dev/null
    log "Persisted to /etc/sysctl.conf"
fi

if ! command -v docker &>/dev/null; then
    log "Installing docker.io..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker.io
    sudo systemctl enable docker --now
    sudo usermod -aG docker "$USER"
    warn "Added $USER to docker group"
    warn "After this script finishes: log out and back in for group to take effect"
    DOCKER_CMD="sudo docker"
    COMPOSE_CMD="sudo docker-compose"
else
    log "Docker: $($DOCKER_CMD --version)"
fi

if ! command -v docker-compose &>/dev/null; then
    log "Installing docker-compose..."
    if ! sudo apt-get install -y -qq docker-compose 2>/dev/null; then
        warn "apt install failed, trying plugin method..."
        ARCH=$(uname -m)
        sudo mkdir -p /usr/local/lib/docker/cli-plugins
        sudo curl -SL \
            "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${ARCH}" \
            -o /usr/local/lib/docker/cli-plugins/docker-compose
        sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
        printf '#!/bin/bash\ndocker compose "$@"\n' | sudo tee /usr/local/bin/docker-compose > /dev/null
        sudo chmod +x /usr/local/bin/docker-compose
    fi
fi
log "docker-compose: $($COMPOSE_CMD --version)"

if [ "$MODE" != "wipe_install" ]; then
    if [ -f "$LAB_DIR/.env" ] && grep -qv "FLEET_TOKEN=PLACEHOLDER" "$LAB_DIR/.env" 2>/dev/null; then
        warn "Existing install detected in $LAB_DIR with tokens already set."
        warn "Use --wipe to start fresh, or --restart to just bring containers back up."
        read -rp "Continue with full reinstall anyway? [y/N] " yn
        [[ "$yn" =~ ^[Yy]$ ]] || { info "Tip: use './elk-install.sh --restart'"; exit 0; }
    fi
fi

# =============================================================================
# PHASE 2 - Create Lab Files
# =============================================================================

header "PHASE 2 - Create Lab Directory and Files"

mkdir -p "$LAB_DIR"
cd "$LAB_DIR"
log "Lab directory: $LAB_DIR"

cat > docker-compose.yml << 'EOF'
services:

  es01:
    image: docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION}
    container_name: elasticsearch
    environment:
      - node.name=es01
      - cluster.name=lab-cluster
      - discovery.type=single-node
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
      - xpack.security.enabled=true
      - xpack.security.http.ssl.enabled=false
      - xpack.ml.enabled=false
      - ES_JAVA_OPTS=-Xms512m -Xmx512m
      - cluster.routing.allocation.disk.threshold_enabled=false
      - action.destructive_requires_name=false
      - indices.recovery.max_bytes_per_sec=50mb
    ulimits:
      memlock:
        soft: -1
        hard: -1
    volumes:
      - es-data:/usr/share/elasticsearch/data
    ports:
      - "9200:9200"
    healthcheck:
      test: ["CMD-SHELL", "curl -sf -u elastic:${ELASTIC_PASSWORD} http://localhost:9200/_cluster/health | grep -qE '(green|yellow)'"]
      interval: 10s
      timeout: 10s
      retries: 30
      start_period: 40s
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  kibana:
    image: docker.elastic.co/kibana/kibana:${STACK_VERSION}
    container_name: kibana
    depends_on:
      - es01
    environment:
      - SERVERNAME=kibana
      - ELASTICSEARCH_HOSTS=http://es01:9200
      - ELASTICSEARCH_USERNAME=kibana_system
      - ELASTICSEARCH_PASSWORD=${KIBANA_PASSWORD}
      - XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY=${ENCRYPTION_KEY}
      - XPACK_SECURITY_ENCRYPTIONKEY=${ENCRYPTION_KEY}
      - XPACK_REPORTING_ENCRYPTIONKEY=${ENCRYPTION_KEY}
      - TELEMETRY_OPTIN=false
    volumes:
      - kibana-data:/usr/share/kibana/data
    ports:
      - "5601:5601"
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:5601/api/status | grep -q available"]
      interval: 10s
      timeout: 10s
      retries: 30
      start_period: 60s
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  fleet-server:
    image: docker.elastic.co/elastic-agent/elastic-agent:${STACK_VERSION}
    container_name: fleet-server
    depends_on:
      - kibana
    ports:
      - "8220:8220"
    user: root
    environment:
      - FLEET_SERVER_ENABLE=true
      - FLEET_SERVER_ELASTICSEARCH_HOST=http://es01:9200
      - FLEET_SERVER_SERVICE_TOKEN=${FLEET_TOKEN}
      - FLEET_SERVER_POLICY_NAME=fleet-server-policy
      - FLEET_SERVER_INSECURE_HTTP=true
      - FLEET_SERVER_HOST=0.0.0.0
      - FLEET_SERVER_PORT=8220
      - KIBANA_FLEET_SETUP=1
      - KIBANA_HOST=http://kibana:5601
      - FLEET_INSECURE=true
    volumes:
      - fleet-data:/usr/share/elastic-agent
      - /var/log:/var/log:ro
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  elastic-agent:
    image: docker.elastic.co/elastic-agent/elastic-agent:${STACK_VERSION}
    container_name: elastic-agent
    depends_on:
      - fleet-server
    user: root
    environment:
      - FLEET_ENROLL=1
      - FLEET_URL=http://fleet-server:8220
      - FLEET_ENROLLMENT_TOKEN=${AGENT_ENROLLMENT_TOKEN}
      - FLEET_INSECURE=true
    volumes:
      - agent-data:/usr/share/elastic-agent
      - /var/run/docker.sock:/var/run/docker.sock:ro
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  es-data:
  kibana-data:
  fleet-data:
  agent-data:
EOF

cat > .env << EOF
STACK_VERSION=${STACK_VERSION}
ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
KIBANA_PASSWORD=${KIBANA_PASSWORD}
ENCRYPTION_KEY=${ENCRYPTION_KEY}
FLEET_TOKEN=PLACEHOLDER
AGENT_ENROLLMENT_TOKEN=PLACEHOLDER
EOF

log "Files written"

# =============================================================================
# PHASE 3 - Start ES + Kibana
# =============================================================================

header "PHASE 3 - Start Elasticsearch and Kibana"

log "Pulling images and starting ES + Kibana..."
info "(First pull: ~5-7 min. Subsequent runs: instant - images are cached)"
COMPOSE_HTTP_TIMEOUT=$COMPOSE_TIMEOUT $COMPOSE_CMD up -d es01 kibana

info "Waiting for Elasticsearch..."
elapsed=0
until curl -sf -u "elastic:${ELASTIC_PASSWORD}" \
    "http://localhost:9200/_cluster/health" \
    | python3 -c "import sys,json; s=json.load(sys.stdin)['status']; sys.exit(0 if s in ['green','yellow'] else 1)" \
    2>/dev/null; do
    sleep 5; elapsed=$((elapsed+5))
    echo -ne "  ${CYAN}[${elapsed}s]${NC} waiting for ES...\r"
    [ "$elapsed" -ge 180 ] && error "Elasticsearch did not start within 180s"
done
echo ""
log "Elasticsearch is up"

log "Setting kibana_system password..."
curl -s -u "elastic:${ELASTIC_PASSWORD}" \
    -X POST "http://localhost:9200/_security/user/kibana_system/_password" \
    -H 'Content-Type: application/json' \
    -d "{\"password\":\"${KIBANA_PASSWORD}\"}" -o /dev/null
log "kibana_system password set"

info "Waiting for Kibana (60-120s)..."
elapsed=0
until curl -sf "http://localhost:5601/api/status" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['status']['overall']['level'])" 2>/dev/null \
    | grep -q "available"; do
    sleep 5; elapsed=$((elapsed+5))
    level=$(curl -sf "http://localhost:5601/api/status" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['status']['overall']['level'])" 2>/dev/null \
        || echo "starting")
    echo -ne "  ${CYAN}[${elapsed}s]${NC} Kibana: $level\r"
    [ "$elapsed" -ge 300 ] && error "Kibana did not become available within 300s"
done
echo ""
log "Kibana is available"

# =============================================================================
# PHASE 4 - Fleet Service Token
# =============================================================================

header "PHASE 4 - Generate Fleet Service Token"

log "Generating Fleet service token..."
TOKEN_RESPONSE=$(curl -sf -u "elastic:${ELASTIC_PASSWORD}" \
    -X POST "http://localhost:9200/_security/service/elastic/fleet-server/credential/token/lab-token" \
    -H 'Content-Type: application/json')

FLEET_TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['token']['value'])" 2>/dev/null) \
    || error "Failed to parse Fleet token. Response: $TOKEN_RESPONSE"

sed -i "s|^FLEET_TOKEN=.*|FLEET_TOKEN=${FLEET_TOKEN}|" .env
log "Fleet service token generated and saved to .env"

# =============================================================================
# PHASE 5 - Fleet API Configuration
# =============================================================================

header "PHASE 5 - Fleet API Configuration (9.x workarounds)"

fleet_call() {
    local method="$1" path="$2" data="${3:-}"
    if [ -n "$data" ]; then
        curl -s -u "elastic:${ELASTIC_PASSWORD}" \
            -X "$method" "http://localhost:5601${path}" \
            -H 'Content-Type: application/json' \
            -H 'kbn-xsrf: true' \
            -d "$data" -o /dev/null -w "%{http_code}"
    else
        curl -s -u "elastic:${ELASTIC_PASSWORD}" \
            -X "$method" "http://localhost:5601${path}" \
            -H 'kbn-xsrf: true' \
            -o /dev/null -w "%{http_code}"
    fi
}

log "Registering Fleet Server host (http://fleet-server:8220)..."
code=$(fleet_call POST "/api/fleet/fleet_server_hosts" \
    '{"name":"fleet-server","host_urls":["http://fleet-server:8220"],"is_default":true}')
[[ "$code" =~ ^2 ]] && log "Fleet Server host registered (HTTP $code)" \
    || warn "Fleet Server host returned HTTP $code (may already exist - continuing)"

log "Creating Fleet Server Policy..."
code=$(fleet_call POST "/api/fleet/agent_policies" \
    '{"name":"Fleet Server Policy","namespace":"default","has_fleet_server":true}')
[[ "$code" =~ ^2 ]] && log "Fleet Server Policy created (HTTP $code)" \
    || warn "Fleet Server Policy returned HTTP $code (may already exist - continuing)"

# =============================================================================
# PHASE 6 - Start Fleet Server
# =============================================================================

header "PHASE 6 - Start Fleet Server"

log "Starting Fleet Server..."
COMPOSE_HTTP_TIMEOUT=$COMPOSE_TIMEOUT $COMPOSE_CMD up -d fleet-server

info "Waiting for Fleet Server on :8220 (up to 120s)..."
elapsed=0
while true; do
    if curl -sf "http://localhost:8220/api/status" &>/dev/null; then
        echo ""
        log "Fleet Server is ready"
        break
    fi
    if [ "$elapsed" -ge 120 ]; then
        warn "Fleet Server :8220 not responding after 120s - continuing anyway"
        break
    fi
    sleep 5; elapsed=$((elapsed+5))
    echo -ne "  ${CYAN}[${elapsed}s]${NC} waiting for Fleet Server...\r"
done

log "Waiting 15s for Fleet Server to register with Kibana..."
sleep 15

log "Fixing Fleet default output (localhost -> es01:9200)..."
code=$(fleet_call PUT "/api/fleet/outputs/fleet-default-output" \
    '{"name":"default","type":"elasticsearch","hosts":["http://es01:9200"],"is_default":true,"is_default_monitoring":true}')
[[ "$code" =~ ^2 ]] && log "Fleet output updated to http://es01:9200 (HTTP $code)" \
    || warn "Fleet output update returned HTTP $code - may need manual fix"

# =============================================================================
# PHASE 7 - Agent Enrollment Token
# =============================================================================

header "PHASE 7 - Get Agent Enrollment Token"

log "Fetching enrollment token for fleet-server-policy..."
KEYS_RESPONSE=$(curl -sf -u "elastic:${ELASTIC_PASSWORD}" \
    "http://localhost:5601/api/fleet/enrollment_api_keys" \
    -H 'kbn-xsrf: true')

AGENT_TOKEN=$(echo "$KEYS_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data.get('items', data.get('list', []))
for item in items:
    if item.get('policy_id') == 'fleet-server-policy' and item.get('active', True):
        print(item['api_key'])
        break
" 2>/dev/null) || true

if [ -z "$AGENT_TOKEN" ]; then
    warn "Could not get enrollment token automatically"
    warn "Get it manually: Kibana -> Fleet -> Enrollment tokens"
    warn "Then: sed -i 's/AGENT_ENROLLMENT_TOKEN=.*/AGENT_ENROLLMENT_TOKEN=YOUR_TOKEN/' ~/elk-lab/.env"
    warn "Then: docker-compose up -d elastic-agent"
    AGENT_TOKEN="MANUAL_SETUP_REQUIRED"
else
    log "Enrollment token obtained"
    sed -i "s|^AGENT_ENROLLMENT_TOKEN=.*|AGENT_ENROLLMENT_TOKEN=${AGENT_TOKEN}|" .env
fi

# =============================================================================
# PHASE 8 - Start Elastic Agent
# =============================================================================

header "PHASE 8 - Start Elastic Agent"

if [ "$AGENT_TOKEN" = "MANUAL_SETUP_REQUIRED" ]; then
    warn "Skipping elastic-agent - get token manually (see above)"
else
    log "Starting Elastic Agent..."
    COMPOSE_HTTP_TIMEOUT=$COMPOSE_TIMEOUT $COMPOSE_CMD up -d elastic-agent
    log "Elastic Agent started"
    sleep 10
fi

# =============================================================================
# PHASE 9 - Ingest Pipeline
# =============================================================================

header "PHASE 9 - Create VPN Ingest Pipeline"

log "Creating vpn.logs.pipeline..."
curl -sf -u "elastic:${ELASTIC_PASSWORD}" \
    -X PUT "http://localhost:9200/_ingest/pipeline/vpn.logs.pipeline" \
    -H 'Content-Type: application/json' \
    -d '{
  "processors": [
    {
      "grok": {
        "field": "message",
        "patterns": ["%{TIMESTAMP_ISO8601:event.time_string} %{WORD:event.action} %{USER:user.name} %{IP:source.ip} %{IP:vpn.client.ip} %{NOTSPACE:vpn.server.region}"]
      }
    },
    {
      "date": {
        "field": "event.time_string",
        "formats": ["ISO8601"],
        "target_field": "@timestamp"
      }
    }
  ]
}' > /dev/null
log "Pipeline created: vpn.logs.pipeline"

# =============================================================================
# PHASE 10 - VPN Log Data
# =============================================================================

header "PHASE 10 - Generate VPN Log Data"

log "Generating 500 VPN log entries at /var/log/vpnlog..."
sudo python3 - << 'PYEOF'
import datetime, random

LOG_FILE = "/var/log/vpnlog"

def generate_logs():
    random.seed(42)
    now = datetime.datetime.now(datetime.timezone.utc)
    current_time = now - datetime.timedelta(hours=16)
    user_names = [
        "j.jones", "d.wade", "s.stillhour", "c.lin", "s.summer",
        "t.binlao", "c.yamashi", "l.stone", "o.devarius", "p.mallow",
        "m.chen", "a.patel", "r.garcia", "k.mueller", "e.dubois",
        "h.tanaka", "s.novak", "f.ahmed", "v.rossi", "j.smith"
    ]
    user_weights = [1] * len(user_names)
    user_weights[user_names.index("s.summer")] = 5
    locations = ["us-east-1", "us-west-1", "uk-london"]
    loc_weights = [1, 1, 3]
    user_configs = {}
    for i, name in enumerate(user_names):
        user_configs[name] = {
            "source_ip": f"72.14.{20+i}.1",
            "vpn_ip": f"10.10.10.{100+i}",
            "home_loc": random.choices(locations, weights=loc_weights, k=1)[0]
        }
    user_state = {name: False for name in user_names}
    logs = []
    total_events = 500
    auth_fail_indices = random.sample(range(total_events), 40)
    mallow_fails = auth_fail_indices[:25]
    while len(logs) < total_events:
        idx = len(logs)
        jitter = random.randint(60, 150)
        current_time += datetime.timedelta(seconds=jitter)
        if current_time > now:
            current_time = now
        ts = current_time.strftime("%Y-%m-%dT%H:%M:%SZ")
        if idx in mallow_fails:
            selected_user = "p.mallow"
        else:
            selected_user = random.choices(user_names, weights=user_weights, k=1)[0]
        config = user_configs[selected_user]
        src_ip = config["source_ip"]
        vpn_ip = config["vpn_ip"]
        loc = config["home_loc"]
        if idx in auth_fail_indices:
            action = "auth_fail"
            logs.append(f"{ts} {action} {selected_user} {src_ip} 0.0.0.0 {loc}\n")
        else:
            if not user_state[selected_user]:
                action = "connection_start"
                user_state[selected_user] = True
            else:
                action = "connection_stop"
                user_state[selected_user] = False
            logs.append(f"{ts} {action} {selected_user} {src_ip} {vpn_ip} {loc}\n")
    with open(LOG_FILE, "w") as f:
        f.writelines(logs)
    print(f"Successfully generated logs in {LOG_FILE}")

generate_logs()
PYEOF

log "vpnlog: $(wc -l < /var/log/vpnlog) entries written"

if $DOCKER_CMD exec fleet-server ls /var/log/vpnlog &>/dev/null 2>&1; then
    log "fleet-server can see /var/log/vpnlog"
else
    warn "fleet-server cannot see /var/log/vpnlog - check volume mount"
fi

# =============================================================================
# PHASE 11 - Final Status
# =============================================================================

header "PHASE 11 - Final Status"

$COMPOSE_CMD ps

echo ""
info "Waiting 20s for data to flow..."
sleep 20

DOC_COUNT=$(curl -sf -u "elastic:${ELASTIC_PASSWORD}" \
    "http://localhost:9200/logs-*/_count" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['count'])" 2>/dev/null || echo "unknown")
log "Documents in logs-*: $DOC_COUNT"

# =============================================================================
# DONE
# =============================================================================

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║        ELK Lab Setup Complete            ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Kibana:${NC}         http://localhost:5601"
echo -e "  ${CYAN}Kibana login:${NC}   elastic / ${ELASTIC_PASSWORD}"
echo -e "  ${CYAN}Elasticsearch:${NC}  http://localhost:9200"
echo -e "  ${CYAN}ES login:${NC}       elastic / ${ELASTIC_PASSWORD}"
echo -e "  ${CYAN}Fleet Server:${NC}   http://localhost:8220"
echo ""
echo -e "  ${BOLD}Next step in Kibana:${NC}"
echo -e "  Management -> Integrations -> Custom Logs (Filestream)"
echo -e "  Path: /var/log/vpnlog  |  Pipeline: vpn.logs.pipeline"
echo -e "  Policy: Fleet Server Policy  |  Save and deploy"
echo ""
echo -e "  ${BOLD}Discover VPN logs:${NC}"
echo -e '  Query: event.module: "filestream"'
echo -e "  Time:  Last 24 hours"
echo ""
echo -e "  ${BOLD}${YELLOW}Lifecycle:${NC}"
echo -e "  Shutdown:  cd ~/elk-lab && docker-compose down"
echo -e "  Restart:   ./elk-install.sh --restart"
echo -e "  Full wipe: ./elk-install.sh --wipe"
echo ""
if ! $DOCKER_WORKS && ! groups "$USER" | grep -q '\bdocker\b'; then
    echo -e "  ${BOLD}${RED}ACTION REQUIRED:${NC} Log out and back in so docker group takes effect"
    echo -e "  After that you can run docker-compose without sudo"
    echo ""
fi
echo -e "  Lab dir: $LAB_DIR"
echo ""
