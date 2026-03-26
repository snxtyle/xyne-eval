#!/bin/bash

echo "=========================================="
echo "  Xyne Development Setup"
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

cleanup_docker() {
    print_status "Cleaning up Docker environment..."
    docker stop $(docker ps -aq) 2>/dev/null || true
    docker system prune -f 2>/dev/null || true
    docker volume prune -f 2>/dev/null || true
    orb restart docker 2>/dev/null || true
    sleep 5
}

# Check if tmux is installed
if ! command -v tmux &> /dev/null; then
    print_status "Installing tmux..."
    if command -v brew &> /dev/null; then
        brew install tmux
    else
        print_error "Please install tmux manually"
        exit 1
    fi
fi

# Check if bun is installed
if ! command -v bun &> /dev/null; then
    print_status "Installing bun..."
    curl -fsSL https://bun.sh/install | bash
fi

export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

print_status "Checking Docker..."
if ! command -v docker &> /dev/null; then
    print_warning "Docker is not installed"
    print_status "Installing Docker..."
    
    echo ""
    echo "Please choose your Docker backend:"
    echo "  1) Docker Desktop (default)"
    echo "  2) OrbStack (faster, macOS native)"
    echo "  3) Podman (open source)"
    echo ""
    read -p "Enter choice (1-3) or 'q' to quit: " choice
    
    case $choice in
        2)
            print_status "Installing OrbStack..."
            curl -fsSL https://orbstack.dev/download | bash
            orb start docker
            ;;
        3)
            print_status "Installing Podman..."
            brew install podman
            podman machine init
            podman machine start
            ;;
        *)
            print_status "Installing Docker Desktop..."
            brew install --cask docker
            open -a Docker
            print_warning "Please start Docker Desktop and press Enter to continue..."
            read
            ;;
    esac
fi

if ! docker info &> /dev/null; then
    print_error "Docker is not running"
    print_warning "Please start Docker Desktop, OrbStack, or Podman"
    exit 1
fi

print_status "Detecting Docker environment..."
DOCKER_BACKEND="unknown"
if command -v orb &> /dev/null; then
    DOCKER_BACKEND="orbstack"
    print_status "Detected OrbStack Docker"
elif command -v podman &> /dev/null; then
    DOCKER_BACKEND="podman"
    print_status "Detected Podman"
else
    DOCKER_BACKEND="docker"
    print_status "Detected Docker Desktop"
fi

print_status "Cleaning up stale Docker resources..."
docker stop $(docker ps -aq) 2>/dev/null || true
docker system prune -f --volumes 2>/dev/null || true

if [ "$DOCKER_BACKEND" = "orbstack" ]; then
    print_status "Restarting OrbStack Docker daemon..."
    orb restart docker 2>/dev/null || true
    sleep 3
elif [ "$DOCKER_BACKEND" = "podman" ]; then
    print_status "Restarting Podman..."
    podman machine stop 2>/dev/null || true
    podman machine start 2>/dev/null || true
    sleep 3
fi

# Kill processes on ports
print_status "Killing existing processes on ports..."
lsof -ti :3000 | xargs kill -9 2>/dev/null || true
lsof -ti :3001 | xargs kill -9 2>/dev/null || true
lsof -ti :5173 | xargs kill -9 2>/dev/null || true

# Stop Docker app container
docker stop xyne-app 2>/dev/null || true

print_status "Creating .env file..."
if [ ! -f "server/.env" ]; then
    if [ -f "server/.env.default" ]; then
        cp server/.env.default server/.env
    fi
fi

# Clean and reinstall frontend
print_status "Cleaning and installing frontend dependencies..."
cd frontend
rm -rf node_modules bun.lockb package-lock.json
npm install --legacy-peer-deps
cd ..

# Clean and reinstall server
print_status "Cleaning and installing server dependencies..."
cd server
rm -rf node_modules bun.lockb package-lock.json
bun install
bun add -d @esbuild/darwin-x64
bun add @xyne/vespa-ts
cd ..

# Kill existing session (ignore errors)
tmux kill-session -t xyne 2>/dev/null || true
sleep 1

# Enable mouse scrolling in tmux
tmux set -g mouse on 2>/dev/null || true

print_status "Creating tmux session with 3 windows..."

# Get current directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Kill any existing tmux session
tmux kill-session -t xyne 2>/dev/null || true
sleep 1

# Enable mouse scrolling in tmux
tmux set -g mouse on 2>/dev/null || true

# Create new tmux session with 3 windows
tmux new-session -d -s xyne -n "docker"
tmux send-keys -t xyne:docker "cd ${SCRIPT_DIR} && docker-compose -f deployment/docker-compose.yml pull && docker-compose -f deployment/docker-compose.yml up" C-m

tmux new-window -t xyne -n "server"
tmux send-keys -t xyne:server "cd ${SCRIPT_DIR}/server && bun run dev" C-m

tmux new-window -t xyne -n "frontend"
tmux send-keys -t xyne:frontend "cd ${SCRIPT_DIR}/frontend && npm install rollup --legacy-peer-deps && npm run dev" C-m

# List windows to verify
tmux list-windows -t xyne

print_status "3 tmux windows created!"
echo ""
echo "=========================================="
echo "  TMUX SESSION DETAILS"
echo "=========================================="
echo ""
echo "To view all 3 terminal windows, run:"
echo "  tmux attach -t xyne"
echo ""
echo "In tmux session:"
echo "  - Ctrl+b n  : Switch to next window"
echo "  - Ctrl+b p  : Switch to previous window"
echo "  - Ctrl+b 0  : Go to docker window"
echo "  - Ctrl+b 1  : Go to server window"
echo "  - Ctrl+b 2  : Go to frontend window"
echo "  - Ctrl+b d  : Detach from tmux"
echo ""
echo "Or open VS Code terminal (Cmd+Shift+\`) and run:"
echo "  tmux attach -t xyne"

print_status "=========================================="
print_status "Setup complete!"
print_status "=========================================="
echo ""
echo "Access the application:"
echo "  - Frontend: http://localhost:5173"
echo "  - Backend:  http://localhost:3000"
echo ""
echo "3 Terminal windows should now be open."