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
    print_status "Setting up eval environment..."
    
    local eval_dir="$EVAL_AUTOMATION_DIR"
    
    mkdir -p "$eval_dir/results"
    mkdir -p "$eval_dir/scoring_outputs"
    
    print_status "Eval environment ready"
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
    
    cd "$EVAL_AUTOMATION_DIR"
    
    RESULTS_DIR="$EVAL_AUTOMATION_DIR/results" bun run test_api_v6.ts "$START_INDEX" "$COUNT" "$BATCH_SIZE"
    
    if [ $? -ne 0 ]; then
        print_error "test_api_v6.ts failed!"
        exit 1
    fi
    
    print_status "test_api_v6.ts completed successfully!"
}

run_scorer() {
    print_status "Running scorer.ts..."
    echo ""
    
    cd "$EVAL_AUTOMATION_DIR"
    
    RESULTS_DIR="$EVAL_AUTOMATION_DIR/results" bun run scorer.ts
    
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
    echo "Results available in:"
    echo "  $EVAL_AUTOMATION_DIR/results/"
    echo ""
    
    read -p "Cleanup eval environment? (y/n/c): " -n 1 -r
    echo
    case "$REPLY" in
        y|Y)
            print_status "Cleaning up..."
            cd "$SCRIPT_DIR" && ./setup.sh --clean
            ;;
        c|C)
            print_status "Cleaning up including Vespa..."
            cd "$SCRIPT_DIR" && ./setup.sh --clean-vespa
            ;;
        *)
            print_status "Skipping cleanup. Run ./setup.sh --clean manually to cleanup."
            ;;
    esac
}

main "$@"