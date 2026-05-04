#!/bin/bash

set -euo pipefail

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
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Error handler
cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        print_error "Script failed with exit code $exit_code"
        
        # Generate fallback results on failure
        if [ -n "${RUNNER_ID:-}" ]; then
            generate_fallback_results
        fi
    fi
}
trap cleanup_on_error EXIT

# Detect if running as root for sudo usage
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_AUTOMATION_DIR="${SCRIPT_DIR}/eval-automation"
OUTPUT_DIR="${SCRIPT_DIR}/output"

# Create output directory
mkdir -p "${OUTPUT_DIR}"

export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# Argument Parsing
# 1. Parse positional args: API key and UUID run ID
API_KEY=""
RUNNER_ID=""

if [[ $# -gt 0 ]] && [[ "$1" == sk-* ]]; then
    API_KEY="$1"
    shift
    print_status "API key parsed from positional args"
fi

if [[ $# -gt 0 ]] && [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    RUNNER_ID="$1"
    shift
    print_status "Run ID parsed: $RUNNER_ID"
fi

# 2. Parse remaining flag arguments
START_INDEX=0
COUNT=10
BATCH_SIZE=10
TEST_MODEL="private-large"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --concurrency)
            # Not used in this benchmark but parse it
            shift 2
            ;;
        --domain)
            # Not used in this benchmark but parse it
            shift 2
            ;;
        --max-steps)
            # Not used in this benchmark but parse it
            shift 2
            ;;
        --model)
            TEST_MODEL="$2"
            shift 2
            ;;
        --trials)
            COUNT="$2"
            shift 2
            ;;
        --start-index)
            START_INDEX="$2"
            shift 2
            ;;
        --batch-size)
            BATCH_SIZE="$2"
            shift 2
            ;;
        *)
            print_warning "Unknown argument: $1"
            shift
            ;;
    esac
done

# 3. Set default API URL
API_URL="https://grid.ai.juspay.net/v1"

# 4. Export LiteLLM config if applicable
if [ -n "$API_KEY" ]; then
    export LITELLM_API_KEY="$API_KEY"
    export OPENAI_API_KEY="$API_KEY"
fi

export LITE_LLM_URL="https://grid.ai.juspay.net"
export TEST_MODEL="$TEST_MODEL"

print_status "Configuration:"
echo "  Start Index: $START_INDEX"
echo "  Count: $COUNT"
echo "  Batch Size: $BATCH_SIZE"
echo "  Model: $TEST_MODEL"
echo "  API URL: $API_URL"
if [ -n "$RUNNER_ID" ]; then
    echo "  Run ID: $RUNNER_ID"
fi
echo ""

setup_test_script() {
    print_status "Setting up eval environment..."
    
    mkdir -p "$EVAL_AUTOMATION_DIR/results"
    mkdir -p "$EVAL_AUTOMATION_DIR/scoring_outputs"
    mkdir -p "${OUTPUT_DIR}"
    
    print_status "Eval environment ready"
}

check_dependencies() {
    print_status "Checking dependencies..."
    
    if ! command -v tmux &> /dev/null; then
        print_error "tmux is not installed. Please run setup.sh first."
        exit 1
    fi
    
    if ! command -v bun &> /dev/null; then
        print_error "bun is not installed. Please run setup.sh first."
        exit 1
    fi
    
    print_status "Dependencies OK"
}

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
    
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -s http://localhost:3000/health > /dev/null 2>&1; then
            print_status "Server is ready!"
            return 0
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
    done
    
    print_error "Server is not responding at http://localhost:3000"
    print_status "Please ensure services are running via setup.sh"
    exit 1
}

run_test_api() {
    print_status "Running eval on QA pairs..."
    echo "  Start Index: $START_INDEX"
    echo "  Count: $COUNT"
    echo "  Batch Size: $BATCH_SIZE"
    echo ""
    
    cd "$EVAL_AUTOMATION_DIR"
    
    # Run the test with logging
    local log_file="${OUTPUT_DIR}/test_api_${RUNNER_ID:-run}.log"
    
    if RESULTS_DIR="$EVAL_AUTOMATION_DIR/results" \
       bun run test_api_v6.ts "$START_INDEX" "$COUNT" "$BATCH_SIZE" 2>&1 | tee "$log_file"; then
        print_status "test_api_v6.ts completed successfully!"
    else
        print_error "test_api_v6.ts failed!"
        return 1
    fi
}

run_scorer() {
    print_status "Running scorer.ts..."
    echo ""
    
    cd "$EVAL_AUTOMATION_DIR"
    
    local log_file="${OUTPUT_DIR}/scorer_${RUNNER_ID:-run}.log"
    
    if RESULTS_DIR="$EVAL_AUTOMATION_DIR/results" \
       bun run scorer.ts 2>&1 | tee "$log_file"; then
        print_status "scorer.ts completed successfully!"
    else
        print_error "scorer.ts failed!"
        return 1
    fi
}

