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

# --- Configure NetworkManager to ignore interface IF hostapd method works ---
NM_CONF_FILE="/etc/NetworkManager/conf.d/99-unmanaged-devices.conf"
mkdir -p /etc/NetworkManager/conf.d/
configure_nm_unmanaged() {
    echo "Configuring NetworkManager to ignore ${PI_INTERFACE}..."
    cat << EOF > "${NM_CONF_FILE}"
[keyfile]
unmanaged-devices=interface-name:${PI_INTERFACE}
EOF
    echo "Reloading NetworkManager configuration..."
    systemctl reload NetworkManager || echo "NetworkManager might not be running."
    # Ensure system dnsmasq is enabled when hostapd service manages the AP
    echo "Ensuring system dnsmasq service is enabled (hostapd mode)..."
    systemctl enable dnsmasq || echo "Failed to enable dnsmasq."
    sleep 2
}
configure_nm_managed() {
    echo "Ensuring NetworkManager manages ${PI_INTERFACE}..."
    if [ -f "${NM_CONF_FILE}" ]; then
        rm -f "${NM_CONF_FILE}"
        echo "Reloading NetworkManager configuration..."
        systemctl reload NetworkManager || echo "NetworkManager might not be running."
        sleep 2
    fi
    # Ensure interface is managed again
    nmcli device set ${PI_INTERFACE} managed yes || echo "Failed to set device ${PI_INTERFACE} to managed."
    # Disable system dnsmasq when NetworkManager shared mode manages the AP/DHCP
    echo "Disabling system dnsmasq service (NetworkManager mode)..."
    systemctl disable dnsmasq || echo "Failed to disable dnsmasq."
    systemctl stop dnsmasq || echo "dnsmasq was not running."
    sleep 2
}

# Unmask and stop hostapd (fix common issue, ensure clean state)
systemctl unmask hostapd 2>/dev/null || true
systemctl stop hostapd 2>/dev/null || true
# We will enable it later *if* this method succeeds

# Stop and disable other potentially conflicting services
echo "Stopping and disabling potentially conflicting services (wpa_supplicant)..."
systemctl stop wpa_supplicant 2>/dev/null || true
systemctl disable wpa_supplicant 2>/dev/null || true # Crucial to prevent interference
killall hostapd 2>/dev/null || true # Kill any lingering manual processes
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
HOSTAPD_METHOD="" # Will be 'service' or 'nmcli'
SUCCESSFUL_HOSTAPD_CONF=""

# First attempt with minimal config
echo "Starting hostapd with minimal configuration..."
if hostapd /tmp/hostapd.conf > /tmp/hostapd.log 2>&1 &
then
    sleep 4 # Give it more time to start
    if pgrep -x "hostapd" > /dev/null; then
        echo "Hostapd started successfully with minimal config (temporarily)."
        SUCCESSFUL_HOSTAPD_CONF="/tmp/hostapd.conf"
        # Stop the temporary process
        echo "Stopping temporary hostapd process..."
        pkill hostapd
        sleep 2
    else
        echo "Hostapd process not found after starting with minimal config. Check /tmp/hostapd.log."
        # Ensure it's really stopped
        pkill hostapd 2>/dev/null || true
    fi
else
    echo "Minimal hostapd config failed to start. Check /tmp/hostapd.log."
    pkill hostapd 2>/dev/null || true
fi

# Second attempt with alternative config if first failed
if [ -z "$SUCCESSFUL_HOSTAPD_CONF" ]; then
    echo "Trying alternative hostapd configuration..."
    if hostapd /tmp/hostapd_alt.conf >> /tmp/hostapd.log 2>&1 &
    then
        sleep 4 # Give it more time to start
        if pgrep -x "hostapd" > /dev/null; then
            echo "Hostapd started successfully with alternative config (temporarily)."
            SUCCESSFUL_HOSTAPD_CONF="/tmp/hostapd_alt.conf"
            # Stop the temporary process
            echo "Stopping temporary hostapd process..."
            pkill hostapd
            sleep 2
        else
            echo "Hostapd process not found after starting with alternative config. Check /tmp/hostapd.log."
            pkill hostapd 2>/dev/null || true
        fi
    else
        echo "Alternative hostapd config also failed to start. Check /tmp/hostapd.log."
        pkill hostapd 2>/dev/null || true
    fi
fi

# --- Configure Persistence Based on Success ---

