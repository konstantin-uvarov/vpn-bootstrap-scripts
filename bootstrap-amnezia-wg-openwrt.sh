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

    # Function to generic install
    do_install() {
        PKG_NAME=$1
        FILE_NAME=$2
        
        # 1. Check if installed
        if opkg list-installed | grep -q "^$PKG_NAME"; then
             log_info "$PKG_NAME already installed"
             return 0
        fi

        # 2. Try repository install first
        log_info "Attempting to install $PKG_NAME from repository..."
        if opkg install "$PKG_NAME"; then
             log_info "$PKG_NAME installed from repository."
             return 0
        fi
        
        # 3. Download and Install Manual
        log_info "Repository install failed. Attempting manual download..."
        DOWNLOAD_URL="${BASE_URL}v${VERSION}/${FILE_NAME}"
        log_info "Downloading $FILE_NAME..."
        
        if wget -O "$AWG_DIR/$FILE_NAME" "$DOWNLOAD_URL"; then
             log_info "Installing $FILE_NAME..."
             if opkg install "$AWG_DIR/$FILE_NAME"; then
                 return 0
             else
                 ERR_CODE=$?
                 log_error "Failed to install $FILE_NAME using standard method."
                 
                 # Check for architecture mismatch
                 # Constructed Arch from script logic: ${PKGARCH}_${TARGET}_${SUBTARGET}
                 EXPECTED_ARCH="${PKGARCH}_${TARGET}_${SUBTARGET}"
                 
                 if ! opkg print-architecture | grep -q "$EXPECTED_ARCH"; then
                     printf "${RED}[WARNING]${NC} Installation failed due to architecture mismatch.\n"
                     printf "Package architecture: $EXPECTED_ARCH\n"
                     printf "Do you want to add '$EXPECTED_ARCH' to opkg config? [y/N]: "
                     read ARCH_CHOICE
                     if [ "$ARCH_CHOICE" = "y" ] || [ "$ARCH_CHOICE" = "Y" ]; then
                         # Determine priority - usually end of list + 10 or just high number
                         # Default to 200 to be safe/low priority
                         ARCH_CONF="/etc/opkg/arch.conf"
                         if [ -f "/etc/opkg.conf" ] && grep -q "arch " "/etc/opkg.conf"; then
                             ARCH_CONF="/etc/opkg.conf"
                         fi
                         
                         log_info "Adding 'arch $EXPECTED_ARCH 200' to $ARCH_CONF"
                         echo "arch $EXPECTED_ARCH 200" >> "$ARCH_CONF"
                         opkg update >/dev/null 2>&1 # Refresh not strictly needed for local install but good practice
                     else
                         log_error "Cannot proceed without matching architecture."
                         exit 1
                     fi
                 fi

                 # Check for kernel mismatch heuristic (output likely contains dependency error)
                 printf "${RED}[WARNING]${NC} We will now attempt to force installation to bypass kernel dependencies.\n"
                 printf "Do you want to proceed? (Recursive force-depends) [y/N]: "
                 read FORCE_CHOICE
                 if [ "$FORCE_CHOICE" = "y" ] || [ "$FORCE_CHOICE" = "Y" ]; then
                     log_info "Attempting force installation..."
                     if opkg install "$AWG_DIR/$FILE_NAME" --force-depends; then
                         log_info "$PKG_NAME installed with force-depends."
                         return 0
                     else
                         log_error "Force installation of $PKG_NAME failed."
                         exit 1
                     fi
                 else
                     exit 1
                 fi
             fi
        else
             log_error "Error downloading $FILE_NAME."
             exit 1
        fi
    }

    # Install kmod-amneziawg
    do_install "kmod-amneziawg" "kmod-amneziawg${PKGPOSTFIX}"

    # Install amneziawg-tools
    do_install "amneziawg-tools" "amneziawg-tools${PKGPOSTFIX}"

    # Install LuCI package
    do_install "$LUCI_PACKAGE_NAME" "${LUCI_PACKAGE_NAME}${PKGPOSTFIX}"

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
