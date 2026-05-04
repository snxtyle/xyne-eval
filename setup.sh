#!/bin/bash

set -euo pipefail

echo "=========================================="
echo "  Xyne Eval Setup + Doc Ingestion"
echo "=========================================="

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}[SETUP]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Detect if running as root for sudo usage
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# Error handler - captures logs before exit but keeps tmux for debugging
cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        print_error "Script failed with exit code $exit_code"
        
        # Capture debug information
        print_error "=== DEBUG INFORMATION ==="
        
        # Check if tmux session exists
        if tmux has-session -t xyne 2>/dev/null; then
            print_error "tmux session exists. Capturing logs..."
            
            # Create output directory for logs
            local log_dir="${SCRIPT_DIR}/logs"
            mkdir -p "$log_dir"
            
            # Capture logs from each window if possible
            for window in docker server frontend sync; do
                tmux capture-pane -t xyne:$window -p 2>/dev/null > "${log_dir}/${window}.log" && \
                    print_error "Captured ${window} logs to: ${log_dir}/${window}.log" || \
                    print_error "Could not capture ${window} logs"
            done
            
            # Show last 20 lines of server window
            print_error ""
            print_error "=== SERVER WINDOW LOGS (last 20 lines) ==="
            tmux capture-pane -t xyne:server -p 2>/dev/null | tail -20 || print_error "No server logs available"
            
            print_error ""
            print_error "=== DOCKER CONTAINER STATUS ==="
            docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || print_error "Cannot get container status"
            
            print_error ""
            print_error "To debug manually: tmux attach -t xyne"
            print_error "Or view logs in: ${log_dir}/"
        else
            print_error "No tmux session found (was never created or was cleaned up)"
        fi
        
        print_error "========================"
    fi
    
    # Return original exit code
    return $exit_code
}
trap cleanup_on_error EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_AUTOMATION_DIR="${SCRIPT_DIR}/eval-automation"
DOCS_DIR="${EVAL_AUTOMATION_DIR}/docs"

export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

