#!/bin/bash

# --- Script to Setup dnsmasq and iptables Redirect on RPi Bookworm ---
# --- Redirects all client DNS lookups to the Pi itself, and ---
# --- forwards incoming HTTP traffic (port 80) to localhost:TARGET_PORT ---

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error
set -u

# --- CONFIGURATION (EDIT THESE VALUES!) ---

# Network interface clients will connect TO on the Pi (e.g., wlan0, eth0)
PI_INTERFACE="wlan1"

# The EXACT name of the NetworkManager connection for the interface above
# Find using: nmcli connection show
NM_CON_NAME="Hotspot" # Example: Replace with "Wired connection 1", "YourWifiSSID", etc.

# Static IP address for the Pi on the chosen interface
PI_STATIC_IP="192.168.4.1"

# Subnet prefix (e.g., /24 for 255.255.255.0)
PI_IP_PREFIX="24"

# Gateway IP address (Often the Pi's own IP if it's the router for this segment,
# or your main router's IP if Pi is just joining an existing network)
PI_GATEWAY="192.168.8.195" # Example: Use 192.168.1.1 if PI_STATIC_IP is 192.168.1.10

# DNS Servers for the Pi ITSELF (comma-separated, no spaces)
# Use external DNS or 127.0.0.1 if dnsmasq handles upstream lookups
PI_DNS_SERVERS="1.1.1.1,8.8.8.8"

# Port on localhost to redirect HTTP traffic to
TARGET_PORT="3000"

# Enable dnsmasq's DHCP server? (true/false)
# Set to true ONLY if the Pi should assign IPs to clients on this interface.
ENABLE_DHCP="true"
# DHCP IP address range start (only used if ENABLE_DHCP=true)
DHCP_RANGE_START="192.168.4.50"
# DHCP IP address range end (only used if ENABLE_DHCP=true)
DHCP_RANGE_END="192.168.4.150"
# DHCP lease time (only used if ENABLE_DHCP=true)
DHCP_LEASE_TIME="12h"

# --- END CONFIGURATION ---

# --- SCRIPT LOGIC ---

echo "--- Starting DNS Redirect Setup ---"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)."
   exit 1
fi

# --- Step 1: Configure NetworkManager Hotspot with Password ---
echo "[Step 1] Disconnecting device ${PI_INTERFACE} if active..."
nmcli device disconnect "${PI_INTERFACE}" || echo "Device ${PI_INTERFACE} was not connected."
sleep 3 # Increased delay

# Define the desired SSID and Password
NEW_SSID="SVLFG"
# No password for open network

echo "[Step 1] Creating OPEN Wi-Fi hotspot with SSID '${NEW_SSID}' on device ${PI_INTERFACE}..."

# Remove any existing connection with this name
HOTSPOT_CON_NAME="Hotspot-${PI_INTERFACE}"
echo "Removing any existing connection '${HOTSPOT_CON_NAME}'..."
nmcli connection delete "${HOTSPOT_CON_NAME}" >/dev/null 2>&1 || true
# Also remove the fallback NM connection if it exists
nmcli connection delete "NM-Hotspot" >/dev/null 2>&1 || true

# Verify WiFi adapter supports AP mode
echo "Checking if adapter supports AP mode..."
if ! iw list | grep -q "* AP$"; then
    echo "WARNING: This adapter might not support AP mode. Check 'iw list' output."
    # Continue anyway in case iw reporting is incomplete
fi

# Install only the necessary packages
echo "Installing required packages..."
apt-get update
apt-get install -y hostapd dnsmasq iptables-persistent

# --- Prevent NetworkManager from managing the interface ---
echo "Configuring NetworkManager to ignore ${PI_INTERFACE}..."
NM_CONF_FILE="/etc/NetworkManager/conf.d/99-unmanaged-devices.conf"
mkdir -p /etc/NetworkManager/conf.d/
cat << EOF > "${NM_CONF_FILE}"
[keyfile]
unmanaged-devices=interface-name:${PI_INTERFACE}
EOF
echo "Reloading NetworkManager configuration..."
systemctl reload NetworkManager || echo "NetworkManager might not be running."
sleep 2

# Unmask and enable hostapd (fix common issue)
systemctl unmask hostapd 2>/dev/null || true

# Stop and disable any conflicting services
echo "Stopping and disabling potentially conflicting services (wpa_supplicant, hostapd)..."
systemctl stop hostapd 2>/dev/null || true
systemctl disable hostapd 2>/dev/null || true # Disable it initially, we start it manually
systemctl stop wpa_supplicant 2>/dev/null || true
systemctl disable wpa_supplicant 2>/dev/null || true # Crucial to prevent interference
killall hostapd 2>/dev/null || true
killall wpa_supplicant 2>/dev/null || true
sleep 2 # Increased delay

