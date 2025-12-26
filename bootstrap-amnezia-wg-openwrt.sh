#!/bin/sh

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() {
    printf "${GREEN}[INFO]${NC} $1\n"
}

log_error() {
    printf "${RED}[ERROR]${NC} $1\n"
}

check_repo() {
    log_info "Checking OpenWrt repo availability..."
    opkg update | grep -q "Failed to download" && log_error "opkg failed. Check internet or date. Command for force ntp sync: ntpd -p ptbtime1.ptb.de" && exit 1
}

install_awg_packages() {
    # Architecture detection
    PKGARCH=$(opkg print-architecture | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}')
    
    # Target detection
    TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 1)
    SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 2)
    VERSION=$(ubus call system board | jsonfilter -e '@.release.version')
    PKGPOSTFIX="_v${VERSION}_${PKGARCH}_${TARGET}_${SUBTARGET}.ipk"
    BASE_URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/"

    # Version Logic
    AWG_VERSION="1.0"
    MAJOR_VERSION=$(echo "$VERSION" | cut -d '.' -f 1)
    MINOR_VERSION=$(echo "$VERSION" | cut -d '.' -f 2)
    PATCH_VERSION=$(echo "$VERSION" | cut -d '.' -f 3)

    if [ "$MAJOR_VERSION" -gt 24 ] || \
       [ "$MAJOR_VERSION" -eq 24 -a "$MINOR_VERSION" -gt 10 ] || \
       [ "$MAJOR_VERSION" -eq 24 -a "$MINOR_VERSION" -eq 10 -a "$PATCH_VERSION" -ge 3 ] || \
       [ "$MAJOR_VERSION" -eq 23 -a "$MINOR_VERSION" -eq 5 -a "$PATCH_VERSION" -ge 6 ]; then
        AWG_VERSION="2.0"
        LUCI_PACKAGE_NAME="luci-proto-amneziawg"
    else
        LUCI_PACKAGE_NAME="luci-app-amneziawg"
    fi

    log_info "Detected AWG version: $AWG_VERSION"
    
    AWG_DIR="/tmp/amneziawg"
    mkdir -p "$AWG_DIR"

    # Install kmod-amneziawg
    if opkg list-installed | grep -q kmod-amneziawg; then
        log_info "kmod-amneziawg already installed"
    else
        KMOD_AMNEZIAWG_FILENAME="kmod-amneziawg${PKGPOSTFIX}"
        DOWNLOAD_URL="${BASE_URL}v${VERSION}/${KMOD_AMNEZIAWG_FILENAME}"
        log_info "Downloading $KMOD_AMNEZIAWG_FILENAME..."
        wget -O "$AWG_DIR/$KMOD_AMNEZIAWG_FILENAME" "$DOWNLOAD_URL"

        if [ $? -eq 0 ]; then
            opkg install "$AWG_DIR/$KMOD_AMNEZIAWG_FILENAME" || { log_error "Failed to install kmod-amneziawg"; exit 1; }
        else
            log_error "Error downloading kmod-amneziawg. Check your internet or device compatibility."
            exit 1
        fi
    fi

    # Install amneziawg-tools
    if opkg list-installed | grep -q amneziawg-tools; then
        log_info "amneziawg-tools already installed"
    else
        AMNEZIAWG_TOOLS_FILENAME="amneziawg-tools${PKGPOSTFIX}"
        DOWNLOAD_URL="${BASE_URL}v${VERSION}/${AMNEZIAWG_TOOLS_FILENAME}"
        log_info "Downloading $AMNEZIAWG_TOOLS_FILENAME..."
        wget -O "$AWG_DIR/$AMNEZIAWG_TOOLS_FILENAME" "$DOWNLOAD_URL"

        if [ $? -eq 0 ]; then
            opkg install "$AWG_DIR/$AMNEZIAWG_TOOLS_FILENAME" || { log_error "Failed to install amneziawg-tools"; exit 1; }
        else
            log_error "Error downloading amneziawg-tools."
            exit 1
        fi
    fi

    # Install LuCI package
    if opkg list-installed | grep -q "$LUCI_PACKAGE_NAME"; then
        log_info "$LUCI_PACKAGE_NAME already installed"
    else
        LUCI_AMNEZIAWG_FILENAME="${LUCI_PACKAGE_NAME}${PKGPOSTFIX}"
        DOWNLOAD_URL="${BASE_URL}v${VERSION}/${LUCI_AMNEZIAWG_FILENAME}"
        log_info "Downloading $LUCI_AMNEZIAWG_FILENAME..."
        wget -O "$AWG_DIR/$LUCI_AMNEZIAWG_FILENAME" "$DOWNLOAD_URL"

        if [ $? -eq 0 ]; then
            opkg install "$AWG_DIR/$LUCI_AMNEZIAWG_FILENAME" || { log_error "Failed to install $LUCI_PACKAGE_NAME"; exit 1; }
        else
            log_error "Error downloading $LUCI_PACKAGE_NAME."
            exit 1
        fi
    fi

    rm -rf "$AWG_DIR"
    log_info "All packages installed successfully."
}

