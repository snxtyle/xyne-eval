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
        
        local packages="apt-utils lsof tmux curl jq unzip zip"
        if ! command -v docker &> /dev/null; then
            packages="$packages docker.io"
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
    
    # Install vespa CLI for schema deployment
    if ! command -v vespa &> /dev/null; then
        print_status "Installing vespa CLI..."
        curl -fsSL https://github.com/vespa-engine/vespa/releases/latest/download/vespa-cli_$(uname -s)_$(uname -m).tar.gz 2>/dev/null | \
            tar xz -C /tmp/ 2>/dev/null && \
            cp /tmp/vespa-cli/bin/vespa /usr/local/bin/vespa 2>/dev/null || \
            print_warning "Failed to install vespa CLI - will try HTTP deploy as fallback"
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

generate_qa_data() {
    local qa_file="$EVAL_AUTOMATION_DIR/qa_output_hard.json"
    
    if [ -f "$qa_file" ]; then
        print_status "QA data file already exists: $qa_file"
        return 0
    fi
    
    print_status "Generating QA data file from test-queries.json..."
    
    local test_queries_file="$SCRIPT_DIR/eval-data/test-queries.json"
    if [ ! -f "$test_queries_file" ]; then
        print_warning "test-queries.json not found at: $test_queries_file"
        print_warning "Cannot generate QA data automatically"
        return 1
    fi
    
    # Convert test-queries.json to qa_output_hard.json format using jq
    if command -v jq &> /dev/null; then
        jq 'map({
            User_data: {
                UserID: "eval@juspay.in",
                User_name: "Eval Runner"
            },
            Question_weights: {
                Coverage_preference: "medium",
                Vagueness: 0.1,
                Question_Complexity: "low",
                Realness: "fact",
                Reasoning: "fact-based",
                Question_format: "definitive"
            },
            Question: .input,
            Answer_weights: {
                Factuality: 1.0,
                Completeness: 1.0,
                Domain_relevance: 1.0
            },
            Answer: ("Ground truth answer for: " + .input),
            Confidence: 0.8,
            citations: [],
            question_id: ("q_" + (.input | @base64 | .[0:12]))
        })' "$test_queries_file" > "$qa_file"
        
        local count=$(jq 'length' "$qa_file" 2>/dev/null || echo "0")
        print_status "Generated QA data file with $count questions from test-queries.json"
        print_warning "Note: Ground truth answers are auto-generated placeholders"
        print_warning "For meaningful scoring, replace with real QA data containing correct answers"
    else
        print_warning "jq not available - cannot convert test-queries.json"
        print_warning "Creating minimal QA data file..."
        
        # Create a minimal QA file with a few sample questions
        cat > "$qa_file" << 'QAEOF'
