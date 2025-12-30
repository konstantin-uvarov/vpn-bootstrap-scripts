#!/usr/bin/env bash
#
# Sing-Box VPN Server - Bootstrap Script
# Downloads and sets up the sing-box VPN server on a fresh Linux VM
#
# Usage:
#   curl -sSL <PUBLIC_URL>/bootstrap-sing-box.sh | bash
#   # Or download first:
#   curl -sSL <PUBLIC_URL>/bootstrap-sing-box.sh -o bootstrap.sh && bash bootstrap.sh
#

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Target repository (private - will prompt for token if needed)
DEFAULT_REPO="https://github.com/konstantin-uvarov/docker-sing-box.git"

# All log functions output to stderr so they don't interfere with function return values
log_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[OK]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# ============================================================================
# Environment Detection
# ============================================================================

is_wsl2() {
    grep -qi microsoft /proc/version 2>/dev/null || [[ -n "${WSL_DISTRO_NAME:-}" ]]
}

get_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    else
        echo ""
    fi
}

# ============================================================================
# Pre-flight Checks
# ============================================================================

check_sudo() {
    log_info "Checking sudo privileges..."

    if [[ $EUID -eq 0 ]]; then
        log_warn "Running as root. Consider using a regular user with sudo."
        return 0
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        log_error "sudo is not installed. Install sudo or run as root."
        exit 1
    fi

    # Test if sudo works (may prompt for password)
    if ! sudo -v; then
        log_error "Cannot obtain sudo privileges. Check your sudoers configuration."
        exit 1
    fi

    log_success "Sudo privileges confirmed"
}

check_environment() {
    log_info "Detecting environment..."

    if is_wsl2; then
        log_warn "WSL2 environment detected"
        log_warn "Limitations:"
        log_warn "  - Public IP detection may return internal WSL2 IP"
        log_warn "  - VPN won't be accessible from outside this machine"
        log_warn "  - For production, use a cloud VM (Azure, GCP, AWS, DigitalOcean)"
        echo "" >&2
        read -r -p "Continue anyway? [y/N]: " confirm </dev/tty
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Aborting. Use 'make init' on a cloud VM instead."
            exit 0
        fi
    fi

    local pkg_manager
    pkg_manager=$(get_package_manager)
    if [[ -z "$pkg_manager" ]]; then
        log_error "Unsupported system: neither apt nor yum found"
        exit 1
    fi

    log_success "Package manager: ${pkg_manager}"
}

# ============================================================================
# Package Installation
# ============================================================================

install_package() {
    local cmd="$1"
    local pkg="$2"

    if command -v "$cmd" >/dev/null 2>&1; then
        log_info "${pkg} already installed"
        return 0
    fi

    log_info "Installing ${pkg}..."
    local pkg_manager
    pkg_manager=$(get_package_manager)

    case "$pkg_manager" in
        apt)
            sudo apt-get update -qq
            sudo apt-get install -y "$pkg"
            ;;
        yum)
            sudo yum install -y "$pkg"
            ;;
    esac

    if command -v "$cmd" >/dev/null 2>&1; then
        log_success "${pkg} installed"
    else
        log_error "Failed to install ${pkg}"
        return 1
    fi
}

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        log_info "Docker already installed"
    else
        log_info "Installing Docker..."
        local pkg_manager
        pkg_manager=$(get_package_manager)

        case "$pkg_manager" in
            apt)
                sudo apt-get update -qq
                sudo apt-get install -y docker.io
                ;;
            yum)
                sudo yum install -y docker
                ;;
        esac
    fi

    # Try to enable Docker service (skip on WSL2 with Docker Desktop)
    if command -v systemctl >/dev/null 2>&1 && ! is_wsl2; then
        log_info "Enabling Docker service..."
        sudo systemctl enable --now docker || true
    elif is_wsl2; then
        log_info "WSL2 detected - assuming Docker Desktop integration"
    fi

    # Verify Docker is working
    if docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1; then
        log_success "Docker is running"
    else
        if is_wsl2; then
            log_error "Docker not responding. Ensure Docker Desktop is running on Windows."
            log_error "In Docker Desktop: Settings > Resources > WSL Integration > Enable for your distro"
        else
            log_error "Docker installation failed or daemon not responding"
        fi
        exit 1
    fi
}

