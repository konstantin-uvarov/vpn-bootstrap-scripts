#!/bin/sh

# AmneziaWG Installer for OpenWrt
# Based on https://github.com/Slava-Shchipunov/awg-openwrt
# Packages source: https://github.com/konstantin-uvarov/awg-openwrt

# Colors
GREEN='\033[32;1m'
RED='\033[31;1m'
NC='\033[0m'

log_info() { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

check_repo() {
    log_info "Checking OpenWrt repo availability..."
    if opkg update 2>&1 | grep -q "Failed to download"; then
        log_error "opkg update failed. Check internet or date."
        log_error "Force NTP sync: ntpd -p ptbtime1.ptb.de"
        exit 1
    fi
}

install_awg_packages() {
    # Architecture detection (get highest priority arch)
    PKGARCH=$(opkg print-architecture | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}')
    
    # Target and version detection
    TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 1)
    SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 2)
    VERSION=$(ubus call system board | jsonfilter -e '@.release.version')
    
    PKGPOSTFIX="_v${VERSION}_${PKGARCH}_${TARGET}_${SUBTARGET}.ipk"
    BASE_URL="https://github.com/konstantin-uvarov/awg-openwrt/releases/download/"

    # Determine AWG protocol version (2.0 for OpenWrt >= 23.05.6 or >= 24.10.3)
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

    log_info "OpenWrt version: $VERSION"
    log_info "Architecture: $PKGARCH ($TARGET/$SUBTARGET)"
    log_info "AWG protocol version: $AWG_VERSION"
    
    AWG_DIR="/tmp/amneziawg"
    mkdir -p "$AWG_DIR"

    # Install package function
    install_pkg() {
        PKG_NAME="$1"
        FILE_NAME="$2"
        
        if opkg list-installed | grep -q "^${PKG_NAME} "; then
            log_info "$PKG_NAME is already installed"
            return 0
        fi

        DOWNLOAD_URL="${BASE_URL}v${VERSION}/${FILE_NAME}"
        log_info "Downloading $FILE_NAME..."
        
        if ! wget -q -O "$AWG_DIR/$FILE_NAME" "$DOWNLOAD_URL"; then
            log_error "Failed to download $FILE_NAME"
            log_error "URL: $DOWNLOAD_URL"
            exit 1
        fi
        
        log_info "Installing $PKG_NAME..."
        if ! opkg install "$AWG_DIR/$FILE_NAME"; then
            log_error "Failed to install $PKG_NAME"
            exit 1
        fi
        
        log_info "$PKG_NAME installed successfully"
    }

    # Install packages
    install_pkg "kmod-amneziawg" "kmod-amneziawg${PKGPOSTFIX}"
    install_pkg "amneziawg-tools" "amneziawg-tools${PKGPOSTFIX}"
    install_pkg "$LUCI_PACKAGE_NAME" "${LUCI_PACKAGE_NAME}${PKGPOSTFIX}"

    rm -rf "$AWG_DIR"
    log_info "All AmneziaWG packages installed successfully"
}

