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
NEW_SSID="SVLFG"
# No password for open network

echo "[Step 1] Creating OPEN Wi-Fi hotspot with SSID '${NEW_SSID}' on device ${PI_INTERFACE}..."

# Remove any existing connection with this name
HOTSPOT_CON_NAME="Hotspot-${PI_INTERFACE}"
echo "Removing any existing connection '${HOTSPOT_CON_NAME}'..."
nmcli connection delete "${HOTSPOT_CON_NAME}" >/dev/null 2>&1 || true

# Install only the necessary packages
echo "Installing required packages..."
apt-get update
apt-get install -y hostapd dnsmasq iptables-persistent

# Stop and disable any conflicting services
echo "Stopping any existing WiFi services..."
systemctl stop hostapd 2>/dev/null || true
systemctl stop wpa_supplicant 2>/dev/null || true 
killall hostapd 2>/dev/null || true
killall wpa_supplicant 2>/dev/null || true
sleep 1

# Create a simple hostapd configuration
echo "Creating hostapd configuration..."
cat << EOF > /tmp/hostapd.conf
interface=${PI_INTERFACE}
driver=nl80211
ssid=${NEW_SSID}
hw_mode=g
channel=7
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
EOFarameters to help disable captive portal detection
wmm_enabled=1
# Configure the interface with static IP
echo "Setting static IP on ${PI_INTERFACE}..."
ip addr flush dev ${PI_INTERFACE} 2>/dev/null || true
ip addr add ${PI_STATIC_IP}/${PI_IP_PREFIX} dev ${PI_INTERFACE}
ip link set ${PI_INTERFACE} up
# Configure the interface with static IP
# Start hostapdtatic IP on ${PI_INTERFACE}..."
echo "Starting hostapd..."ERFACE} 2>/dev/null || true
hostapd -B /tmp/hostapd.conf${PI_IP_PREFIX} dev ${PI_INTERFACE}
sleep 2 set ${PI_INTERFACE} up

NM_CON_NAME="hostapd-${PI_INTERFACE}"
echo "[Step 1] WiFi hotspot '${NEW_SSID}' created successfully."
sleep 3 # Wait for network to potentially stabilize
sleep 2
# --- Step 2: Install Required Packages ---
echo "[Step 2] Installing dnsmasq and iptables-persistent..."
# Pre-configure debconf to avoid interactive prompts for iptables-persistent
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections # Usually disable v6 saving unless needed
# --- Step 2: Install Required Packages ---
apt-get update Installing dnsmasq and iptables-persistent..."
apt-get install -y dnsmasq iptables-persistentrompts for iptables-persistent
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
# --- Step 3: Configure dnsmasq ---ersistent/autosave_v6 boolean false | debconf-set-selections # Usually disable v6 saving unless needed
echo "[Step 3] Configuring dnsmasq (/etc/dnsmasq.conf)..."
DNSMASQ_CONF="/etc/dnsmasq.conf"
DNSMASQ_CONF_BAK="${DNSMASQ_CONF}.$(date +%F-%H%M%S).bak"

# Backup existing configdnsmasq ---
if [ -f "$DNSMASQ_CONF" ]; thenasq (/etc/dnsmasq.conf)..."
    echo "Backing up existing ${DNSMASQ_CONF} to ${DNSMASQ_CONF_BAK}"
    cp "$DNSMASQ_CONF" "$DNSMASQ_CONF_BAK"%F-%H%M%S).bak"
fi
# Backup existing config
# Create the new dnsmasq configuration file
# Overwrites existing file!ng ${DNSMASQ_CONF} to ${DNSMASQ_CONF_BAK}"
cat << EOF > "$DNSMASQ_CONF"MASQ_CONF_BAK"
# Configuration for dnsmasq generated by script
# Interface to listen on
interface=${PI_INTERFACE}configuration file
# Bind to only specified interface
bind-interfacesDNSMASQ_CONF"
# Resolve all domains to this Pirated by script
address=/#/${PI_STATIC_IP} # <--- This line is already here
# Standard optionsptive portal detection URLs - let them through to the internetERFACE}
domain-neededprevent captive portal notificationsy specified interface
bogus-privple.com/1.1.1.1faces
# Optionally increase cache size1
# cache-size=1000google.com/1.1.1.1TATIC_IP}
# Standard options# Standard options
EOFain-neededain-needed
bogus-privbogus-priv
# Add DHCP configuration if enabled
if [ "$ENABLE_DHCP" = "true" ]; then
    echo "[Step 3] Adding DHCP configuration to dnsmasq..."
    # Derive subnet mask from prefix (basic implementation for /24) - Improve if other prefixes needed
    SUBNET_MASK="255.255.255.0"
    if [ "$PI_IP_PREFIX" != "24" ]; then
      echo "Warning: Script currently assumes /24 prefix for DHCP subnet mask. Adjust manually if needed."
      # Add more complex prefix-to-mask logic here if necessary
    fiDerive subnet mask from prefix (basic implementation for /24) - Improve if other prefixes neededDerive subnet mask from prefix (basic implementation for /24) - Improve if other prefixes needed
    SUBNET_MASK="255.255.255.0"    SUBNET_MASK="255.255.255.0"
    cat << EOF >> "$DNSMASQ_CONF"]; then]; then