install_dependencies() {
    print_status "Installing required dependencies..."
    
    # Detect if we're in a container (Docker siblings pattern)
    local in_container=false
    if [ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
        in_container=true
        print_status "Running in container - detecting environment..."
    fi
    
    # Detect container-optimized OS (read-only root)
    local readonly_fs=false
    if ! touch /test_write_permission 2>/dev/null; then
        readonly_fs=true
        print_status "Detected read-only filesystem (Container-Optimized OS)"
    else
        rm -f /test_write_permission
    fi
    
    # Check if Docker is available via sibling mount
    local docker_sibling=false
    if [ -S /var/run/docker.sock ] || [ -S /run/docker.sock ]; then
        docker_sibling=true
        print_status "Docker socket detected (siblings mode)"
    fi
    
    # Only run apt-get if we're not on a read-only filesystem
    if [ "$readonly_fs" = false ]; then
        # Update package lists
        $SUDO apt-get update -qq 2>/dev/null || {
            print_warning "apt-get update failed - may be in container without apt"
        }
        
        # Check if Docker is already available
        local docker_available=false
        if command -v docker &> /dev/null && docker ps &> /dev/null 2>&1; then
            docker_available=true
        fi
        
        # Install required packages
        # Note: Even with docker_sibling (socket available), we still need docker.io CLI
        local packages="apt-utils lsof tmux curl jq unzip"
        if ! command -v docker &> /dev/null; then
            packages="$packages docker.io"
        fi
        # Only install docker-compose standalone if docker isn't available AND no socket
        if [ "$docker_sibling" = false ] && ! command -v docker &> /dev/null; then
            packages="$packages docker-compose"
        fi
        
        for pkg in $packages; do
            if ! command -v "$pkg" &> /dev/null && ! dpkg -l "$pkg" &> /dev/null 2>&1; then
                print_status "Installing $pkg..."
                $SUDO apt-get install -y -qq "$pkg" 2>/dev/null || {
                    print_warning "Failed to install $pkg, continuing..."
                }
            fi
        done
        
        # Only try to start docker service if we installed it
        if [ "$docker_available" = false ] && [ "$docker_sibling" = false ] && command -v docker &> /dev/null; then
            print_status "Attempting to start Docker service..."
            $SUDO systemctl start docker 2>/dev/null || true
        fi
    else
        print_status "Skipping apt-get (read-only filesystem)"
    fi
    
    # Verify Docker is working (either native or sibling)
    if command -v docker &> /dev/null; then
        if docker ps &> /dev/null 2>&1; then
            print_status "Docker is operational"
        else
            print_warning "Docker command available but cannot connect"
            if [ "$docker_sibling" = true ]; then
                print_error "Docker socket detected but permission denied"
                print_error "Socket permissions: $(ls -la /var/run/docker.sock 2>/dev/null || ls -la /run/docker.sock 2>/dev/null || echo 'Socket not found')"
                print_error "Make sure the container user has access to the docker socket"
                print_error "Or run with --group-add $(stat -c '%g' /var/run/docker.sock 2>/dev/null || stat -c '%g' /run/docker.sock 2>/dev/null || echo 'docker')"
            fi
            return 1
        fi
    else
        print_error "Docker command not found. Cannot proceed without Docker."
        return 1
    fi
    
    # Install bun if not present
    if ! command -v bun &> /dev/null; then
        print_status "Installing bun..."
        if command -v unzip &> /dev/null; then
            curl -fsSL https://bun.sh/install | bash || {
                print_warning "Failed to install bun via official installer"
            }
        fi
        
        # Check if bun was installed, if not try npm as fallback
        if ! command -v bun &> /dev/null && command -v npm &> /dev/null; then
            print_status "Attempting to install bun via npm..."
            npm install -g bun 2>/dev/null || {
                print_warning "Failed to install bun via npm"
            }
        fi
        
        if ! command -v bun &> /dev/null; then
            print_warning "Could not install bun automatically"
            print_warning "Please install bun manually from https://bun.sh"
            return 1
        fi
        
        # Re-export PATH in case bun was just installed
        export BUN_INSTALL="$HOME/.bun"
        export PATH="$BUN_INSTALL/bin:$PATH"
    fi
    
    # Install docker-compose separately (it's often not included in docker.io)
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null 2>&1; then
        print_status "Installing docker-compose..."
        if [ "$readonly_fs" = false ]; then
            $SUDO apt-get install -y -qq docker-compose 2>/dev/null || {
                # Try alternative: install compose plugin via pip or standalone binary
                print_warning "Failed to install docker-compose via apt, trying standalone..."
                curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose 2>/dev/null && \
                $SUDO chmod +x /usr/local/bin/docker-compose 2>/dev/null || {
                    print_warning "Failed to install docker-compose standalone"
                }
            }
        fi
    fi
    
    print_status "Dependencies installed"
    
    # Install Node.js dependencies for server
    if [ -f "${SCRIPT_DIR}/server/package.json" ]; then
        if [ ! -d "${SCRIPT_DIR}/server/node_modules" ]; then
            print_status "Installing server dependencies..."
            cd "${SCRIPT_DIR}/server"
            if command -v bun &> /dev/null; then
                bun install || npm install || print_warning "Failed to install server dependencies"
            elif command -v npm &> /dev/null; then
                npm install || print_warning "Failed to install server dependencies"
            fi
            cd "${SCRIPT_DIR}"
        else
            print_status "Server dependencies already installed"
        fi
    fi
    
    # Install Node.js dependencies for frontend
    if [ -f "${SCRIPT_DIR}/frontend/package.json" ]; then
        if [ ! -d "${SCRIPT_DIR}/frontend/node_modules" ]; then
            print_status "Installing frontend dependencies..."
            cd "${SCRIPT_DIR}/frontend"
            if command -v npm &> /dev/null; then
                npm install || print_warning "Failed to install frontend dependencies"
            fi
            cd "${SCRIPT_DIR}"
        else
            print_status "Frontend dependencies already installed"
        fi
    fi
}

kill_existing_processes() {
    print_status "Killing existing processes on ports 3000 and 3010..."
    
    if command -v lsof &> /dev/null; then
        lsof -ti :3000 | xargs kill -9 2>/dev/null || true
        lsof -ti :3010 | xargs kill -9 2>/dev/null || true
    fi
    
    pkill -f "bun run.*server.ts" 2>/dev/null || true
    sleep 2
    print_status "Existing processes killed"
}