# If direct hostapd method worked, configure the service
if [ -n "$SUCCESSFUL_HOSTAPD_CONF" ]; then
    echo "Direct hostapd method successful. Configuring hostapd service for persistence..."
    HOSTAPD_METHOD="service"

    # 1. Copy the successful config to the default location
    echo "Copying ${SUCCESSFUL_HOSTAPD_CONF} to /etc/hostapd/hostapd.conf..."
    cp "${SUCCESSFUL_HOSTAPD_CONF}" /etc/hostapd/hostapd.conf
    chmod 600 /etc/hostapd/hostapd.conf # Secure permissions

    # 2. Configure /etc/default/hostapd to use the config file
    echo "Configuring /etc/default/hostapd..."
    # Remove existing DAEMON_CONF line if present
    sed -i '/^DAEMON_CONF=/d' /etc/default/hostapd
    # Add the new line
    echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd

    # 3. Ensure NetworkManager ignores the interface AND system dnsmasq is enabled
    configure_nm_unmanaged

    # 4. Enable and start the hostapd service
    echo "Enabling and starting hostapd service..."
    systemctl enable hostapd
    systemctl restart hostapd # Use restart to ensure it picks up new config
    sleep 5 # Give service time to start

    # 5. Verify service started
    if systemctl is-active --quiet hostapd; then
        echo "hostapd service started successfully."
        HOSTAPD_STARTED=true
        NM_CON_NAME="hostapd-service" # Indicate service is managing
    else
        echo "ERROR: hostapd service failed to start. Check 'systemctl status hostapd' and 'journalctl -u hostapd'."
        HOSTAPD_STARTED=false
    fi

# Fallback to NetworkManager ONLY if hostapd failed completely
else
    echo "Direct hostapd attempts failed. Trying NetworkManager hotspot fallback..."
    HOSTAPD_METHOD="nmcli"

    # Ensure NetworkManager is managing the interface AND system dnsmasq is disabled
    configure_nm_managed

    # Ensure hostapd service is disabled if we are using NM
    echo "Disabling hostapd service (using NetworkManager fallback)..."
    systemctl disable hostapd 2>/dev/null || true
    systemctl stop hostapd 2>/dev/null || true

    # Try creating a hotspot through NetworkManager as fallback
    echo "Attempting to create hotspot via NetworkManager..."
    # Create a basic connection
    nmcli con add type wifi ifname ${PI_INTERFACE} con-name "NM-Hotspot" autoconnect yes ssid "${NEW_SSID}" || true
    # Configure it as an access point with SHARED IP (NM handles DHCP/DNS)
    nmcli con modify "NM-Hotspot" 802-11-wireless.mode ap 802-11-wireless.band bg ipv4.method shared ipv4.addresses "${PI_STATIC_IP}/${PI_IP_PREFIX}" ipv4.gateway "${PI_STATIC_IP}" || true
    # Remove security
    nmcli con modify "NM-Hotspot" wifi-sec.key-mgmt none || true
    # Set higher power
    nmcli con modify "NM-Hotspot" 802-11-wireless.tx-power 100 || true
    # Try multiple channels
    NM_HOTSPOT_UP=false
    for channel in 1 6 11; do
        echo "Trying NetworkManager with channel $channel..."
        nmcli con modify "NM-Hotspot" 802-11-wireless.channel $channel || true
        # Activate it
        if nmcli con up "NM-Hotspot"; then
            echo "NetworkManager hotspot activated successfully on channel $channel!"
            NM_CON_NAME="NM-Hotspot" # Use the actual NM connection name
            HOSTAPD_STARTED=true # Mark as started via NM
            NM_HOTSPOT_UP=true
            # Ensure NetworkManager service is enabled for persistence
            systemctl enable NetworkManager
            break
        else
            echo "Failed to bring up NM-Hotspot on channel $channel."
        fi
    done

    if [ "$NM_HOTSPOT_UP" = false ]; then
        echo "CRITICAL: All hotspot creation methods failed (direct hostapd and NetworkManager)."
        echo "Network will not be visible."
        echo "Try rebooting and running this script again."
        echo "You may also need to check if your WiFi adapter supports AP mode ('iw list')."
        echo "Check hostapd log: /tmp/hostapd.log"
        echo "Check NetworkManager logs: journalctl -u NetworkManager"
        echo "Check hostapd service status: systemctl status hostapd"
        HOSTAPD_STARTED=false
    fi
fi

sleep 3