# More aggressively reset the WiFi interface
echo "Resetting WiFi interface ${PI_INTERFACE}..."
ip link set ${PI_INTERFACE} down
# Wait for interface to fully go down
sleep 3 # Increased delay
# Bring interface back up
ip link set ${PI_INTERFACE} up
sleep 3 # Increased delay

# Check for any RF blocks
echo "Checking for RF blocks..."
if command -v rfkill &> /dev/null; then
    rfkill list
    echo "Unblocking all WiFi devices..."
    rfkill unblock wifi
fi

# Try multiple configurations - create both versions then try them in sequence
# First, create a *very* basic hostapd configuration
echo "Creating minimal hostapd configuration..."
cat << EOF > /tmp/hostapd.conf
interface=${PI_INTERFACE}
driver=nl80211
ssid=${NEW_SSID}
hw_mode=g
channel=6
# Minimal required for open network
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=0
EOF

# Create a slightly more featured version as fallback
echo "Creating alternative hostapd configuration..."
cat << EOF > /tmp/hostapd_alt.conf
interface=${PI_INTERFACE}
driver=nl80211
ssid=${NEW_SSID}
hw_mode=g
channel=11 # Different channel
macaddr_acl=0
auth_algs=1 # Standard open auth
ignore_broadcast_ssid=0
wpa=0
# Add country code and WMM
country_code=DE
ieee80211d=1
wmm_enabled=1
beacon_int=100
EOF

# Try to ensure the adapter is in the right mode
echo "Making sure WiFi interface is in AP mode..."
iw dev ${PI_INTERFACE} set type __ap || echo "Could not set AP mode (might already be in AP mode)"

HOSTAPD_STARTED=false
# First attempt with minimal config
echo "Starting hostapd with minimal configuration..."
if hostapd -B /tmp/hostapd.conf > /tmp/hostapd.log 2>&1; then
    sleep 2 # Give it time to start
    if pgrep -x "hostapd" > /dev/null; then
        echo "Hostapd started successfully with minimal config."
        HOSTAPD_STARTED=true
    else
        echo "Hostapd process not found after starting with minimal config. Check /tmp/hostapd.log."
    fi
else
    echo "Minimal hostapd config failed to start. Check /tmp/hostapd.log."
fi

# Second attempt with alternative config if first failed
if [ "$HOSTAPD_STARTED" = false ]; then
    echo "Trying alternative hostapd configuration..."
    if hostapd -B /tmp/hostapd_alt.conf >> /tmp/hostapd.log 2>&1; then
        sleep 2 # Give it time to start
        if pgrep -x "hostapd" > /dev/null; then
            echo "Hostapd started successfully with alternative config."
            HOSTAPD_STARTED=true
        else
            echo "Hostapd process not found after starting with alternative config. Check /tmp/hostapd.log."
        fi
    else
        echo "Alternative hostapd config also failed to start. Check /tmp/hostapd.log."
    fi
fi

# Fallback to NetworkManager ONLY if hostapd failed completely
if [ "$HOSTAPD_STARTED" = false ]; then
    echo "All direct hostapd attempts failed. Re-enabling NetworkManager control for ${PI_INTERFACE} and trying NM hotspot..."

    # Remove the unmanaged device configuration
    rm -f "${NM_CONF_FILE}"
    echo "Reloading NetworkManager configuration..."
    systemctl reload NetworkManager || echo "NetworkManager might not be running."
    sleep 2
    # Ensure interface is managed again
    nmcli device set ${PI_INTERFACE} managed yes || echo "Failed to set device to managed."
    sleep 2

    # Try creating a hotspot through NetworkManager as fallback
    echo "Attempting to create hotspot via NetworkManager..."
    # Create a basic connection
    nmcli con add type wifi ifname ${PI_INTERFACE} con-name "NM-Hotspot" autoconnect yes ssid "${NEW_SSID}" || true
    # Configure it as an access point
    nmcli con modify "NM-Hotspot" 802-11-wireless.mode ap 802-11-wireless.band bg ipv4.method shared || true
    # Remove security
    nmcli con modify "NM-Hotspot" wifi-sec.key-mgmt none || true
    # Set higher power
    nmcli con modify "NM-Hotspot" 802-11-wireless.tx-power 100 || true
    # Try multiple channels
    for channel in 1 6 11; do
        echo "Trying NetworkManager with channel $channel..."
        nmcli con modify "NM-Hotspot" 802-11-wireless.channel $channel || true
        # Activate it
        if nmcli con up "NM-Hotspot"; then
            echo "NetworkManager hotspot activated successfully on channel $channel!"
            NM_CON_NAME="NM-Hotspot"
            HOSTAPD_STARTED=true # Mark as started via NM
            break
        fi
    done

    if [ "$HOSTAPD_STARTED" = false ]; then
        echo "CRITICAL: All hotspot creation methods failed. Network will not be visible."
        echo "Try rebooting and running this script again."
        echo "You may also need to check if your WiFi adapter supports AP mode."
        echo "Check hostapd log: /tmp/hostapd.log"
        echo "Check NetworkManager logs: journalctl -u NetworkManager"
    fi