ensure_collection() {
    print_status "Ensuring collection exists in database..."
    
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed. Cannot create collection."
        return 1
    fi
    
    local collection_name="cl_eval_xyne_search"
    local collection_exists=$(docker exec xyne-db psql -U xyne -d xyne -t -c "SELECT COUNT(*) FROM collections WHERE name = '$collection_name';" 2>/dev/null || echo "0")
    
    if [ "$collection_exists" -eq "0" ] || [ -z "$collection_exists" ]; then
        print_status "Creating collection '$collection_name'..."
        local result=$(docker exec xyne-db psql -U xyne -d xyne -t -c "INSERT INTO collections (id, workspace_id, owner_id, name, vespa_doc_id, is_private, total_items) VALUES (gen_random_uuid(), 1, 1, '$collection_name', '${collection_name}_doc', false, 0) RETURNING id;" 2>/dev/null | tr -d ' ')
        
        if [ -n "$result" ]; then
            print_status "Collection created with ID: $result"
            export COLLECTION_ID="$result"
        else
            print_warning "Failed to create collection (database may not be ready yet)"
        fi
    else
        local collection_id=$(docker exec xyne-db psql -U xyne -d xyne -t -c "SELECT id FROM collections WHERE name = '$collection_name' LIMIT 1;" 2>/dev/null | tr -d ' ')
        print_status "Collection already exists: $collection_id"
        export COLLECTION_ID="$collection_id"
    fi
}

fix_env_settings() {
    print_status "Fixing environment settings..."
    
    # Fix LAYOUT_PARSING_BASE_URL in eval-automation/.env (Linux-compatible sed)
    if [ -f "$EVAL_AUTOMATION_DIR/.env" ]; then
        if grep -q "LAYOUT_PARSING_BASE_URL='https://.*ngrok" "$EVAL_AUTOMATION_DIR/.env" 2>/dev/null; then
            print_status "Commenting out expired ngrok URL in eval-automation/.env"
            sed -i "s|^LAYOUT_PARSING_BASE_URL=|# LAYOUT_PARSING_BASE_URL=|g" "$EVAL_AUTOMATION_DIR/.env"
        fi
    fi
    
    # Fix LAYOUT_PARSING_BASE_URL in server/.env (Linux-compatible sed)
    if [ -f "$SCRIPT_DIR/server/.env" ]; then
        if grep -q "LAYOUT_PARSING_BASE_URL='https://.*ngrok" "$SCRIPT_DIR/server/.env" 2>/dev/null; then
            print_status "Commenting out expired ngrok URL in server/.env"
            sed -i "s|^LAYOUT_PARSING_BASE_URL=|# LAYOUT_PARSING_BASE_URL=|g" "$SCRIPT_DIR/server/.env"
        fi
    fi
}

ensure_directories() {
    print_status "Creating required directories..."
    
    # Create results directory
    mkdir -p "$SCRIPT_DIR/server/results"
    
    # Create QA input directory and copy file
    local qa_input_dir="$SCRIPT_DIR/server/xyne-evals/qa_pipelines/generation_through_vespa/output"
    mkdir -p "$qa_input_dir"
    
    if [ -f "$EVAL_AUTOMATION_DIR/qa_output_hard.json" ] && [ ! -f "$qa_input_dir/qa_output_hard.json" ]; then
        print_status "Copying QA file to expected location..."
        cp "$EVAL_AUTOMATION_DIR/qa_output_hard.json" "$qa_input_dir/"
    fi
}