# Verify hotspot is running via the chosen method
if [ "$HOSTAPD_STARTED" = true ]; then
    echo "Hotspot started successfully using method: ${HOSTAPD_METHOD}"
    if [ "$HOSTAPD_METHOD" = "service" ]; then
        if ! systemctl is-active --quiet hostapd; then
             echo "WARNING: hostapd service method was chosen, but the service is not active!"
             HOSTAPD_STARTED=false # Re-evaluate status
        fi
    elif [ "$HOSTAPD_METHOD" = "nmcli" ]; then
        if [ "$(nmcli -g GENERAL.STATE con show "${NM_CON_NAME}" 2>/dev/null)" != "activated" ]; then
             echo "WARNING: NetworkManager method was chosen, but connection '${NM_CON_NAME}' is not activated!"
             HOSTAPD_STARTED=false # Re-evaluate status
        fi
    fi
else
     echo "WARNING: Hotspot failed to start using any method."
     echo "Detailed hostapd log:"
     cat /tmp/hostapd.log || echo "No hostapd log found."
fi

# Configure the interface with static IP only if AP started AND hostapd service method is used
if [ "$HOSTAPD_STARTED" = true ]; then
    if [ "$HOSTAPD_METHOD" = "service" ]; then
        echo "Setting static IP on ${PI_INTERFACE} (hostapd service mode)..."
        ip addr flush dev ${PI_INTERFACE} 2>/dev/null || true
        ip addr add ${PI_STATIC_IP}/${PI_IP_PREFIX} dev ${PI_INTERFACE}
        ip link set ${PI_INTERFACE} up
        sleep 2 # Give IP time to settle
    else
         echo "Skipping manual static IP configuration (${HOSTAPD_METHOD} mode handles it)."
         # NM in shared mode should configure the IP based on ipv4.addresses setting above
    fi

    # Status check
    echo "Network interface status:"
    ip addr show ${PI_INTERFACE}
    iwconfig ${PI_INTERFACE} || true

    echo "[Step 1] WiFi hotspot '${NEW_SSID}' setup finished using method '${HOSTAPD_METHOD}'."
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
# Only configure system dnsmasq if hostapd service method is used
if [ "$HOSTAPD_STARTED" = true ] && [ "$HOSTAPD_METHOD" = "service" ]; then
    echo "[Step 3] Configuring system dnsmasq (/etc/dnsmasq.conf) for hostapd mode..."
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
# Bind to only specified interface(s)
bind-interfaces
# Explicitly listen on the static IP for this interface
listen-address=${PI_STATIC_IP} 
# --- DNS settings for local network ---
# Standard options
domain-needed
bogus-priv
# Use upstream DNS servers for general lookups
server=${PI_DNS_SERVERS//,/$'\nserver='}
# --- Intercept Connectivity Checks ---
# Redirect specific connectivity check domains to the Pi itself
# This helps suppress "no internet" / captive portal warnings on most devices
# Google / Android
address=/connectivitycheck.gstatic.com/${PI_STATIC_IP}
address=/clients3.google.com/${PI_STATIC_IP}
address=/clients.google.com/${PI_STATIC_IP}
address=/google.com/generate_204/${PI_STATIC_IP} # Specific path sometimes used
# Apple / iOS / macOS
address=/captive.apple.com/${PI_STATIC_IP}
address=/www.apple.com/${PI_STATIC_IP}
address=/www.appleiphonecell.com/${PI_STATIC_IP}
address=/airport.us/${PI_STATIC_IP}
address=/ibook.info/${PI_STATIC_IP}
# Microsoft / Windows
address=/www.msftconnecttest.com/${PI_STATIC_IP}
address=/www.msftncsi.com/${PI_STATIC_IP}
# Amazon / Kindle
address=/spectrum.s3.amazonaws.com/${PI_STATIC_IP}
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
elif [ "$HOSTAPD_STARTED" = true ] && [ "$HOSTAPD_METHOD" = "nmcli" ]; then
    echo "[Step 3] Skipping system dnsmasq configuration (NetworkManager shared mode handles DHCP/DNS)."
else
    echo "[Step 3] Skipping dnsmasq configuration as hotspot failed."
fi

# --- Step 4: Stop Conflicting Services & Restart dnsmasq ---
# Only manage system dnsmasq if hostapd service method is used
if [ "$HOSTAPD_STARTED" = true ] && [ "$HOSTAPD_METHOD" = "service" ]; then
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

    echo "[Step 4] Restarting and enabling system dnsmasq service (hostapd mode)..."
    systemctl restart dnsmasq
    # Enable is handled in configure_nm_unmanaged now
    # systemctl enable dnsmasq
    echo "[Step 4] dnsmasq service restarted."
    sleep 3 # Wait longer for service
    echo "[Step 4] Checking dnsmasq status..."
    systemctl status dnsmasq --no-pager || echo "Warning: dnsmasq status check failed."
    echo "[Step 4] Checking dnsmasq listeners (should be on ${PI_STATIC_IP}:53)..."
    ss -tulnp | grep ':53 ' | grep dnsmasq || echo "Warning: dnsmasq does not seem to be listening on port 53."
    echo "[Step 4] Checking dnsmasq DHCP listeners (should be on 0.0.0.0:67)..."
    ss -tulnp | grep ':67 ' | grep dnsmasq || echo "Warning: dnsmasq does not seem to be listening on port 67 for DHCP."

elif [ "$HOSTAPD_STARTED" = true ] && [ "$HOSTAPD_METHOD" = "nmcli" ]; then
     echo "[Step 4] Skipping system dnsmasq restart (NetworkManager handles DHCP/DNS)."
     # NM might start its own dnsmasq instance, check for that
     echo "[Step 4] Checking for any dnsmasq listeners (NM might run one)..."
     ss -tulnp | grep ':53 ' | grep dnsmasq || echo "Info: No dnsmasq listening on port 53 found."
     ss -tulnp | grep ':67 ' | grep dnsmasq || echo "Info: No dnsmasq listening on port 67 found (NM might use internal DHCP)."
else
    echo "[Step 4] Skipping dnsmasq restart as hotspot failed."
fi

# --- Step 5: Configure iptables Rules ---
if [ "$HOSTAPD_STARTED" = true ]; then
    echo "[Step 5] Clearing previous NAT and INPUT rules for ${PI_INTERFACE}..."
    # Flush existing PREROUTING rules first to avoid duplicates
    iptables -t nat -F PREROUTING || echo "Warning: Failed to flush NAT PREROUTING chain."
    # Flush potentially relevant INPUT rules (be careful not to lock yourself out if using SSH over this interface)
    iptables -F INPUT || echo "Warning: Failed to flush INPUT chain. This might drop existing connections."
    # Optionally flush OUTPUT if the Pi itself should also be redirected (less common need)
    # iptables -t nat -F OUTPUT || echo "Warning: Failed to flush OUTPUT chain."

    # --- Add INPUT Rules (Allow DHCP, DNS, HTTP/S) ---
    echo "Adding iptables rule to allow established connections..."
    iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    echo "Adding iptables rule to allow loopback traffic..."
    iptables -A INPUT -i lo -j ACCEPT
    echo "Adding iptables rule for incoming DHCP requests (UDP 67/68) on ${PI_INTERFACE}..."
    iptables -A INPUT -i ${PI_INTERFACE} -p udp --dport 67 -j ACCEPT
    iptables -A INPUT -i ${PI_INTERFACE} -p udp --dport 68 -j ACCEPT
    echo "Adding iptables rule for incoming DNS requests (UDP/TCP 53) on ${PI_INTERFACE}..."
    iptables -A INPUT -i ${PI_INTERFACE} -p udp --dport 53 -j ACCEPT
    iptables -A INPUT -i ${PI_INTERFACE} -p tcp --dport 53 -j ACCEPT
    echo "Adding iptables rule for incoming HTTP requests (TCP ${TARGET_PORT}) on ${PI_INTERFACE}..."
    iptables -A INPUT -i ${PI_INTERFACE} -p tcp --dport ${TARGET_PORT} -j ACCEPT
    echo "Adding iptables rule for incoming HTTPS requests (TCP 3443) on ${PI_INTERFACE}..."
    iptables -A INPUT -i ${PI_INTERFACE} -p tcp --dport 3443 -j ACCEPT

    # --- Add Redirect Rules (NAT Table) ---
    echo "Adding iptables rule for HTTP (port 80) -> port ${TARGET_PORT}..."
    iptables -t nat -A PREROUTING -i ${PI_INTERFACE} -p tcp --dport 80 -j REDIRECT --to-port ${TARGET_PORT}
    echo "Adding iptables rule for HTTPS (port 443) -> port 3443..."
    iptables -t nat -A PREROUTING -i ${PI_INTERFACE} -p tcp --dport 443 -j REDIRECT --to-port 3443

    echo "[Step 5] iptables rules configured."
    echo "[Step 5] Current INPUT rules:"
    iptables -L INPUT -nv || echo "Warning: Failed to list iptables INPUT rules."
    echo "[Step 5] Current NAT PREROUTING rules:"
    iptables -t nat -L PREROUTING -nv || echo "Warning: Failed to list iptables NAT rules."
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
# This helps if NetworkManager is managing the interface
echo "Creating NetworkManager dispatcher script..."
mkdir -p /etc/NetworkManager/dispatcher.d/
cat << EOF > /etc/NetworkManager/dispatcher.d/99-restart-dnsmasq
#!/bin/bash
INTERFACE=\$1
STATUS=\$2

# Only restart dnsmasq when the specific interface comes up
if [ "\$INTERFACE" = "${PI_INTERFACE}" ] && [ "\$STATUS" = "up" ]; then
    # Add a small delay before restarting dnsmasq
    sleep 5
    systemctl restart dnsmasq
fi
EOF

# Make the script executable
chmod +x /etc/NetworkManager/dispatcher.d/99-restart-dnsmasq

# Also modify dnsmasq.service to wait for network and potentially hostapd
echo "Modifying dnsmasq service to wait for network services and bind to interface..."
mkdir -p /etc/systemd/system/dnsmasq.service.d/
# Use printf to handle the interface name correctly in the unit file content
printf "[Unit]\n# Wait for general network readiness and specific services\n# Bind dnsmasq lifecycle to the specific network device\nWants=network-online.target\nAfter=network-online.target NetworkManager.service hostapd.service\nBindsTo=sys-subsystem-net-devices-%s.device\nAfter=sys-subsystem-net-devices-%s.device\n\n[Service]\n# Add a delay before starting dnsmasq\nExecStartPre=/bin/sleep 10\n" "${PI_INTERFACE}" "${PI_INTERFACE}" > /etc/systemd/system/dnsmasq.service.d/override.conf

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
    echo "* WiFi Hotspot Status: STARTED (using ${HOSTAPD_METHOD})"
    echo "* Persistence: Configured to start automatically on reboot."
    if [ "$HOSTAPD_METHOD" = "service" ]; then
        echo "* Static IP ${PI_STATIC_IP}/${PI_IP_PREFIX} configured manually on interface ${PI_INTERFACE}."
        echo "* System dnsmasq configured for DHCP (if enabled) and DNS."
        echo "*   - Standard DNS uses upstream servers: ${PI_DNS_SERVERS}"
        echo "*   - Connectivity check domains redirected to ${PI_STATIC_IP}."
        if [ "$ENABLE_DHCP" = "true" ]; then
            echo "*   - System dnsmasq DHCP server enabled for range ${DHCP_RANGE_START}-${DHCP_RANGE_END}."
        fi
    else # nmcli method
        echo "* Static IP ${PI_STATIC_IP}/${PI_IP_PREFIX} configured via NetworkManager shared mode."
        echo "* NetworkManager internal mechanisms handle DHCP/DNS for clients."
        echo "* System dnsmasq service is disabled."
    fi
    echo "* iptables rules allow DHCP/DNS/HTTP/HTTPS and redirect HTTP(S) traffic (ports 80/443) to local ports ${TARGET_PORT}/3443."
    echo "* iptables rules should be persistent across reboots."
else
    echo "* WiFi Hotspot Status: FAILED TO START"
    echo "* Persistence: Cannot be guaranteed as startup failed."
    echo "* Static IP configuration SKIPPED."
    echo "* dnsmasq configuration SKIPPED."
    echo "* iptables configuration SKIPPED."
    echo "* Please check logs: /tmp/hostapd.log and journalctl -u NetworkManager"
fi
echo "* Added fixes for dnsmasq startup timing issues (NetworkManager dispatcher + service delay)."
echo ""
echo "Next Steps:"
if [ "$HOSTAPD_STARTED" = true ]; then
    echo "1.  Ensure your Node.js web application is running on the Pi (check logs for errors):"
    echo "    - Listening on port ${TARGET_PORT} (HTTP) and 3443 (HTTPS)."
    echo "    - Responding with HTTP 204 to connectivity check paths/domains (check Node.js logs for '/generate_204', etc.)."
    echo "2.  Connect client devices to the '${NEW_SSID}' network."
    echo "3.  Verify clients get an IP address in the ${DHCP_RANGE_START} - ${DHCP_RANGE_END} range."
    echo "4.  Test access to your local application from a client device (e.g., http://${PI_STATIC_IP}:${TARGET_PORT})."
    echo "5.  A reboot (sudo reboot) is recommended to verify all changes work properly."
else
    echo "1.  Troubleshoot the hotspot failure based on the logs provided."
    echo "2.  Verify WiFi adapter compatibility and driver status."
    echo "3.  Consider trying a different WiFi adapter."
fi
echo ""
exit 0 # Exit cleanly even on failure, summary indicates status