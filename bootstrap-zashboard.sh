#!/bin/sh
#
# Zashboard Installer for OpenWRT (sing-box)
#
# Usage:
#   curl -sSL <URL>/bootstrap-zashboard.sh | sh
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check for opkg
if ! command -v opkg >/dev/null 2>&1; then
    log_error "opkg not found. Is this OpenWRT?"
    exit 1
fi

# Install dependencies
log_info "Installing dependencies..."
opkg update
opkg install unzip curl

# Define paths
INSTALL_DIR="/www/zashboard"

# Create install directory
if [ -d "$INSTALL_DIR" ]; then
    log_info "Cleaning existing installation..."
    rm -rf "$INSTALL_DIR"
fi
mkdir -p "$INSTALL_DIR"

# Get latest release URL
log_info "Fetching latest release info..."
# Use GitHub API to find latest release tag
LATEST_TAG=$(curl -s "https://api.github.com/repos/Zephyruso/zashboard/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$LATEST_TAG" ]; then
    log_error "Failed to fetch latest release tag. Defaulting to known version if necessary, or check internet connection."
    # Fallback could be implemented here, but for now we error out to avoid broken installs
    exit 1
fi

log_info "Latest version: $LATEST_TAG"
DOWNLOAD_URL="https://github.com/Zephyruso/zashboard/releases/download/$LATEST_TAG/dist.zip"

# Download and extract
TMP_FILE="/tmp/zashboard.zip"
log_info "Downloading Zashboard..."
curl -L -o "$TMP_FILE" "$DOWNLOAD_URL"

log_info "Extracting to $INSTALL_DIR..."
unzip -q "$TMP_FILE" -d "$INSTALL_DIR"
rm "$TMP_FILE"

# Make sure index.html exists
if [ ! -f "$INSTALL_DIR/index.html" ]; then
    log_error "Installation failed: index.html not found in extracted files."
    exit 1
fi

log_info "Zashboard installed successfully at $INSTALL_DIR"
log_info ""
log_info "Verify your sing-box configuration has 'experimental.clash_api' enabled:"
log_info "{"
log_info "  \"experimental\": {"
log_info "    \"clash_api\": {"
log_info "      \"external_controller\": \"0.0.0.0:9090\","
log_info "      \"external_ui\": \"$INSTALL_DIR\""
log_info "    }"
log_info "  }"
log_info "}"
log_info ""
log_info "Access the dashboard at http://<ROUTER_IP>:9090/ui"