ensure_env_file() {
    print_status "Ensuring server .env file has required variables..."
    
    local env_file="$SCRIPT_DIR/server/.env"
    local env_changed=false
    
    if [ ! -f "$env_file" ]; then
        print_status "Creating server/.env from defaults..."
        if [ -f "$SCRIPT_DIR/deployment/portable/.env.default" ]; then
            cp "$SCRIPT_DIR/deployment/portable/.env.default" "$env_file"
        else
            touch "$env_file"
        fi
        env_changed=true
    fi
    
    # Generate random base64 strings for required secrets if not set
    local required_vars="ENCRYPTION_KEY SERVICE_ACCOUNT_ENCRYPTION_KEY JWT_SECRET ACCESS_TOKEN_SECRET REFRESH_TOKEN_SECRET"
    for var in $required_vars; do
        if ! grep -q "^${var}=" "$env_file" 2>/dev/null || grep -q "^${var}=$" "$env_file" 2>/dev/null; then
            # Generate 256-bit (32 bytes) base64-encoded key
            local value=$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64)
            if grep -q "^${var}=" "$env_file" 2>/dev/null; then
                sed -i "s|^${var}=.*|${var}=${value}|" "$env_file"
            else
                echo "${var}=${value}" >> "$env_file"
            fi
            print_status "Set ${var} in .env"
            env_changed=true
        fi
    done
    
    # Set DATABASE_HOST to localhost for local dev (not docker network hostname)
    if grep -q "^DATABASE_HOST=xyne-db" "$env_file" 2>/dev/null; then
        sed -i "s|^DATABASE_HOST=xyne-db|DATABASE_HOST=localhost|" "$env_file"
        print_status "Set DATABASE_HOST=localhost for local dev"
        env_changed=true
    fi
    
    # Set DATABASE_URL to use localhost
    if grep -q "DATABASE_URL=.*xyne-db" "$env_file" 2>/dev/null; then
        sed -i "s|xyne-db|localhost|g" "$env_file"
        print_status "Set DATABASE_URL to use localhost"
        env_changed=true
    fi
    
    # Set VESPA_HOST to localhost for local dev
    if grep -q "^VESPA_HOST=vespa" "$env_file" 2>/dev/null; then
        sed -i "s|^VESPA_HOST=vespa|VESPA_HOST=localhost|" "$env_file"
        print_status "Set VESPA_HOST=localhost for local dev"
        env_changed=true
    fi
    
    # Set HOST if empty
    if ! grep -q "^HOST=" "$env_file" 2>/dev/null || grep -q "^HOST=$" "$env_file" 2>/dev/null; then
        if grep -q "^HOST=" "$env_file" 2>/dev/null; then
            sed -i "s|^HOST=.*|HOST=http://localhost:3000|" "$env_file"
        else
            echo "HOST=http://localhost:3000" >> "$env_file"
        fi
        env_changed=true
    fi
    
    # Set NODE_ENV if empty
    if ! grep -q "^NODE_ENV=" "$env_file" 2>/dev/null || grep -q "^NODE_ENV=$" "$env_file" 2>/dev/null; then
        if grep -q "^NODE_ENV=" "$env_file" 2>/dev/null; then
            sed -i "s|^NODE_ENV=.*|NODE_ENV=development|" "$env_file"
        else
            echo "NODE_ENV=development" >> "$env_file"
        fi
        env_changed=true
    fi
    
    if [ "$env_changed" = true ]; then
        print_status "Server .env updated with required variables"
    else
        print_status "Server .env already configured"
    fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_AUTOMATION_DIR="${SCRIPT_DIR}/eval-automation"
DOCS_DIR="${EVAL_AUTOMATION_DIR}/docs"

export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# Load environment variables
set -a
source "${EVAL_AUTOMATION_DIR}/.env" 2>/dev/null || true
source "${EVAL_AUTOMATION_DIR}/.env.local" 2>/dev/null || true
source "${SCRIPT_DIR}/server/.env" 2>/dev/null || true
set +a

check_services() {
    print_status "Checking if services are already running..."
    
    if ! command -v tmux &> /dev/null; then
        print_error "tmux is not installed"
        return 1
    fi
    
    if tmux has-session -t xyne 2>/dev/null; then
        print_warning "Session 'xyne' already exists"
        read -p "Do you want to restart services? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            tmux kill-session -t xyne 2>/dev/null || true
            sleep 2
        else
            print_status "Using existing session"
            return 0
        fi
    fi
}