install_compose_plugin() {
    if docker compose version >/dev/null 2>&1; then
        log_info "Docker Compose plugin already installed"
        return 0
    fi

    log_info "Installing Docker Compose plugin..."
    local pkg_manager
    pkg_manager=$(get_package_manager)

    case "$pkg_manager" in
        apt)
            # Try from default repos first
            sudo apt-get update -qq
            if ! sudo apt-get install -y docker-compose-plugin 2>/dev/null; then
                # Add Docker's official repository
                log_info "Adding Docker official repository..."
                sudo apt-get install -y ca-certificates curl gnupg
                sudo install -m 0755 -d /etc/apt/keyrings
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
                sudo chmod a+r /etc/apt/keyrings/docker.gpg
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
                sudo apt-get update -qq
                sudo apt-get install -y docker-compose-plugin
            fi
            ;;
        yum)
            # Try default repos first, then add Docker's official repo
            if ! sudo yum install -y docker-compose-plugin 2>/dev/null; then
                log_info "Adding Docker official repository..."
                sudo yum install -y yum-utils
                sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                sudo yum install -y docker-compose-plugin
            fi
            ;;
    esac

    if docker compose version >/dev/null 2>&1; then
        log_success "Docker Compose plugin installed"
    else
        log_error "Failed to install Docker Compose plugin"
        log_error "See: https://docs.docker.com/compose/install/linux/"
        exit 1
    fi
}

# ============================================================================
# Repository Setup
# ============================================================================

prompt_repo_url() {
    read -r -p "Repository URL [${DEFAULT_REPO}]: " repo_url </dev/tty
    echo "${repo_url:-$DEFAULT_REPO}"
}

clone_with_token() {
    local url="$1"
    local token="$2"
    # Remove protocol prefix if present
    local cleaned
    cleaned=$(echo "$url" | sed -e 's#^https://##' -e 's#^http://##')
    git clone "https://${token}@${cleaned}"
}

clone_repository() {
    local repo_url="$1"
    local target_dir
    target_dir=$(basename "$repo_url" .git)

    if [[ -d "$target_dir" ]]; then
        log_info "Directory '${target_dir}' already exists"
        echo "$target_dir"
        return 0
    fi

    log_info "Cloning ${repo_url}..."

    # Disable git credential prompt - we'll handle auth ourselves
    local clone_output
    if clone_output=$(GIT_TERMINAL_PROMPT=0 git clone "$repo_url" 2>&1); then
        log_success "Repository cloned"
        echo "$target_dir"
        return 0
    fi

    # Clone failed, show the error and ask for token
    log_warn "Clone failed. Git output:"
    echo "$clone_output" >&2
    echo "" >&2
    read -r -p "Enter GitHub personal access token (leave blank to abort): " -s gh_token </dev/tty
    echo "" >&2

    if [[ -z "$gh_token" ]]; then
        log_error "No token provided. Aborting."
        exit 1
    fi

    if clone_with_token "$repo_url" "$gh_token"; then
        log_success "Repository cloned with token"
        echo "$target_dir"
    else
        log_error "Clone failed even with token. Check the URL and token permissions."
        exit 1
    fi
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo "" >&2
    echo "==========================================" >&2
    echo "  Sing-Box VPN Server - Bootstrap Script" >&2
    echo "==========================================" >&2
    echo "" >&2

    # Pre-flight checks
    check_sudo
    check_environment

    # Install prerequisites
    install_package git git
    install_package make make
    install_package curl curl
    install_package envsubst gettext-base
    install_package jq jq
    install_docker
    install_compose_plugin

    echo "" >&2

    # Clone repository
    repo_url=$(prompt_repo_url)
    target_dir=$(clone_repository "$repo_url")

    # Enter directory and run setup
    cd "$target_dir"

    echo "" >&2
    log_info "Running 'make start' in ${target_dir}..."
    echo "" >&2

    make start

    echo "" >&2
    log_success "Bootstrap complete!"
}

main "$@"
