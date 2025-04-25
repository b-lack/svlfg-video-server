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
sleep 2

# Define the desired SSID and Password
NEW_SSID="SVLFG - Broadcast"
NEW_PASSWORD="svlfg123" # Set your desired password here
echo "[Step 1] Creating OPEN Wi-Fi hotspot with SSID '${NEW_SSID}' on device ${PI_INTERFACE}..."

# Use the dedicated hotspot command with the desired password.
# This creates an AP with WPA2-PSK security by default.
nmcli device wifi hotspot ifname "${PI_INTERFACE}" ssid "${NEW_SSID}" || { echo "Error creating open hotspot."; exit 1; }
sleep 5 # Give NM time to create and activate the profile

# Dynamically find the connection name associated with the active hotspot on the interface
echo "[Step 1] Finding the active connection profile name for ${PI_INTERFACE}..."
ACTIVE_CON_UUID=$(nmcli -g GENERAL.CONNECTION device show "${PI_INTERFACE}")
if [ -z "$ACTIVE_CON_UUID" ]; then
    echo "Error: Could not find an active connection UUID for ${PI_INTERFACE} after creating hotspot."
    exit 1
fi
NM_CON_NAME=$(nmcli -g connection.id connection show "${ACTIVE_CON_UUID}")
if [ -z "$NM_CON_NAME" ]; then
    echo "Error: Could not find connection name for UUID ${ACTIVE_CON_UUID}."
    exit 1
fi
echo "[Step 1] Found active connection name: '${NM_CON_NAME}'"

echo "[Step 1] Modifying hotspot connection '${NM_CON_NAME}' for static IP..."

# Now modify the connection NM created ONLY for static IP settings.
# We KEEP the security settings created by the 'hotspot' command.
nmcli connection modify "${NM_CON_NAME}" \
    ipv4.method manual \
    ipv4.addresses "${PI_STATIC_IP}/${PI_IP_PREFIX}" \
    ipv4.gateway "${PI_GATEWAY}" \
    ipv4.dns "${PI_DNS_SERVERS}" \
    ipv4.ignore-auto-dns yes \
    ipv4.ignore-auto-routes yes \
    ipv6.method ignore || { echo "Error modifying IP settings for the created hotspot connection '${NM_CON_NAME}'."; exit 1; }

echo "[Step 1] Reloading and activating modified hotspot connection '${NM_CON_NAME}'..."
# Bring it down first to ensure settings apply cleanly
nmcli connection down "${NM_CON_NAME}" || echo "Warning: Connection '${NM_CON_NAME}' might already be down."
sleep 2
nmcli connection up "${NM_CON_NAME}" || { echo "Error bringing modified hotspot connection '${NM_CON_NAME}' up."; exit 1; }

echo "[Step 1] NetworkManager hotspot '${NM_CON_NAME}' created/configured with password and activated."
sleep 3 # Wait for network to potentially stabilize

# --- Step 2: Install Required Packages ---
echo "[Step 2] Installing dnsmasq and iptables-persistent..."
# Pre-configure debconf to avoid interactive prompts for iptables-persistent
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections # Usually disable v6 saving unless needed

apt-get update
apt-get install -y dnsmasq iptables-persistent

# --- Step 3: Configure dnsmasq ---
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
# Resolve all domains to this Pi
# address=/#/${PI_STATIC_IP} # <--- This line is already here
# Standard options
domain-needed
bogus-priv
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

# --- Step 4: Stop Conflicting Services & Restart dnsmasq ---
echo "[Step 4] Stopping systemd-resolved (if active)..."
if systemctl is-active --quiet systemd-resolved; then
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved
    echo "systemd-resolved stopped and disabled."
else
    echo "systemd-resolved was not active."
fi
# Optional: Force update /etc/resolv.conf for the Pi itself
# echo "nameserver ${PI_DNS_SERVERS//,/$'\n'nameserver }" > /etc/resolv.conf # More robust way needed potentially

echo "[Step 4] Restarting and enabling dnsmasq service..."
systemctl restart dnsmasq
systemctl enable dnsmasq
echo "[Step 4] dnsmasq service restarted and enabled."
sleep 2 # Wait for service

# --- Step 5: Configure iptables Rules ---
echo "[Step 5] Configuring iptables redirect rules (Ports 80,443 -> ${TARGET_PORT})..."

# Function to add an iptables rule for a specific port if it doesn't exist
echo "Adding iptables rule for HTTP (port 80) → port 3000..."
iptables -t nat -A PREROUTING -i ${PI_INTERFACE} -p tcp --dport 80 -j REDIRECT --to-port 3000

echo "Adding iptables rule for HTTPS (port 443) → port 3443..."
iptables -t nat -A PREROUTING -i ${PI_INTERFACE} -p tcp --dport 443 -j REDIRECT --to-port 3443

# Add rules for both HTTP (80) and HTTPS (443)
#add_redirect_rule 80
#add_redirect_rule 443

# --- Step 6: Make iptables Rules Persistent ---
echo "[Step 6] Saving iptables rules..."
# The package installation should have prompted for saving, but save again just in case.
netfilter-persistent save

# --- Step 7: Fix dnsmasq Startup Timing Issues ---
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

# After generating certificates
chown "${SUDO_USER:-$USER}":"${SUDO_USER:-$USER}" "$CERT_DIR/privkey.pem" "$CERT_DIR/fullchain.pem"
chmod 644 "$CERT_DIR/fullchain.pem"  # Everyone can read the certificate
chmod 600 "$CERT_DIR/privkey.pem"   # Only owner can read the private key


# --- Step 9: Completion ---
echo ""
echo "--- Setup Complete! ---"
echo ""
echo "Summary:"
echo "* Static IP ${PI_STATIC_IP}/${PI_IP_PREFIX} configured on interface ${PI_INTERFACE} (via NM connection '${NM_CON_NAME}')."
echo "* dnsmasq installed and configured to resolve all DNS to ${PI_STATIC_IP}."
if [ "$ENABLE_DHCP" = "true" ]; then
    echo "* dnsmasq DHCP server enabled for range ${DHCP_RANGE_START}-${DHCP_RANGE_END}."
fi
echo "* iptables rules added to redirect HTTP traffic (port 80) to port 3000 and HTTPS traffic (port 443) to port 3443."
echo "* iptables rules should be persistent across reboots."
echo "* Added fixes for dnsmasq startup timing issues (NetworkManager dispatcher + service delay)."
echo ""
echo "Next Steps:"
echo "1.  Ensure your web application is running on the Pi and listening on port ${TARGET_PORT}."
echo "2.  Connect client devices to the ${PI_INTERFACE} network."
echo "3.  Clients should get DNS/IP automatically (if DHCP enabled) or configure them manually to use ${PI_STATIC_IP} as DNS."
echo "4.  Test DNS resolution and HTTP access (e.g., http://example.com) from a client device."
echo "5.  A reboot (sudo reboot) is recommended to verify all changes work properly."
echo ""

exit 0