start_tmux_services() {
    print_status "Starting tmux services..."
    
    if ! command -v tmux &> /dev/null; then
        print_error "tmux is not installed. Cannot start services."
        return 1
    fi
    
    # Export bun path for all future commands
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"
    
    # Verify bun is accessible
    if ! command -v bun &> /dev/null; then
        print_error "bun is not in PATH. Cannot start services."
        print_error "BUN_INSTALL: $BUN_INSTALL"
        print_error "PATH: $PATH"
        return 1
    fi
    
    print_status "Verified bun is available at: $(which bun)"
    
    tmux kill-session -t xyne 2>/dev/null || true
    sleep 1
    tmux set -g mouse on 2>/dev/null || true

    # Ensure logs directory exists
    mkdir -p "${SCRIPT_DIR}/logs"

    local VESPA_RUNNING="no"
    local POSTGRES_RUNNING="no"
    
    if command -v docker &> /dev/null; then
        VESPA_RUNNING=$(docker ps --format '{{.Names}}' | grep -q "^vespa$" && echo "yes" || echo "no")
        POSTGRES_RUNNING=$(docker ps --format '{{.Names}}' | grep -q "^xyne-db$" && echo "yes" || echo "no")
    fi

    if [ "$VESPA_RUNNING" != "yes" ] || [ "$POSTGRES_RUNNING" != "yes" ]; then
        if command -v docker &> /dev/null; then
            # Detect docker compose command (v2 vs v1)
            local compose_cmd="docker-compose"
            if docker compose version &> /dev/null 2>&1; then
                compose_cmd="docker compose"
            fi
            
            # Create required directories for Docker volumes before starting
            mkdir -p "$SCRIPT_DIR/server/vespa-data" "$SCRIPT_DIR/server/vespa-logs" "$SCRIPT_DIR/server/xyne-data"
            
            print_status "Starting Docker services using: $compose_cmd"
            tmux new-session -d -s xyne -n "docker"
            tmux send-keys -t xyne:docker "cd ${SCRIPT_DIR} && $compose_cmd -f deployment/docker-compose.yml up 2>&1 | tee ${SCRIPT_DIR}/logs/docker-compose.log" C-m
            
            # Wait for Docker containers to be ready
            print_status "Waiting for Docker containers to initialize..."
            wait_for_docker_containers
        else
            print_warning "Docker not available, skipping Docker services"
            tmux new-session -d -s xyne -n "docker"
            tmux send-keys -t xyne:docker 'echo Docker not available' C-m
        fi
    else
        print_status "Docker services already running"
        tmux new-session -d -s xyne -n "docker"
        tmux send-keys -t xyne:docker 'echo Docker services already running' C-m
    fi

    sleep 2

    tmux new-window -t xyne -n "server"
    tmux send-keys -t xyne:server "export BUN_INSTALL=\"\$HOME/.bun\" && export PATH=\"\$BUN_INSTALL/bin:\$PATH\" && cd ${SCRIPT_DIR}/server && bun run dev" C-m

    tmux new-window -t xyne -n "frontend"
    tmux send-keys -t xyne:frontend "export BUN_INSTALL=\"\$HOME/.bun\" && export PATH=\"\$BUN_INSTALL/bin:\$PATH\" && cd ${SCRIPT_DIR}/frontend && npm run dev" C-m

    tmux new-window -t xyne -n "sync"
    tmux send-keys -t xyne:sync "export BUN_INSTALL=\"\$HOME/.bun\" && export PATH=\"\$BUN_INSTALL/bin:\$PATH\" && cd ${SCRIPT_DIR}/server && bun run dev:sync" C-m

    print_status "4 tmux windows created (docker, server, frontend, sync)"
}

wait_for_docker_containers() {
    print_status "Waiting for Docker containers to be healthy..."
    
    local max_attempts=60
    local attempt=0
    local db_ready=false
    
    while [ $attempt -lt $max_attempts ]; do
        # Check for any xyne-db container
        if docker ps --format '{{.Names}}' | grep -q "xyne-db\|xyne_postgres"; then
            # Check if postgres is accepting connections
            if docker exec xyne-db pg_isready -U xyne -d xyne &> /dev/null 2>&1 || \
               docker exec xyne_postgres pg_isready -U xyne -d xyne &> /dev/null 2>&1; then
                db_ready=true
                print_status "PostgreSQL is ready"
            fi
        fi
        
        if [ "$db_ready" = true ]; then
            print_status "Database is ready, proceeding..."
            return 0
        fi
        
        attempt=$((attempt + 1))
        if [ $((attempt % 10)) -eq 0 ]; then
            echo ""
            print_status "Still waiting for containers... ($attempt/$max_attempts)"
            docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || true
            
            # Check docker-compose log for errors
            if [ -f "${SCRIPT_DIR}/logs/docker-compose.log" ]; then
                local last_errors=$(tail -5 "${SCRIPT_DIR}/logs/docker-compose.log" 2>/dev/null)
                if echo "$last_errors" | grep -qi "error\|fail\|refused"; then
                    print_warning "Docker compose log errors detected:"
                    echo "$last_errors" | head -5
                fi
            fi
        fi
        echo -n "."
        sleep 2
    done
    
    echo ""
    print_warning "Timeout waiting for containers, but continuing anyway..."
    print_warning "Server may fail to connect to database"
    
    # Print docker-compose logs for debugging
    if [ -f "${SCRIPT_DIR}/logs/docker-compose.log" ]; then
        print_warning "Docker compose log (last 20 lines):"
        tail -20 "${SCRIPT_DIR}/logs/docker-compose.log" 2>/dev/null
    fi
}