[
  {
    "User_data": {
      "UserID": "eval@juspay.in",
      "User_name": "Eval Runner"
    },
    "Question_weights": {
      "Coverage_preference": "medium",
      "Vagueness": 0.1,
      "Question_Complexity": "low",
      "Realness": "fact",
      "Reasoning": "fact-based",
      "Question_format": "definitive"
    },
    "Question": "What is Juspay's approach to payment orchestration?",
    "Answer_weights": {
      "Factuality": 1.0,
      "Completeness": 1.0,
      "Domain_relevance": 1.0
    },
    "Answer": "Juspay provides a payment orchestration platform that aggregates multiple payment gateways and methods.",
    "Confidence": 0.8,
    "citations": [],
    "question_id": "q_sample_001"
  },
  {
    "User_data": {
      "UserID": "eval@juspay.in",
      "User_name": "Eval Runner"
    },
    "Question_weights": {
      "Coverage_preference": "medium",
      "Vagueness": 0.1,
      "Question_Complexity": "medium",
      "Realness": "fact",
      "Reasoning": "fact-based",
      "Question_format": "definitive"
    },
    "Question": "How does UPI SDK integration work with Juspay?",
    "Answer_weights": {
      "Factuality": 1.0,
      "Completeness": 1.0,
      "Domain_relevance": 1.0
    },
    "Answer": "Juspay's UPI SDK enables merchants to integrate UPI payments into their applications with support for intent flow and collect requests.",
    "Confidence": 0.7,
    "citations": [],
    "question_id": "q_sample_002"
  },
  {
    "User_data": {
      "UserID": "eval@juspay.in",
      "User_name": "Eval Runner"
    },
    "Question_weights": {
      "Coverage_preference": "high",
      "Vagueness": 0.2,
      "Question_Complexity": "high",
      "Realness": "fact",
      "Reasoning": "analytical",
      "Question_format": "definitive"
    },
    "Question": "What are the PCI DSS compliance requirements for payment gateways?",
    "Answer_weights": {
      "Factuality": 1.0,
      "Completeness": 1.0,
      "Domain_relevance": 1.0
    },
    "Answer": "PCI DSS compliance for payment gateways includes requirements for network security, cardholder data protection, vulnerability management, access control, monitoring, and security policies.",
    "Confidence": 0.75,
    "citations": [],
    "question_id": "q_sample_003"
  }
]
QAEOF
        print_status "Created minimal QA data file with 3 sample questions"
        print_warning "For meaningful scoring, replace with real QA data containing correct answers"
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
    
    # GOOGLE_CLIENT_ID/SECRET are required at boot (non-null asserted in server.ts)
    # Use placeholders since we don't use OAuth in eval
    for gvar in GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET; do
        if ! grep -q "^${gvar}=" "$env_file" 2>/dev/null || grep -q "^${gvar}=$" "$env_file" 2>/dev/null; then
            echo "${gvar}=placeholder" >> "$env_file"
            print_status "Set ${gvar}=placeholder in .env"
            env_changed=true
        fi
    done
    
    # GOOGLE_REDIRECT_URI required by config.ts
    if ! grep -q "^GOOGLE_REDIRECT_URI=" "$env_file" 2>/dev/null || grep -q "^GOOGLE_REDIRECT_URI=$" "$env_file" 2>/dev/null; then
        echo "GOOGLE_REDIRECT_URI=http://localhost:3000/v1/auth/callback" >> "$env_file"
        env_changed=true
    fi
    
    # EMBEDDING_MODEL for Vespa deploy
    if ! grep -q "^EMBEDDING_MODEL=" "$env_file" 2>/dev/null || grep -q "^EMBEDDING_MODEL=$" "$env_file" 2>/dev/null; then
        echo "EMBEDDING_MODEL=bge-small-en-v1.5" >> "$env_file"
        env_changed=true
    fi
    
    # RAG_OFF_FEATURE - enable RAG for search
    if ! grep -q "^RAG_OFF_FEATURE=" "$env_file" 2>/dev/null; then
        echo "RAG_OFF_FEATURE=false" >> "$env_file"
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
    print_status "Cleaning up existing services..."
    
    if tmux has-session -t xyne 2>/dev/null; then
        print_status "Killing existing tmux session..."
        tmux kill-session -t xyne 2>/dev/null || true
        sleep 2
    fi
}

start_docker_containers() {
    print_status "Starting Docker containers directly (siblings mode)..."
    
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not available. Cannot start containers."
        return 1
    fi
    
    if ! docker ps &> /dev/null 2>&1; then
        print_error "Docker daemon is not reachable"
        return 1
    fi
    
    # --- PostgreSQL ---
    if docker ps --format '{{.Names}}' | grep -q "^xyne-db$"; then
        print_status "PostgreSQL container already running"
    else
        docker rm -f xyne-db 2>/dev/null || true
        print_status "Starting PostgreSQL (xyne-db)..."
        docker run -d \
            --name xyne-db \
            -e POSTGRES_USER=xyne \
            -e POSTGRES_PASSWORD=xyne \
            -e POSTGRES_DB=xyne \
            -e "POSTGRES_INITDB_ARGS=--encoding=UTF-8 --lc-collate=C --lc-ctype=C" \
            -p 5432:5432 \
            postgres:15-alpine || {
            print_error "Failed to start PostgreSQL container"
            print_error "Check: docker pull postgres:15-alpine"
            return 1
        }
        print_status "PostgreSQL container started"
    fi
    
    # --- Vespa ---
    if docker ps --format '{{.Names}}' | grep -q "^vespa$"; then
        print_status "Vespa container already running"
    else
        docker rm -f vespa 2>/dev/null || true
        print_status "Starting Vespa..."
        docker run -d \
            --name vespa \
            -p 8080:8080 \
            -p 8081:8081 \
            -p 19071:19071 \
            -e "VESPA_CONFIGSERVER_JVMARGS=-Xms1g -Xmx16g -XX:+UseG1GC -XX:G1HeapRegionSize=32M" \
            -e "VESPA_CONFIGPROXY_JVMARGS=-Xms512m -Xmx8g -XX:+UseG1GC" \
            -e VESPA_ALLOW_WRITE_AS_USER=true \
            vespaengine/vespa || {
            print_error "Failed to start Vespa container"
            print_error "Check: docker pull vespaengine/vespa"
            return 1
        }
        print_status "Vespa container started"
    fi
}