# --- DHCP Settings ---ript currently assumes /24 prefix for DHCP subnet mask. Adjust manually if needed."ript currently assumes /24 prefix for DHCP subnet mask. Adjust manually if needed."
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${SUBNET_MASK},${DHCP_LEASE_TIME}
dhcp-option=option:router,${PI_STATIC_IP}
dhcp-option=option:dns-server,${PI_STATIC_IP}
# Optional: Set local domainCONF"CONF"
# domain=lanettings ---ettings ---
EOFp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${SUBNET_MASK},${DHCP_LEASE_TIME}p-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${SUBNET_MASK},${DHCP_LEASE_TIME}
else-option=option:router,${PI_STATIC_IP}-option=option:router,${PI_STATIC_IP}
    echo "[Step 3] DHCP server disabled in configuration."
fiOptional: Set local domainOptional: Set local domain
# domain=lan# domain=lan
echo "[Step 3] dnsmasq configuration written to ${DNSMASQ_CONF}"
elseelse
# --- Step 4: Stop Conflicting Services & Restart dnsmasq ---
echo "[Step 4] Stopping systemd-resolved (if active)..."
if systemctl is-active --quiet systemd-resolved; then
    systemctl stop systemd-resolvedn written to ${DNSMASQ_CONF}"n written to ${DNSMASQ_CONF}"
    systemctl disable systemd-resolved
    echo "systemd-resolved stopped and disabled." dnsmasq --- dnsmasq ---
else "[Step 4] Stopping systemd-resolved (if active)..." "[Step 4] Stopping systemd-resolved (if active)..."
    echo "systemd-resolved was not active."lved; thenlved; then
fi  systemctl stop systemd-resolved  systemctl stop systemd-resolved
# Optional: Force update /etc/resolv.conf for the Pi itself
# echo "nameserver ${PI_DNS_SERVERS//,/$'\n'nameserver }" > /etc/resolv.conf # More robust way needed potentially
elseelse
echo "[Step 4] Restarting and enabling dnsmasq service..."
systemctl restart dnsmasq
systemctl enable dnsmasq /etc/resolv.conf for the Pi itself /etc/resolv.conf for the Pi itself
echo "[Step 4] dnsmasq service restarted and enabled." }" > /etc/resolv.conf # More robust way needed potentially }" > /etc/resolv.conf # More robust way needed potentially
sleep 2 # Wait for service
echo "[Step 4] Restarting and enabling dnsmasq service..."echo "[Step 4] Restarting and enabling dnsmasq service..."
# --- Step 5: Configure iptables Rules ---
echo "[Step 5] Configuring iptables redirect rules (Ports 80,443 -> ${TARGET_PORT})..."
echo "[Step 4] dnsmasq service restarted and enabled."echo "[Step 4] dnsmasq service restarted and enabled."
# Add rules to redirect web traffic to captive portal
echo "Adding iptables rule for HTTP (port 80) → port ${TARGET_PORT}..."
iptables -t nat -A PREROUTING -i ${PI_INTERFACE} -p tcp --dport 80 -j REDIRECT --to-port ${TARGET_PORT}
echo "[Step 5] Configuring iptables redirect rules (Ports 80,443 -> ${TARGET_PORT})..."echo "[Step 5] Configuring iptables redirect rules (Ports 80,443 -> ${TARGET_PORT})..."
echo "Adding iptables rule for HTTPS (port 443) → port 3443..."
iptables -t nat -A PREROUTING -i ${PI_INTERFACE} -p tcp --dport 443 -j REDIRECT --to-port 3443
echo "Adding iptables rule for HTTP (port 80) → port ${TARGET_PORT}..."echo "Adding iptables rule for HTTP (port 80) → port ${TARGET_PORT}..."
# Remove captive portal detection handling to avoid triggering notifications -p tcp --dport 80 -j REDIRECT --to-port ${TARGET_PORT} -p tcp --dport 80 -j REDIRECT --to-port ${TARGET_PORT}
# Instead, these domains will be handled by upstream DNS servers as configured in dnsmasq

