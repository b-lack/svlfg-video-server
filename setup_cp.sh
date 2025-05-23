#!/bin/bash

# Exit on error
set -e

# Must run as root
if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

echo "Installing required packages..."
apt-get update
apt-get install -y hostapd dnsmasq iptables

# Stop services for configuration
systemctl stop hostapd
systemctl stop dnsmasq

# Configure network interface
echo "Configuring network interface..."
cat > /etc/dhcpcd.conf << EOF
interface wlan1
    static ip_address=192.168.4.1/24
    nohook wpa_supplicant
EOF

# Configure hostapd (Access Point)
echo "Setting up WiFi access point..."
cat > /etc/hostapd/hostapd.conf << EOF
interface=wlan1
driver=nl80211
ssid=SVLFG
hw_mode=g
channel=7
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=0
EOF

# Configure hostapd to use our configuration
echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' > /etc/default/hostapd

# Configure dnsmasq (DHCP and DNS)
echo "Configuring DHCP and DNS..."
mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig
cat > /etc/dnsmasq.conf << EOF
interface=wlan1
dhcp-range=192.168.4.2,192.168.4.100,255.255.255.0,24h
# Redirect ALL domains to our Pi
address=/#/192.168.4.1
# Don't use /etc/hosts
no-hosts
# Don't forward DNS queries to upstream servers
no-resolv
# Respond to all DNS queries with our IP
bogus-priv
EOF

# Enable IP forwarding
echo "Enabling IP forwarding..."
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Configure iptables for redirection
echo "Setting up redirection rules..."
# Clear existing rules
iptables -t nat -F

# Explicitly redirect HTTP/HTTPS traffic for pi1.gruenecho.de to the correct Node.js port
# Make sure we're not catching SSH traffic (port 22)
iptables -t nat -A PREROUTING -i wlan1 -p tcp --dport 80 -j REDIRECT --to-port 3000
iptables -t nat -A PREROUTING -i wlan1 -p tcp --dport 443 -j REDIRECT --to-port 3443

# Save iptables rules
iptables-save > /etc/iptables.ipv4.nat

# Make iptables rules persistent
echo "Making iptables rules persistent..."
cat > /etc/rc.local << EOF
#!/bin/sh -e
iptables-restore < /etc/iptables.ipv4.nat
exit 0
EOF
chmod +x /etc/rc.local

# Create a service file for the Node.js server
echo "Creating service for Node.js server..."
cat > /etc/systemd/system/nodeserver.service << EOF
[Unit]
Description=Node.js Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/Users/b-mini/sites/svlfg/video/server
ExecStart=/usr/bin/node /Users/b-mini/sites/svlfg/video/server/index.js
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Enable and start services
echo "Enabling services..."
systemctl daemon-reload
systemctl unmask hostapd
systemctl enable hostapd
systemctl enable dnsmasq
systemctl enable nodeserver

# Restart services
echo "Restarting services..."
systemctl restart dhcpcd
systemctl restart hostapd
systemctl restart dnsmasq
systemctl start nodeserver

echo "Setup complete! The SVLFG WiFi network should now be available."
echo "The Node.js server will handle all connectivity checks to prevent captive portal and 'no internet' notifications."