wait_for_services() {
    print_status "Waiting for services to be ready..."
    
    local max_attempts=90
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -s http://localhost:3000/health > /dev/null 2>&1; then
            print_status "Server is ready!"
            break
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 3
    done
    
    if [ $attempt -eq $max_attempts ]; then
        print_error "Server did not become ready in time"
        print_error "Check tmux session for errors: tmux attach -t xyne"
        return 1
    fi
    
    echo ""
    print_status "All services ready!"
}

ingest_docs() {
    local ingestion_marker="${EVAL_AUTOMATION_DIR}/.docs_ingested"
    
    if [ -f "$ingestion_marker" ]; then
        print_status "Docs already ingested (marker file exists)"
        print_warning "Skipping doc ingestion - to re-ingest, delete: $ingestion_marker"
        return 0
    fi
    
    print_status "Starting document ingestion..."
    
    if [ ! -d "$DOCS_DIR" ]; then
        print_warning "Docs directory not found: $DOCS_DIR"
        print_warning "Please download docs and place in: $DOCS_DIR"
        print_warning "Skipping doc ingestion"
        return 0
    fi
    
    local file_count=$(ls -1 "$DOCS_DIR" 2>/dev/null | wc -l)
    if [ "$file_count" -eq 0 ]; then
        print_warning "No files found in docs directory"
        print_warning "Please download docs and place in: $DOCS_DIR"
        return 0
    fi
    
    print_status "Found $file_count files to ingest"
    
    cd "$EVAL_AUTOMATION_DIR"
    
    # Install required dependencies
    if [ ! -f "package.json" ]; then
        print_status "Creating package.json..."
        echo '{}' > package.json
    fi
    
    if [ ! -d "node_modules/hono" ]; then
        print_status "Installing dependencies (hono)..."
        bun add hono
    fi
    
    if [ ! -f "ingest_docs.ts" ]; then
        print_status "Creating ingest_docs.ts script..."
        
        cat > ingest_docs.ts << 'EOF'
#!/usr/bin/env bun

import { sign } from "hono/jwt"
import { readFileSync, existsSync } from "fs"
import { join } from "path"

const TEST_USER_EMAIL = "${TEST_USER_EMAIL:-suraj.nagre@juspay.in}"
const COLLECTION_ID = "${COLLECTION_ID:-cl_eval_xyne_search}"
const API_BASE = "${API_BASE:-http://localhost:3000}"

const accessTokenSecret = process.env.ACCESS_TOKEN_SECRET || ""
const refreshTokenSecret = process.env.REFRESH_TOKEN_SECRET || ""

const AccessTokenCookieName = "access-token"
const RefreshTokenCookieName = "refresh-token"

const generateTokens = async (
  email: string,
  role: string,
  workspaceId: string,
  forRefreshToken: boolean = false,
) => {
  const payload = forRefreshToken
    ? {
        sub: email,
        role: role,
        workspaceId,
        tokenType: "refresh",
        exp: Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60,
      }
    : {
        sub: email,
        role: role,
        workspaceId,
        tokenType: "access",
        exp: Math.floor(Date.now() / 1000) + 15 * 60,
      }
  const jwtToken = await sign(
    payload,
    forRefreshToken ? refreshTokenSecret : accessTokenSecret,
  )
  return jwtToken
}

const generateAuthenticationCookies = async () => {
  const accessToken = await generateTokens(TEST_USER_EMAIL, "admin", "ws_default")
  const refreshToken = await generateTokens(TEST_USER_EMAIL, "admin", "ws_default", true)
  return { accessToken, refreshToken }
}

const uploadFile = async (filePath: string, cookies: { accessToken: string; refreshToken: string }) => {
  const fileName = filePath.split("/").pop() || "unknown"
  
  const formData = new FormData()
  const fileBuffer = readFileSync(filePath)
  const blob = new Blob([fileBuffer])
  const file = new File([blob], fileName)
  formData.append("files", file)
  formData.append("useOCR", "true")
  formData.append("duplicateStrategy", "rename")

  try {
    const response = await fetch(`${API_BASE}/api/v1/cl/${COLLECTION_ID}/items/upload`, {
      method: "POST",
      headers: {
        "Cookie": `${AccessTokenCookieName}=${cookies.accessToken}; ${RefreshTokenCookieName}=${cookies.refreshToken}`,
      },
      body: formData,
    })

    if (!response.ok) {
      const error = await response.text()
      throw new Error(`Upload failed: ${response.status} - ${error}`)
    }

    return await response.json()
  } catch (error) {
    throw error
  }
}

const main = async () => {
  const docsDir = process.env.DOCS_DIR || "./docs"
  
  if (!existsSync(docsDir)) {
    console.error(`Docs directory not found: ${docsDir}`)
    process.exit(1)
  }

  const files = await Bun.file(docsDir).stream()
  const fileList: string[] = []
  
  for await (const entry of Deno.readDir(docsDir)) {
    if (entry.isFile && !entry.name.startsWith(".")) {
      fileList.push(join(docsDir, entry.name))
    }
  }

  if (fileList.length === 0) {
    console.log("No files found to ingest")
    return
  }

  console.log(`Found ${fileList.length} files to ingest`)
  
  const cookies = await generateAuthenticationCookies()
  
  let successCount = 0
  let failCount = 0

  for (let i = 0; i < fileList.length; i++) {
    const filePath = fileList[i]
    const fileName = filePath.split("/").pop()
    
    process.stdout.write(`[${i + 1}/${fileList.length}] Uploading: ${fileName}... `)
    
    try {
      await uploadFile(filePath, cookies)
      console.log("✓")
      successCount++
    } catch (error) {
      console.log(`✗ - ${error.message}`)
      failCount++
    }
    
    await new Promise(resolve => setTimeout(resolve, 500))
  }

  console.log(`\n==========================================`)
  console.log(`Ingestion complete: ${successCount} succeeded, ${failCount} failed`)
  console.log(`==========================================`)
}

main().catch(console.error)
EOF
    fi
    
    print_status "Running doc ingestion script..."
    TEST_USER_EMAIL="$TEST_USER_EMAIL" \
    COLLECTION_ID="$COLLECTION_ID" \
    API_BASE="$API_BASE" \
    ACCESS_TOKEN_SECRET="$ACCESS_TOKEN_SECRET" \
    REFRESH_TOKEN_SECRET="$REFRESH_TOKEN_SECRET" \
    DOCS_DIR="$DOCS_DIR" \
    bun run ingest_docs.ts
    
    print_status "Waiting for sync-server to process all documents..."
    print_warning "Please monitor the sync tmux window for processing status"
    read -p "Press Enter when processing is complete (or 's' to skip): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
        print_status "Doc ingestion complete!"
        
        echo "$(date)" > "$ingestion_marker"
        print_status "Created marker file: $ingestion_marker"
        print_status "Docs will not be re-ingested on next run"
    fi
}

main() {
    install_dependencies
    kill_existing_processes
    fix_env_settings
    ensure_env_file
    ensure_directories
    ensure_collection
    check_services
    start_tmux_services
    wait_for_services
    ingest_docs
    
    echo ""
    echo "=========================================="
    echo "  Setup Complete!"
    echo "=========================================="
    echo ""
    echo "To view tmux session:"
    echo "  tmux attach -t xyne"
    echo ""
    echo "Windows:"
    echo "  Ctrl+b 0 - docker"
    echo "  Ctrl+b 1 - server"
    echo "  Ctrl+b 2 - frontend"
    echo "  Ctrl+b 3 - sync"
    echo ""
    echo "Next step: Run run.sh to execute the eval pipeline"
}

main "$@"