fi

sleep 3

# Verify hostapd or NM hotspot is running
if ! pgrep hostapd > /dev/null && [ "$(nmcli -g GENERAL.STATE con show "NM-Hotspot" 2>/dev/null)" != "activated" ]; then
    echo "WARNING: Neither hostapd nor NetworkManager hotspot appears to be running!"
    echo "Detailed hostapd log:"
    cat /tmp/hostapd.log || echo "No hostapd log found."
    # No recovery attempt here as previous steps failed
fi

# Show informative messages
echo "==== WiFi AP Troubleshooting ===="
echo "If Android devices cannot see the network:"
echo "1. Verify the WiFi adapter supports AP mode: check 'iw list' output for 'AP' in 'Supported interface modes'"
echo "2. Try rebooting the Raspberry Pi after setup"
echo "3. Ensure Android WiFi scanning is enabled"
echo "4. Try moving closer to the Raspberry Pi"
echo "5. Check /tmp/hostapd.log for errors"
echo "==============================="

# Configure the interface with static IP only if AP started
if [ "$HOSTAPD_STARTED" = true ]; then
    echo "Setting static IP on ${PI_INTERFACE}..."
    ip addr flush dev ${PI_INTERFACE} 2>/dev/null || true
    ip addr add ${PI_STATIC_IP}/${PI_IP_PREFIX} dev ${PI_INTERFACE}
    ip link set ${PI_INTERFACE} up

    # Status check
    echo "Network interface status:"
    ip addr show ${PI_INTERFACE}
    iwconfig ${PI_INTERFACE} || true

    # Set NM_CON_NAME based on which method worked
    if pgrep hostapd > /dev/null; then
        NM_CON_NAME="hostapd-${PI_INTERFACE}" # Indicate hostapd is managing
    elif [ "$(nmcli -g GENERAL.STATE con show "NM-Hotspot" 2>/dev/null)" = "activated" ]; then
        NM_CON_NAME="NM-Hotspot" # Indicate NM is managing
    fi

    echo "[Step 1] WiFi hotspot '${NEW_SSID}' creation attempt finished."
    sleep 3 # Wait for network to potentially stabilize
else
    echo "[Step 1] WiFi hotspot creation FAILED. Skipping IP configuration."
fi

# --- Step 2: Install Required Packages ---
echo "[Step 2] Configuring iptables-persistent..."
# Pre-configure debconf to avoid interactive prompts for iptables-persistent
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections

# --- Step 3: Configure dnsmasq ---
if [ "$HOSTAPD_STARTED" = true ]; then
    echo "[Step 3] Configuring dnsmasq (/etc/dnsmasq.conf)..."
    DNSMASQ_CONF="/etc/dnsmasq.conf"
    DNSMASQ_CONF_BAK="${DNSMASQ_CONF}.$(date +%F-%H%M%S).bak"

    # Backup existing config
    if [ -f "$DNSMASQ_CONF" ]; then
        echo "Backing up existing ${DNSMASQ_CONF} to ${DNSMASQ_CONF_BAK}"
        cp "$DNSMASQ_CONF" "$DNSMASQ_CONF_BAK"
    fi

    # Create the new dnsmasq configuration file
    # Overwrites existing file!
    cat << EOF > "$DNSMASQ_CONF"
