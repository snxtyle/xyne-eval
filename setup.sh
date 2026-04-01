#!/bin/bash

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
    echo -e "${RED}[ERROR]${NC} $1"
}

cleanup() {
    print_status "Cleaning up eval environment..."
    
    local cleanup_vespa=${1:-false}
    local cleanup_docker=${2:-false}
    
    print_status "Stopping tmux session..."
    tmux kill-session -t xyne 2>/dev/null || true
    
    print_status "Killing processes on ports 3000/3010..."
    lsof -ti :3000 | xargs kill -9 2>/dev/null || true
    lsof -ti :3010 | xargs kill -9 2>/dev/null || true
    pkill -f "bun run.*server.ts" 2>/dev/null || true
    
    if [ "$cleanup_vespa" = "true" ]; then
        print_status "Cleaning Vespa data..."
        docker exec vespa bash -c "rm -rf /opt/vespa/var/search/* 2>/dev/null || true"
        docker exec vespa bash -c "vespa-stop 2>/dev/null || true"
        docker exec vespa bash -c "sleep 2 && vespa-start 2>/dev/null || true"
    fi
    
    if [ "$cleanup_docker" = "true" ]; then
        print_warning "Stopping Docker services..."
        docker stop xyne-db xyne-app 2>/dev/null || true
    fi
    
    print_status "Cleaning eval-automation results..."
    rm -f "$EVAL_AUTOMATION_DIR/.docs_ingested"
    rm -f "$EVAL_AUTOMATION_DIR/.env"
    
    print_status "Cleanup complete!"
}

show_help() {
    echo "Usage: ./setup.sh [command]"
    echo ""
    echo "Commands:"
    echo "  (no args)      Run full setup + doc ingestion"
    echo "  --clean        Clean up processes only"
    echo "  --clean-vespa  Clean up + clear Vespa data"
    echo "  --clean-all    Clean up + clear Vespa + stop Docker"
    echo "  --help         Show this help message"
}

kill_existing_processes() {
    print_status "Killing existing processes on ports 3000 and 3010..."
    lsof -ti :3000 | xargs kill -9 2>/dev/null || true
    lsof -ti :3010 | xargs kill -9 2>/dev/null || true
    pkill -f "bun run.*server.ts" 2>/dev/null || true
    sleep 2
    print_status "Existing processes killed"
}

ensure_collection() {
    print_status "Ensuring collection exists in database..."
    
    local collection_name="cl_eval_xyne_search"
    local collection_exists=$(docker exec xyne-db psql -U xyne -d xyne -t -c "SELECT COUNT(*) FROM collections WHERE name = '$collection_name';" 2>/dev/null || echo "0")
    
    if [ "$collection_exists" -eq "0" ] || [ -z "$collection_exists" ]; then
        print_status "Creating collection '$collection_name'..."
        local result=$(docker exec xyne-db psql -U xyne -d xyne -t -c "INSERT INTO collections (id, workspace_id, owner_id, name, vespa_doc_id, is_private, total_items) VALUES (gen_random_uuid(), 1, 1, '$collection_name', '${collection_name}_doc', false, 0) RETURNING id;" 2>/dev/null | tr -d ' ')
        
        if [ -n "$result" ]; then
            print_status "Collection created with ID: $result"
            # Export for later use
            export COLLECTION_ID="$result"
        else
            print_error "Failed to create collection"
        fi
    else
        local collection_id=$(docker exec xyne-db psql -U xyne -d xyne -t -c "SELECT id FROM collections WHERE name = '$collection_name' LIMIT 1;" 2>/dev/null | tr -d ' ')
        print_status "Collection already exists: $collection_id"
        export COLLECTION_ID="$collection_id"
    fi
}

fix_env_settings() {
    print_status "Fixing environment settings..."
    
    # Fix LAYOUT_PARSING_BASE_URL in eval-automation/.env
    if grep -q "LAYOUT_PARSING_BASE_URL='https://.*ngrok" "$EVAL_AUTOMATION_DIR/.env" 2>/dev/null; then
        print_status "Commenting out expired ngrok URL in eval-automation/.env"
        sed -i '' "s|^LAYOUT_PARSING_BASE_URL=|# LAYOUT_PARSING_BASE_URL=|g" "$EVAL_AUTOMATION_DIR/.env"
    fi
    
    # Fix LAYOUT_PARSING_BASE_URL in server/.env
    if grep -q "LAYOUT_PARSING_BASE_URL='https://.*ngrok" "$SCRIPT_DIR/server/.env" 2>/dev/null; then
        print_status "Commenting out expired ngrok URL in server/.env"
        sed -i '' "s|^LAYOUT_PARSING_BASE_URL=|# LAYOUT_PARSING_BASE_URL=|g" "$SCRIPT_DIR/server/.env"
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
    
    tmux kill-session -t xyne 2>/dev/null || true
    sleep 1
    tmux set -g mouse on 2>/dev/null || true

    VESPA_RUNNING=$(docker ps --format '{{.Names}}' | grep -q "^vespa$" && echo "yes" || echo "no")
    POSTGRES_RUNNING=$(docker ps --format '{{.Names}}' | grep -q "^xyne-db$" && echo "yes" || echo "no")

    if [ "$VESPA_RUNNING" != "yes" ] || [ "$POSTGRES_RUNNING" != "yes" ]; then
        print_status "Starting Docker services..."
        tmux new-session -d -s xyne -n "docker"
        tmux send-keys -t xyne:docker "cd ${SCRIPT_DIR} && docker-compose -f deployment/docker-compose.yml up" C-m
    else
        print_status "Docker services already running"
        tmux new-session -d -s xyne -n "docker"
        tmux send-keys -t xyne:docker 'echo Docker services already running' C-m
    fi

    sleep 5

    tmux new-window -t xyne -n "server"
    tmux send-keys -t xyne:server "cd ${SCRIPT_DIR}/server && bun run dev" C-m

    tmux new-window -t xyne -n "frontend"
    tmux send-keys -t xyne:frontend "cd ${SCRIPT_DIR}/frontend && npm run dev" C-m

    tmux new-window -t xyne -n "sync"
    tmux send-keys -t xyne:sync "cd ${SCRIPT_DIR}/server && bun run dev:sync" C-m

    print_status "4 tmux windows created (docker, server, frontend, sync)"
}

wait_for_services() {
    print_status "Waiting for services to be ready..."
    
    local max_attempts=60
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -s http://localhost:3000/health > /dev/null 2>&1; then
            print_status "Server is ready!"
            break
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
    done
    
    if [ $attempt -eq $max_attempts ]; then
        print_error "Server did not become ready in time"
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
    local cmd=${1:-}
    
    case "$cmd" in
        --help|-h)
            show_help
            exit 0
            ;;
        --clean)
            cleanup "false" "false"
            exit 0
            ;;
        --clean-vespa)
            cleanup "true" "false"
            exit 0
            ;;
        --clean-all)
            cleanup "true" "true"
            exit 0
            ;;
        "")
            kill_existing_processes
            fix_env_settings
            ensure_directories
            ensure_collection
            check_services
            start_tmux_services
            wait_for_services
            ingest_docs
            ;;
        *)
            print_error "Unknown command: $cmd"
            show_help
            exit 1
            ;;
    esac
    
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
    echo "Cleanup commands:"
    echo "  ./setup.sh --clean         - Stop processes, keep services"
    echo "  ./setup.sh --clean-vespa   - Clean + clear Vespa data"
    echo "  ./setup.sh --clean-all     - Full cleanup + stop Docker"
    echo ""
    echo "Next step: Run run.sh to execute the eval pipeline"
}

main "$@"