generate_fallback_results() {
    print_status "Generating fallback results due to failure..."
    
    local output_file="${OUTPUT_DIR}/${RUNNER_ID}_results.json"
    
    cat > "$output_file" << EOF
{
  "metrics": {
    "main": {
      "name": "Overall Score",
      "value": 0
    },
    "secondary": {
      "avg_factuality": 0,
      "avg_completeness": 0,
      "total_items": 0,
      "successful_items": 0
    },
    "additional": {
      "status": "failed",
      "error": "Benchmark execution failed",
      "run_id": "${RUNNER_ID}",
      "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    }
  }
}
EOF
    
    print_status "Fallback results saved to: $output_file"
}

parse_and_generate_results() {
    print_status "Parsing results and generating final output..."
    
    local run_id="${RUNNER_ID:-$(date +%s)}"
    local output_file="${OUTPUT_DIR}/${run_id}_results.json"
    local results_dir="$EVAL_AUTOMATION_DIR/results"
    
    # Find the latest scored results file
    local scored_file=$(ls -t "$results_dir"/scored_*.json 2>/dev/null | head -1)
    
    if [ -z "$scored_file" ] || [ ! -f "$scored_file" ]; then
        print_error "No scored results file found!"
        generate_fallback_results
        return 1
    fi
    
    print_status "Found scored results: $scored_file"
    
    # Parse the results and generate final JSON
    # Use jq if available, otherwise use a simple parser
    if command -v jq &> /dev/null; then
        local avg_overall=$(jq -r '.summary.avg_overall_score // 0' "$scored_file")
        local avg_factuality=$(jq -r '.summary.avg_scores.Factuality // 0' "$scored_file")
        local avg_completeness=$(jq -r '.summary.avg_scores.Completeness // 0' "$scored_file")
        local total_items=$(jq -r '.summary.total_items // 0' "$scored_file")
        local successful_items=$(jq -r '.summary.count // 0' "$scored_file")
        
        cat > "$output_file" << EOF
{
  "metrics": {
    "main": {
      "name": "Overall Score",
      "value": ${avg_overall}
    },
    "secondary": {
      "avg_factuality": ${avg_factuality},
      "avg_completeness": ${avg_completeness},
      "total_items": ${total_items},
      "successful_items": ${successful_items}
    },
    "additional": {
      "status": "completed",
      "model": "${TEST_MODEL}",
      "run_id": "${run_id}",
      "scored_file": "${scored_file}",
      "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    }
  }
}
EOF
    else
        # Fallback without jq - extract values using grep/sed
        local avg_overall=$(grep -o '"avg_overall_score":[0-9.]*' "$scored_file" | cut -d':' -f2 || echo "0")
        local avg_factuality=$(grep -o '"Factuality":[0-9.]*' "$scored_file" | head -1 | cut -d':' -f2 || echo "0")
        local avg_completeness=$(grep -o '"Completeness":[0-9.]*' "$scored_file" | head -1 | cut -d':' -f2 || echo "0")
        local total_items=$(grep -o '"total_items":[0-9]*' "$scored_file" | cut -d':' -f2 || echo "0")
        local successful_items=$(grep -o '"count":[0-9]*' "$scored_file" | cut -d':' -f2 || echo "0")
        
        # Ensure numeric values
        avg_overall=${avg_overall:-0}
        avg_factuality=${avg_factuality:-0}
        avg_completeness=${avg_completeness:-0}
        total_items=${total_items:-0}
        successful_items=${successful_items:-0}
        
        cat > "$output_file" << EOF
{
  "metrics": {
    "main": {
      "name": "Overall Score",
      "value": ${avg_overall}
    },
    "secondary": {
      "avg_factuality": ${avg_factuality},
      "avg_completeness": ${avg_completeness},
      "total_items": ${total_items},
      "successful_items": ${successful_items}
    },
    "additional": {
      "status": "completed",
      "model": "${TEST_MODEL}",
      "run_id": "${run_id}",
      "scored_file": "${scored_file}",
      "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    }
  }
}
EOF
    fi
    
    print_status "Final results saved to: $output_file"
    
    # Display the results
    echo ""
    echo "=========================================="
    echo "  Final Results"
    echo "=========================================="
    cat "$output_file"
    echo ""
}

main() {
    setup_test_script
    check_dependencies
    check_tmux_session
    check_services
    
    echo ""
    echo "=========================================="
    echo "  Starting Eval Pipeline"
    echo "=========================================="
    echo ""
    
    # Run test API
    if ! run_test_api; then
        print_error "Test API phase failed"
        exit 1
    fi
    
    echo ""
    print_status "Test API completed, starting scorer..."
    echo ""
    
    # Run scorer
    if ! run_scorer; then
        print_error "Scorer phase failed"
        exit 1
    fi
    
    # Generate final results
    parse_and_generate_results
    
    echo ""
    echo "=========================================="
    echo "  Eval Pipeline Complete!"
    echo "=========================================="
    echo ""
    echo "Results available in:"
    echo "  ${OUTPUT_DIR}/"
    echo ""
    echo "To view tmux session:"
    echo "  tmux attach -t xyne"
}

main "$@"