configure_interface() {
    log_info "Starting Interface Configuration..."
    
    # Interface Name Logic
    DEFAULT_IFACE="awg0"
    while true; do
        printf "Enter interface name [default: $DEFAULT_IFACE]: "
        read input_iface
        INTERFACE_NAME=${input_iface:-$DEFAULT_IFACE}

        if uci get network.$INTERFACE_NAME >/dev/null 2>&1; then
            printf "Interface '$INTERFACE_NAME' already exists.\n"
            printf "[O]verwrite, [S]kip, or [A]uto-increment? (o/s/a): "
            read action
            case "$action" in
                o|O) 
                    log_info "Overwriting '$INTERFACE_NAME'..."
                    uci delete network.$INTERFACE_NAME
                    break 
                    ;;
                s|S)
                    log_info "Skipping interface creation."
                    return 
                    ;;
                a|A)
                    i=0
                    while uci get network.awg$i >/dev/null 2>&1; do
                        i=$((i+1))
                    done
                    DEFAULT_IFACE="awg$i"
                    printf "Suggested new name: $DEFAULT_IFACE\n"
                    ;;
                *)
                    echo "Invalid choice."
                    ;;
            esac
        else
            break
        fi
    done

    # Create Interface
    printf "Create AmneziaWG interface '$INTERFACE_NAME'? (y/n) [y]: "
    read proceed
    proceed=${proceed:-y}
    
    if [ "$proceed" = "y" ]; then
        uci set network.$INTERFACE_NAME=interface
        uci set network.$INTERFACE_NAME.proto='amneziawg'
        log_info "Interface '$INTERFACE_NAME' created."
    else
        log_info "Skipped interface creation."
        return
    fi
    
    # Create Firewall Zone
    ZONE_NAME="${INTERFACE_NAME}_zone"
    printf "Create firewall zone '$ZONE_NAME' for '$INTERFACE_NAME'? (y/n) [y]: "
    read create_fw
    create_fw=${create_fw:-y}

    if [ "$create_fw" = "y" ]; then
        # Check if zone exists
        if uci show firewall | grep -q "@zone.*name='$ZONE_NAME'"; then
             log_info "Firewall zone '$ZONE_NAME' already exists. Skipping creation."
        else
            uci add firewall zone >/dev/null
            uci set firewall.@zone[-1].name="$ZONE_NAME"
            uci set firewall.@zone[-1].network="$INTERFACE_NAME"
            uci set firewall.@zone[-1].input='REJECT'
            uci set firewall.@zone[-1].output='ACCEPT'
            uci set firewall.@zone[-1].forward='REJECT'
            uci set firewall.@zone[-1].masq='1'
            uci set firewall.@zone[-1].mtu_fix='1'
            log_info "Firewall zone '$ZONE_NAME' created."
        fi
    fi

    # Create Forwarding
    printf "Configure firewall forwarding (LAN -> $ZONE_NAME)? (y/n) [y]: "
    read create_fwd
    create_fwd=${create_fwd:-y}

    if [ "$create_fwd" = "y" ]; then
        FWD_NAME="lan_${ZONE_NAME}"
        if uci show firewall | grep -q "@forwarding.*name='$FWD_NAME'"; then
             log_info "Forwarding '$FWD_NAME' already exists. Skipping."
        else
            uci add firewall forwarding >/dev/null
            uci set firewall.@forwarding[-1].name="$FWD_NAME"
            uci set firewall.@forwarding[-1].src='lan'
            uci set firewall.@forwarding[-1].dest="$ZONE_NAME"
            log_info "Forwarding LAN -> $ZONE_NAME configured."
        fi
    fi
    
    uci commit network
    uci commit firewall
    log_info "Configuration committed."
}

# Main Execution
check_repo
install_awg_packages
configure_interface

printf "\n${GREEN}Setup Complete!${NC}\n"
printf "Next steps:\n"
printf "1. Go to LuCI -> Network -> Interfaces.\n"
printf "2. Edit '$INTERFACE_NAME' (or the one you created).\n"
printf "3. Click 'Load configuration' and upload your AmneziaWG .conf file.\n"
printf "4. Restart the network to apply changes.\n\n"

printf "Restart network now? (y/n) [n]: "
read restart_net
restart_net=${restart_net:-n}

if [ "$restart_net" = "y" ]; then
    log_info "Restarting network..."
    service network restart
fi
