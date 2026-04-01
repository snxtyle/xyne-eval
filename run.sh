#!/bin/bash

echo "=========================================="
echo "  Xyne Eval Runner"
echo "=========================================="

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}[RUNNER]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

setup_test_script() {
    print_status "Setting up test script..."
    
    local eval_dir="$EVAL_AUTOMATION_DIR"
    local server_dir="$SCRIPT_DIR/server"
    
    mkdir -p "$eval_dir/results"
    
    if [ ! -f "$server_dir/test_api.ts" ]; then
        print_status "Copying test script with fixed imports..."
        cp "$eval_dir/test_api_v6.ts" "$server_dir/test_api.ts"
        
        sed -i '' 's|from "../../../db/client"|from "./db/client"|g' "$server_dir/test_api.ts"
        sed -i '' 's|from "../../../db/user"|from "./db/user"|g' "$server_dir/test_api.ts"
        sed -i '' 's|from "../../../config"|from "./config"|g' "$server_dir/test_api.ts"
        
        sed -i '' 's|from "../../server/db/client"|from "./db/client"|g' "$server_dir/test_api.ts"
        sed -i '' 's|from "../../server/db/user"|from "./db/user"|g' "$server_dir/test_api.ts"
        sed -i '' 's|from "../../server/config"|from "./config"|g' "$server_dir/test_api.ts"
        
        sed -i '' 's|xyne-evals/qa_pipelines/generation_through_vespa/output/qa_output_hard.json|../eval-automation/qa_output_hard.json|g' "$server_dir/test_api.ts"
    fi
    
    print_status "Test script ready"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_AUTOMATION_DIR="${SCRIPT_DIR}/eval-automation"

export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

START_INDEX=${1:-0}
COUNT=${2:-10}
BATCH_SIZE=${3:-10}

print_status "Parameters received:"
echo "  Start Index: $START_INDEX"
echo "  Count: $COUNT"
echo "  Batch Size: $BATCH_SIZE"
echo ""

check_tmux_session() {
    print_status "Checking if tmux session 'xyne' is running..."
    
    if ! tmux has-session -t xyne 2>/dev/null; then
        print_error "No 'xyne' tmux session found!"
        print_status "Please run setup.sh first to start services"
        exit 1
    fi
    
    print_status "tmux session 'xyne' is running"
}

check_services() {
    print_status "Checking if services are ready..."
    
    if curl -s http://localhost:3000/health > /dev/null 2>&1; then
        print_status "Server is ready!"
    else
        print_error "Server is not responding at http://localhost:3000"
        print_status "Please ensure services are running via setup.sh"
        exit 1
    fi
}

run_test_api() {
    print_status "Running eval on QA pairs..."
    echo "  Start Index: $START_INDEX"
    echo "  Count: $COUNT"
    echo "  Batch Size: $BATCH_SIZE"
    echo ""
    
    cd "$SCRIPT_DIR/server"
    
    RESULTS_DIR="$EVAL_AUTOMATION_DIR/results" bun run test_api.ts "$START_INDEX" "$COUNT" "$BATCH_SIZE"
    
    if [ $? -ne 0 ]; then
        print_error "test_api_v6.ts failed!"
        exit 1
    fi
    
    print_status "test_api_v6.ts completed successfully!"
}

run_scorer() {
    print_status "Running scorer.ts..."
    echo ""
    
    cd "$SCRIPT_DIR/server"
    
    RESULTS_DIR="$EVAL_AUTOMATION_DIR/results" bun run ../eval-automation/scorer.ts
    
    if [ $? -ne 0 ]; then
        print_error "scorer.ts failed!"
        exit 1
    fi
    
    print_status "scorer.ts completed successfully!"
}

main() {
    setup_test_script
    check_tmux_session
    check_services
    
    echo ""
    echo "=========================================="
    echo "  Starting Eval Pipeline"
    echo "=========================================="
    echo ""
    
    run_test_api
    
    echo ""
    print_status "Test API completed, starting scorer..."
    echo ""
    
    run_scorer
    
    echo ""
    echo "=========================================="
    echo "  Eval Pipeline Complete!"
    echo "=========================================="
    echo ""
    echo "Results should be available in:"
    echo "  $EVAL_AUTOMATION_DIR/"
    echo ""
    echo "To view tmux session:"
    echo "  tmux attach -t xyne"
}

main "$@"