start_tmux_services() {
    print_status "Starting application services in tmux..."
    
    if ! command -v tmux &> /dev/null; then
        print_error "tmux is not installed. Cannot start services."
        return 1
    fi
    
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"
    
    if ! command -v bun &> /dev/null; then
        print_error "bun is not in PATH. Cannot start services."
        return 1
    fi
    
    print_status "Verified bun is available at: $(which bun)"
    
    tmux kill-session -t xyne 2>/dev/null || true
    sleep 1
    tmux set -g mouse on 2>/dev/null || true

    mkdir -p "${SCRIPT_DIR}/logs"

    # Window 0: server
    tmux new-session -d -s xyne -n "server"
    tmux send-keys -t xyne:server "export BUN_INSTALL=\"\$HOME/.bun\" && export PATH=\"\$BUN_INSTALL/bin:\$PATH\" && cd ${SCRIPT_DIR}/server && set -a && source .env && set +a && bun run dev 2>&1 | tee ${SCRIPT_DIR}/logs/server.log" C-m

    sleep 2

    # Window 1: sync
    tmux new-window -t xyne -n "sync"
    tmux send-keys -t xyne:sync "export BUN_INSTALL=\"\$HOME/.bun\" && export PATH=\"\$BUN_INSTALL/bin:\$PATH\" && cd ${SCRIPT_DIR}/server && set -a && source .env && set +a && bun run dev:sync 2>&1 | tee ${SCRIPT_DIR}/logs/sync.log" C-m

    # Window 2: frontend (optional)
    tmux new-window -t xyne -n "frontend"
    tmux send-keys -t xyne:frontend "export BUN_INSTALL=\"\$HOME/.bun\" && export PATH=\"\$BUN_INSTALL/bin:\$PATH\" && cd ${SCRIPT_DIR}/frontend && npm run dev 2>&1 | tee ${SCRIPT_DIR}/logs/frontend.log" C-m

    print_status "3 tmux windows created (server, sync, frontend)"
}