# --- Step 6: Make iptables Rules Persistent ---
echo "[Step 6] Saving iptables rules..."
# The package installation should have prompted for saving, but save again just in case.# Add special rules for captive portal detection# --- Step 6: Make iptables Rules Persistent ---
netfilter-persistent save..."
EROUTING -i ${PI_INTERFACE} -p tcp --dport 80 -d captive.apple.com -j REDIRECT --to-port ${TARGET_PORT}ation should have prompted for saving, but save again just in case.
# --- Step 7: Fix dnsmasq Startup Timing Issues ---ROUTING -i ${PI_INTERFACE} -p tcp --dport 80 -d www.apple.com -j REDIRECT --to-port ${TARGET_PORT}ave
echo "[Step 7] Fixing dnsmasq startup timing issues..."iptables -t nat -A PREROUTING -i ${PI_INTERFACE} -p tcp --dport 80 -d clients3.google.com -j REDIRECT --to-port ${TARGET_PORT}

# Create NetworkManager dispatcher script to restart dnsmasq when wlan1 comes up (443)ming issues..."
echo "Creating NetworkManager dispatcher script..."
mkdir -p /etc/NetworkManager/dispatcher.d/atcher script to restart dnsmasq when wlan1 comes up
cat << EOF > /etc/NetworkManager/dispatcher.d/99-restart-dnsmasqecho "Creating NetworkManager dispatcher script..."
#!/bin/bash
INTERFACE=\$1
STATUS=\$2# The package installation should have prompted for saving, but save again just in case.#!/bin/bash

# Only restart dnsmasq when wlan1 comes up
if [ "\$INTERFACE" = "${PI_INTERFACE}" ] && [ "\$STATUS" = "up" ]; thenssues ---
    systemctl restart dnsmasq
fi${PI_INTERFACE}" ] && [ "\$STATUS" = "up" ]; then
EOForkManager dispatcher script to restart dnsmasq when wlan1 comes up restart dnsmasq
ting NetworkManager dispatcher script..."
# Make the script executablemkdir -p /etc/NetworkManager/dispatcher.d/EOF
chmod +x /etc/NetworkManager/dispatcher.d/99-restart-dnsmasqr.d/99-restart-dnsmasq

# Also modify dnsmasq.service to wait for networkrestart-dnsmasq
echo "Modifying dnsmasq service to wait for network..."ATUS=\$2
mkdir -p /etc/systemd/system/dnsmasq.service.d/ modify dnsmasq.service to wait for network
cat << EOF > /etc/systemd/system/dnsmasq.service.d/override.conf# Only restart dnsmasq when wlan1 comes upecho "Modifying dnsmasq service to wait for network..."
[Unit]NTERFACE}" ] && [ "\$STATUS" = "up" ]; then/dnsmasq.service.d/
Wants=network-online.target
After=network-online.target NetworkManager.servicefi[Unit]

[Service]
ExecStartPre=/bin/sleep 10
EOF
=/bin/sleep 10
# Reload systemd to apply changesce to wait for network
systemctl daemon-reloadk..."
mkdir -p /etc/systemd/system/dnsmasq.service.d/# Reload systemd to apply changes
# --- Step 8: Generate SSL certificates for HTTPS ---F > /etc/systemd/system/dnsmasq.service.d/override.conf daemon-reload
echo "[Step 8] Generating self-signed SSL certificates..."
CERT_DIR="certificates"ts=network-online.target-- Step 8: Generate SSL certificates for HTTPS ---
if [ ! -d "$CERT_DIR" ]; thenAfter=network-online.target NetworkManager.serviceecho "[Step 8] Generating self-signed SSL certificates..."
    echo "Creating certificates directory..."
    mkdir -p "$CERT_DIR"
fiExecStartPre=/bin/sleep 10    echo "Creating certificates directory..."

if [ -f "$CERT_DIR/key.pem" ] && [ -f "$CERT_DIR/cert.pem" ]; then
    echo "SSL certificates already exist. Skipping generation."ly changes