# Configuration for dnsmasq generated by script
# Interface to listen on
interface=${PI_INTERFACE}
# Bind to only specified interface
bind-interfaces
# --- DNS settings for local network ---
# Standard options
domain-needed
bogus-priv
# Use upstream DNS servers for general lookups
server=${PI_DNS_SERVERS//,/$'\nserver='}
# --- Intercept Connectivity Checks ---
# Redirect specific connectivity check domains to the Pi itself
# This helps suppress "no internet" warnings on some devices
address=/connectivitycheck.gstatic.com/${PI_STATIC_IP}
address=/clients3.google.com/${PI_STATIC_IP}
address=/captive.apple.com/${PI_STATIC_IP}
address=/www.msftconnecttest.com/${PI_STATIC_IP}
address=/www.msftncsi.com/${PI_STATIC_IP}
# Optionally increase cache size
# cache-size=1000
EOF

    # Add DHCP configuration if enabled
    if [ "$ENABLE_DHCP" = "true" ]; then
        echo "[Step 3] Adding DHCP configuration to dnsmasq..."
        # Derive subnet mask from prefix (basic implementation for /24) - Improve if other prefixes needed
        SUBNET_MASK="255.255.255.0"
        if [ "$PI_IP_PREFIX" != "24" ]; then
          echo "Warning: Script currently assumes /24 prefix for DHCP subnet mask. Adjust manually if needed."
          # Add more complex prefix-to-mask logic here if necessary
        fi
        cat << EOF >> "$DNSMASQ_CONF"
# --- DHCP Settings ---
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${SUBNET_MASK},${DHCP_LEASE_TIME}
dhcp-option=option:router,${PI_STATIC_IP}
dhcp-option=option:dns-server,${PI_STATIC_IP}
# Optional: Set local domain
# domain=lan
EOF
    else
        echo "[Step 3] DHCP server disabled in configuration."
    fi

    echo "[Step 3] dnsmasq configuration written to ${DNSMASQ_CONF}"
else
    echo "[Step 3] Skipping dnsmasq configuration as hotspot failed."
fi

# --- Step 4: Stop Conflicting Services & Restart dnsmasq ---
if [ "$HOSTAPD_STARTED" = true ]; then
    echo "[Step 4] Stopping systemd-resolved (if active)..."
    if systemctl is-active --quiet systemd-resolved; then
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
        echo "systemd-resolved stopped and disabled."
    else
        echo "systemd-resolved was not active."
    fi

    # Optional: Force update /etc/resolv.conf for the Pi itself
    # echo "nameserver ${PI_DNS_SERVERS//,/$'\n'}" > /etc/resolv.conf # More robust way needed potentially

    echo "[Step 4] Restarting and enabling dnsmasq service..."
    systemctl restart dnsmasq
    systemctl enable dnsmasq
    echo "[Step 4] dnsmasq service restarted and enabled."
    sleep 2 # Wait for service
else
    echo "[Step 4] Skipping dnsmasq restart as hotspot failed."
fi

# --- Step 5: Configure iptables Rules ---
if [ "$HOSTAPD_STARTED" = true ]; then
    echo "[Step 5] Clearing previous NAT PREROUTING rules..."
    # Flush existing PREROUTING rules first to avoid duplicates
    iptables -t nat -F PREROUTING || echo "Warning: Failed to flush PREROUTING chain."
    # --- Add Redirect Rules ---
    # Redirect HTTP/S traffic destined for the Pi (due to DNS interception)
    # or any other address to the local application ports.
    echo "Adding iptables rule for HTTP (port 80) -> port ${TARGET_PORT}..."
    iptables -t nat -A PREROUTING -i ${PI_INTERFACE} -p tcp --dport 80 -j REDIRECT --to-port ${TARGET_PORT}
    echo "Adding iptables rule for HTTPS (port 443) -> port 3443..."
    iptables -t nat -A PREROUTING -i ${PI_INTERFACE} -p tcp --dport 443 -j REDIRECT --to-port 3443
    echo "[Step 5] iptables redirect rules configured."
else
    echo "[Step 5] Skipping iptables configuration as hotspot failed."
fi

# --- Step 6: Make iptables Rules Persistent ---
if [ "$HOSTAPD_STARTED" = true ]; then
    echo "[Step 6] Saving iptables rules..."
    netfilter-persistent save
else
    echo "[Step 6] Skipping iptables save as hotspot failed."
fi

# --- Step 7: Fix dnsmasq Startup Timing Issues ---
# This part should still be configured regardless, as it might help on reboot
echo "[Step 7] Fixing dnsmasq startup timing issues..."
# Create NetworkManager dispatcher script to restart dnsmasq when wlan1 comes up
echo "Creating NetworkManager dispatcher script..."
mkdir -p /etc/NetworkManager/dispatcher.d/
cat << EOF > /etc/NetworkManager/dispatcher.d/99-restart-dnsmasq
#!/bin/bash
INTERFACE=\$1
STATUS=\$2

# Only restart dnsmasq when wlan1 comes up
if [ "\$INTERFACE" = "${PI_INTERFACE}" ] && [ "\$STATUS" = "up" ]; then
    systemctl restart dnsmasq
fi
EOF

# Make the script executable
chmod +x /etc/NetworkManager/dispatcher.d/99-restart-dnsmasq

# Also modify dnsmasq.service to wait for network
echo "Modifying dnsmasq service to wait for network..."
mkdir -p /etc/systemd/system/dnsmasq.service.d/
cat << EOF > /etc/systemd/system/dnsmasq.service.d/override.conf
[Unit]
Wants=network-online.target
After=network-online.target NetworkManager.service

[Service]
ExecStartPre=/bin/sleep 10
EOF

# Reload systemd to apply changes
systemctl daemon-reload

# --- Step 8: Generate SSL certificates for HTTPS ---
# This can also run regardless
echo "[Step 8] Generating self-signed SSL certificates..."
CERT_DIR="certificates"
if [ ! -d "$CERT_DIR" ]; then
    echo "Creating certificates directory..."
    mkdir -p "$CERT_DIR"
fi

if [ -f "$CERT_DIR/key.pem" ] && [ -f "$CERT_DIR/cert.pem" ]; then
    echo "SSL certificates already exist. Skipping generation."
else
    echo "Generating new self-signed certificates valid for 365 days..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$CERT_DIR/key.pem" \
        -out "$CERT_DIR/cert.pem" \
        -subj "/CN=Video Server/O=SVLFG/C=DE" \
        -addext "subjectAltName = IP:${PI_STATIC_IP}"
    chmod 600 "$CERT_DIR/key.pem" "$CERT_DIR/cert.pem"
    echo "SSL certificates generated successfully."
fi

# After generating certificates
chown "${SUDO_USER:-$USER}":"${SUDO_USER:-$USER}" "$CERT_DIR/key.pem" "$CERT_DIR/cert.pem"
chmod 644 "$CERT_DIR/cert.pem"  # Everyone can read the certificate
chmod 600 "$CERT_DIR/key.pem"   # Only owner can read the private key

# --- Step 9: Completion ---
echo ""
echo "--- Setup Finished ---"
echo ""
echo "Summary:"
if [ "$HOSTAPD_STARTED" = true ]; then
    echo "* WiFi Hotspot Status: STARTED (using ${NM_CON_NAME})"
    echo "* Static IP ${PI_STATIC_IP}/${PI_IP_PREFIX} configured on interface ${PI_INTERFACE}."
    echo "* dnsmasq configured for DHCP (if enabled) and DNS."
    echo "*   - Standard DNS uses upstream servers: ${PI_DNS_SERVERS}"
    echo "*   - Connectivity check domains redirected to ${PI_STATIC_IP} to potentially reduce 'no internet' warnings."
    if [ "$ENABLE_DHCP" = "true" ]; then
        echo "* dnsmasq DHCP server enabled for range ${DHCP_RANGE_START}-${DHCP_RANGE_END}."
    fi
    echo "* iptables rules redirect HTTP(S) traffic (ports 80/443) to local ports ${TARGET_PORT}/3443."
    echo "* iptables rules should be persistent across reboots."
else
    echo "* WiFi Hotspot Status: FAILED TO START"
    echo "* Static IP configuration SKIPPED."
    echo "* dnsmasq configuration SKIPPED."
    echo "* iptables configuration SKIPPED."
    echo "* Please check logs: /tmp/hostapd.log and journalctl -u NetworkManager"
fi
echo "* Added fixes for dnsmasq startup timing issues (NetworkManager dispatcher + service delay)."
echo ""
echo "Next Steps:"
if [ "$HOSTAPD_STARTED" = true ]; then
    echo "1.  Ensure your web application is running on the Pi listening on port ${TARGET_PORT} (HTTP) and 3443 (HTTPS)."
    echo "    -> IMPORTANT: To fully suppress 'no internet' warnings, your app should respond with HTTP 204 (No Content)"
    echo "       to requests for paths like '/generate_204', '/connecttest.txt', '/ncsi.txt', or requests to the connectivity domains."
    echo "2.  Connect client devices to the '${NEW_SSID}' network."
    echo "3.  Clients should get DNS/IP automatically (if DHCP enabled)."
    echo "4.  Test access to your local application from a client device."
    echo "5.  A reboot (sudo reboot) is recommended to verify all changes work properly."
else
    echo "1.  Troubleshoot the hotspot failure based on the logs provided."
    echo "2.  Verify WiFi adapter compatibility and driver status."
    echo "3.  Consider trying a different WiFi adapter."
fi
echo ""
exit 0 # Exit cleanly even on failure, summary indicates status