configure_interface() {
    DEFAULT_IFACE="awg0"
    
    printf "\n${GREEN}Interface Configuration${NC}\n"
    printf "Enter interface name [%s]: " "$DEFAULT_IFACE"
    read -r input_iface
    INTERFACE_NAME="${input_iface:-$DEFAULT_IFACE}"

    # Check if interface exists
    if uci -q get network."$INTERFACE_NAME" >/dev/null 2>&1; then
        printf "Interface '%s' already exists.\n" "$INTERFACE_NAME"
        printf "[O]verwrite, [S]kip, or [A]uto-increment? (o/s/a): "
        read -r action
        case "$action" in
            o|O)
                log_info "Removing existing interface '$INTERFACE_NAME'..."
                uci delete network."$INTERFACE_NAME" 2>/dev/null
                # Also remove associated peer configs
                uci show network 2>/dev/null | grep -o "network\.@amneziawg_${INTERFACE_NAME}\[" | \
                    sed 's/\[$//' | while read -r peer; do
                        uci delete "$peer" 2>/dev/null
                    done
                ;;
            s|S)
                log_info "Skipping interface creation"
                return 0
                ;;
            a|A|*)
                i=0
                while uci -q get network.awg$i >/dev/null 2>&1; do
                    i=$((i + 1))
                done
                INTERFACE_NAME="awg$i"
                log_info "Using auto-incremented name: $INTERFACE_NAME"
                ;;
        esac
    fi

    # Create interface
    printf "Create AmneziaWG interface '%s'? (y/n) [y]: " "$INTERFACE_NAME"
    read -r create_iface
    create_iface="${create_iface:-y}"
    
    if [ "$create_iface" != "y" ] && [ "$create_iface" != "Y" ]; then
        log_info "Skipping interface creation"
        return 0
    fi

    uci set network."$INTERFACE_NAME"=interface
    uci set network."$INTERFACE_NAME".proto='amneziawg'
    log_info "Interface '$INTERFACE_NAME' created (proto=amneziawg)"

    # Create firewall zone
    ZONE_NAME="$INTERFACE_NAME"
    printf "Create firewall zone '%s'? (y/n) [y]: " "$ZONE_NAME"
    read -r create_zone
    create_zone="${create_zone:-y}"

    if [ "$create_zone" = "y" ] || [ "$create_zone" = "Y" ]; then
        if uci show firewall 2>/dev/null | grep -q "@zone.*name='$ZONE_NAME'"; then
            log_info "Firewall zone '$ZONE_NAME' already exists"
        else
            uci add firewall zone >/dev/null
            uci set firewall.@zone[-1].name="$ZONE_NAME"
            uci set firewall.@zone[-1].network="$INTERFACE_NAME"
            uci set firewall.@zone[-1].input='REJECT'
            uci set firewall.@zone[-1].output='ACCEPT'
            uci set firewall.@zone[-1].forward='REJECT'
            uci set firewall.@zone[-1].masq='1'
            uci set firewall.@zone[-1].mtu_fix='1'
            log_info "Firewall zone '$ZONE_NAME' created"
        fi
    fi

    # Create forwarding rule (LAN -> AWG zone)
    printf "Configure forwarding (lan -> %s)? (y/n) [y]: " "$ZONE_NAME"
    read -r create_fwd
    create_fwd="${create_fwd:-y}"

    if [ "$create_fwd" = "y" ] || [ "$create_fwd" = "Y" ]; then
        FWD_NAME="lan_${ZONE_NAME}"
        if uci show firewall 2>/dev/null | grep -q "@forwarding.*dest='$ZONE_NAME'"; then
            log_info "Forwarding to '$ZONE_NAME' already exists"
        else
            uci add firewall forwarding >/dev/null
            uci set firewall.@forwarding[-1].src='lan'
            uci set firewall.@forwarding[-1].dest="$ZONE_NAME"
            log_info "Forwarding lan -> $ZONE_NAME configured"
        fi
    fi

    uci commit network
    uci commit firewall
    log_info "Configuration saved"
}

# Main
check_repo
install_awg_packages

printf "\n${GREEN}Configure AmneziaWG interface now? (y/n) [y]: ${NC}"
read -r configure_now
configure_now="${configure_now:-y}"

if [ "$configure_now" = "y" ] || [ "$configure_now" = "Y" ]; then
    configure_interface
fi

printf "\n${GREEN}===== Setup Complete =====${NC}\n"
printf "\nNext steps:\n"
printf "1. Go to LuCI -> Network -> Interfaces\n"
printf "2. Edit the AmneziaWG interface (or create new with protocol 'AmneziaWG VPN')\n"
printf "3. Click 'Load configuration' and import your .conf file\n"
printf "4. Go to Peers tab -> Edit peer -> Enable 'Route Allowed IPs'\n"
printf "5. Save & Apply, then restart network\n"
printf "\nDocumentation: https://docs.amnezia.org/documentation/instructions/openwrt-os-awg/\n\n"

printf "Restart network now? (y/n) [n]: "
read -r restart_net
restart_net="${restart_net:-n}"

if [ "$restart_net" = "y" ] || [ "$restart_net" = "Y" ]; then
    log_info "Restarting network..."
    service network restart
fi