else-f "$CERT_DIR/cert.pem" ]; then
    echo "Generating new self-signed certificates valid for 365 days..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \SL certificates for HTTPS ---
        -keyout "$CERT_DIR/key.pem" \ho "[Step 8] Generating self-signed SSL certificates..."  echo "Generating new self-signed certificates valid for 365 days..."
        -out "$CERT_DIR/cert.pem" \CERT_DIR="certificates"    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -subj "/CN=Video Server/O=SVLFG/C=DE" \
        -addext "subjectAltName = IP:${PI_STATIC_IP}"
    chmod 600 "$CERT_DIR/key.pem" "$CERT_DIR/cert.pem"mkdir -p "$CERT_DIR"    -subj "/CN=Video Server/O=SVLFG/C=DE" \
    echo "SSL certificates generated successfully."
fi
 "$CERT_DIR/cert.pem" ]; thensuccessfully."
# After generating certificatesexist. Skipping generation."
chown "${SUDO_USER:-$USER}":"${SUDO_USER:-$USER}" "$CERT_DIR/key.pem" "$CERT_DIR/cert.pem"
chmod 644 "$CERT_DIR/cert.pem"  # Everyone can read the certificateid for 365 days..."
chmod 600 "$CERT_DIR/key.pem"   # Only owner can read the private key8 \RT_DIR/key.pem" "$CERT_DIR/cert.pem"
te
# After generating certificates      -out "$CERT_DIR/cert.pem" \mod 600 "$CERT_DIR/key.pem"   # Only owner can read the private key
chown "${SUDO_USER:-$USER}":"${SUDO_USER:-$USER}" "$CERT_DIR/privkey.pem" "$CERT_DIR/fullchain.pem"        -subj "/CN=Video Server/O=SVLFG/C=DE" \
chmod 644 "$CERT_DIR/fullchain.pem"  # Everyone can read the certificate = IP:${PI_STATIC_IP}"
chmod 600 "$CERT_DIR/privkey.pem"   # Only owner can read the private key


# --- Step 9: Completion ---
echo ""
echo "--- Setup Complete! ---"
echo ""
echo "Summary:"
echo "* Static IP ${PI_STATIC_IP}/${PI_IP_PREFIX} configured on interface ${PI_INTERFACE} (via NM connection '${NM_CON_NAME}')."echo ""
echo "* dnsmasq installed and configured to resolve all DNS to ${PI_STATIC_IP}."# After generating certificatesecho "Summary:"
if [ "$ENABLE_DHCP" = "true" ]; then"${SUDO_USER:-$USER}" "$CERT_DIR/privkey.pem" "$CERT_DIR/fullchain.pem"C_IP}/${PI_IP_PREFIX} configured on interface ${PI_INTERFACE} (via NM connection '${NM_CON_NAME}')."
    echo "* dnsmasq DHCP server enabled for range ${DHCP_RANGE_START}-${DHCP_RANGE_END}."44 "$CERT_DIR/fullchain.pem"  # Everyone can read the certificate dnsmasq installed and configured to resolve all DNS to ${PI_STATIC_IP}."
fiem"   # Only owner can read the private key; then
echo "* iptables rules added to redirect HTTP traffic (port 80) to port 3000 and HTTPS traffic (port 443) to port 3443."smasq DHCP server enabled for range ${DHCP_RANGE_START}-${DHCP_RANGE_END}."
echo "* iptables rules should be persistent across reboots."
echo "* Added fixes for dnsmasq startup timing issues (NetworkManager dispatcher + service delay)."
echo ""
echo "Next Steps:"ming issues (NetworkManager dispatcher + service delay)."
echo "1.  Ensure your web application is running on the Pi and listening on port ${TARGET_PORT}."
echo "2.  Connect client devices to the ${PI_INTERFACE} network."ho "Summary:"ho "Next Steps:"
echo "3.  Clients should get DNS/IP automatically (if DHCP enabled) or configure them manually to use ${PI_STATIC_IP} as DNS."AME}')."
echo "4.  Test DNS resolution and HTTP access (e.g., http://example.com) from a client device."to ${PI_STATIC_IP}."ork."
echo "5.  A reboot (sudo reboot) is recommended to verify all changes work properly."
echo ""o "* dnsmasq DHCP server enabled for range ${DHCP_RANGE_START}-${DHCP_RANGE_END}.".  Test DNS resolution and HTTP access (e.g., http://example.com) from a client device."
s recommended to verify all changes work properly."
exit 0