wait_for_docker_containers() {
    print_status "Waiting for Docker containers to be healthy..."
    
    local max_attempts=60
    local attempt=0
    local db_ready=false
    local vespa_ready=false
    
    while [ $attempt -lt $max_attempts ]; do
        # Check PostgreSQL
        if [ "$db_ready" = false ] && docker ps --format '{{.Names}}' | grep -q "^xyne-db$"; then
            if docker exec xyne-db pg_isready -U xyne -d xyne &> /dev/null 2>&1; then
                db_ready=true
                print_status "PostgreSQL is ready"
            fi
        fi
        
        # Check Vespa config server
        if [ "$vespa_ready" = false ]; then
            if curl -sf http://localhost:19071/state/v1/health > /dev/null 2>&1; then
                vespa_ready=true
                print_status "Vespa config server is ready"
            fi
        fi
        
        if [ "$db_ready" = true ] && [ "$vespa_ready" = true ]; then
            print_status "All containers are healthy"
            return 0
        fi
        
        attempt=$((attempt + 1))
        if [ $((attempt % 10)) -eq 0 ]; then
            echo ""
            print_status "Still waiting... ($attempt/$max_attempts) db=$db_ready vespa=$vespa_ready"
            docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || true
        fi
        echo -n "."
        sleep 2
    done
    
    echo ""
    print_warning "Timeout waiting for containers"
    
    if [ "$db_ready" = false ]; then
        print_warning "PostgreSQL not ready. Container logs:"
        docker logs xyne-db --tail 20 2>/dev/null || print_warning "Cannot get xyne-db logs"
    fi
    if [ "$vespa_ready" = false ]; then
        print_warning "Vespa not ready. Container logs:"
        docker logs vespa --tail 20 2>/dev/null || print_warning "Cannot get vespa logs"
    fi
    
    if [ "$db_ready" = true ]; then
        print_warning "Continuing with PostgreSQL only (Vespa unavailable)"
        return 0
    fi
    
    return 1
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

run_migrations() {
    print_status "Running database migrations..."
    
    cd "${SCRIPT_DIR}/server"
    
    set -a
    source "${SCRIPT_DIR}/server/.env" 2>/dev/null || true
    set +a
    
    if ! bun run migrate 2>/dev/null; then
        print_warning "bun run migrate failed, trying drizzle-kit push..."
        if bunx drizzle-kit push 2>/dev/null; then
            print_status "Schema pushed via drizzle-kit push"
        else
            print_warning "Migration failed - tables may already exist or schema has issues"
        fi
    else
        print_status "Database migrations applied"
    fi
    
    cd "${SCRIPT_DIR}"
}

seed_user() {
    print_status "Seeding eval user into database..."
    
    local eval_email="suraj.nagre@juspay.in"
    local eval_name="Eval User"
    local eval_role="superAdmin"
    local ws_external_id="ws_default"
    
    # Check if user already exists
    local user_exists=$(docker exec xyne-db psql -U xyne -d xyne -t -c \
        "SELECT COUNT(*) FROM users WHERE email = '${eval_email}';" 2>/dev/null | tr -d ' ')
    
    if [ "$user_exists" = "0" ] || [ -z "$user_exists" ]; then
        # Ensure workspace exists
        local ws_exists=$(docker exec xyne-db psql -U xyne -d xyne -t -c \
            "SELECT COUNT(*) FROM workspaces WHERE external_id = '${ws_external_id}';" 2>/dev/null | tr -d ' ')
        
        if [ "$ws_exists" = "0" ] || [ -z "$ws_exists" ]; then
            print_status "Creating workspace..."
            docker exec xyne-db psql -U xyne -d xyne -c \
                "INSERT INTO workspaces (name, domain, external_id) VALUES ('Eval', 'juspay.in', '${ws_external_id}');" 2>/dev/null || \
                print_warning "Failed to create workspace"
        fi
        
        # Get workspace ID
        local ws_id=$(docker exec xyne-db psql -U xyne -d xyne -t -c \
            "SELECT id FROM workspaces WHERE external_id = '${ws_external_id}' LIMIT 1;" 2>/dev/null | tr -d ' ')
        
        if [ -n "$ws_id" ]; then
            print_status "Creating eval user: ${eval_email}"
            docker exec xyne-db psql -U xyne -d xyne -c \
                "INSERT INTO users (workspace_id, email, name, external_id, role) VALUES (${ws_id}, '${eval_email}', '${eval_name}', '${ws_external_id}', '${eval_role}');" 2>/dev/null || \
                print_warning "Failed to create user"
        else
            print_warning "Could not find workspace ID, skipping user creation"
        fi
    else
        print_status "Eval user already exists: ${eval_email}"
    fi
}

deploy_vespa_schema() {
    print_status "Deploying Vespa schema..."
    
    # Check if Vespa config server is reachable
    if ! curl -sf http://localhost:19071/state/v1/health > /dev/null 2>&1; then
        print_warning "Vespa config server not reachable on port 19071"
        print_warning "Skipping Vespa schema deployment"
        return 0
    fi
    
    # Try using deploy.sh if vespa CLI is available
    if command -v vespa &> /dev/null; then
        print_status "Using vespa CLI to deploy..."
        cd "${SCRIPT_DIR}/server/vespa"
        EMBEDDING_MODEL="${EMBEDDING_MODEL:-bge-small-en-v1.5}" ./deploy.sh 2>&1 || \
            print_warning "Vespa deploy.sh failed"
        cd "${SCRIPT_DIR}"
    else
        print_warning "vespa CLI not installed - attempting manual deploy via HTTP API"
        
        # Replace DIMS placeholders in schema files
        local dims=384
        if [ "${EMBEDDING_MODEL}" = "bge-base-en-v1.5" ]; then dims=768
        elif [ "${EMBEDDING_MODEL}" = "bge-large-en-v1.5" ]; then dims=1024
        fi
        
        cd "${SCRIPT_DIR}/server/vespa"
        
        # Replace DIMS in schema files if bun is available
        if command -v bun &> /dev/null; then
            bun run replaceDIMS.ts "$dims" 2>/dev/null || \
                print_warning "replaceDIMS.ts failed, schemas may have placeholder dimensions"
        fi
        
        # Download embedding model if not present
        mkdir -p models
        if [ ! -f models/tokenizer.json ]; then
            print_status "Downloading embedding model tokenizer..."
            curl -sL "https://huggingface.co/BAAI/bge-small-en-v1.5/resolve/main/tokenizer.json" \
                -o models/tokenizer.json 2>/dev/null || print_warning "Failed to download tokenizer"
        fi
        if [ ! -f models/model.onnx ]; then
            print_status "Downloading embedding model..."
            curl -sL "https://huggingface.co/BAAI/bge-small-en-v1.5/resolve/main/onnx/model.onnx" \
                -o models/model.onnx 2>/dev/null || print_warning "Failed to download model"
        fi
        
        # Create application package zip and deploy via HTTP API
        if command -v zip &> /dev/null; then
            print_status "Creating Vespa application package..."
            zip -r /tmp/vespa-app.zip services.xml validation-overrides.xml schemas/ models/ rules/ 2>/dev/null || \
                zip -r /tmp/vespa-app.zip services.xml validation-overrides.xml schemas/ rules/ 2>/dev/null || \
                print_warning "Failed to create application zip"
            
            if [ -f /tmp/vespa-app.zip ]; then
                print_status "Deploying application package to Vespa..."
                local deploy_response=$(curl -s -w "\n%{http_code}" -X POST \
                    "http://localhost:19071/application/v2/tenant/default/prepareandactivate" \
                    -H "Content-Type: application/zip" \
                    --data-binary @/tmp/vespa-app.zip 2>/dev/null)
                local deploy_status=$(echo "$deploy_response" | tail -1)
                if [ "$deploy_status" = "200" ] || [ "$deploy_status" = "202" ]; then
                    print_status "Vespa application deployed successfully"
                else
                    print_warning "Vespa deploy HTTP status: ${deploy_status}"
                fi
                rm -f /tmp/vespa-app.zip
            fi
        else
            print_warning "zip not available - cannot create Vespa application package"
            print_warning "Install zip or vespa CLI for schema deployment"
        fi
        
        cd "${SCRIPT_DIR}"
    fi
}

main() {
    install_dependencies
    kill_existing_processes
    fix_env_settings
    ensure_env_file
    ensure_directories
    generate_qa_data
    check_services
    
    # Start Docker containers directly (no docker-compose)
    # This avoids volume path resolution issues on COS with Docker siblings
    start_docker_containers
    wait_for_docker_containers
    
    # After containers are healthy, set up the database
    run_migrations
    seed_user
    deploy_vespa_schema
    ensure_collection
    
    # Start application services in tmux (server, sync, frontend)
    start_tmux_services
    wait_for_services
    ingest_docs
    
    echo ""
    echo "=========================================="
    echo "  Setup Complete!"
    echo "=========================================="
    echo ""
    echo "Docker containers:"
    echo "  xyne-db  - PostgreSQL on localhost:5432"
    echo "  vespa    - Search on localhost:8080/8081"
    echo ""
    echo "Tmux session 'xyne':"
    echo "  Ctrl+b 0 - server"
    echo "  Ctrl+b 1 - sync"
    echo "  Ctrl+b 2 - frontend"
    echo ""
    echo "Next step: Run run.sh to execute the eval pipeline"
}

main "$@"
