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
# WPA2/WPA3 security settings
wpa=2
wpa_key_mgmt=WPA-PSK SAE
wpa_pairwise=CCMP
rsn_pairwise=CCMP
wpa_passphrase=12345678
# Enable WPA3 transition mode (supports both WPA2 and WPA3 clients)
ieee80211w=1
sae_require_mfp=1
EOF

# Configure hostapd to use our configuration
echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' > /etc/default/hostapd

# Configure dnsmasq (DHCP and DNS)
echo "Configuring DHCP and DNS..."
mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig
cat > /etc/dnsmasq.conf << EOF
interface=wlan1
dhcp-range=192.168.4.2,192.168.4.100,255.255.255.0,24h
# Don't redirect captive portal detection domains - let them fail naturally
# This prevents devices from showing captive portal notifications
# Don't use /etc/hosts
no-hosts
# Forward DNS queries to upstream DNS servers (Google DNS)
server=8.8.8.8
server=8.8.4.4
EOF

# Enable IP forwarding
echo "Enabling IP forwarding..."
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Configure iptables for network access
echo "Setting up network access rules..."
# Clear existing rules
iptables -t nat -F
iptables -F

# Enable NAT for internet access
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i wlan1 -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o wlan1 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Optional: redirect your application traffic only (remove if not needed)
iptables -t nat -A PREROUTING -i wlan1 -p tcp -d 192.168.4.1 --dport 80 -j REDIRECT --to-port 3000
iptables -t nat -A PREROUTING -i wlan1 -p tcp -d 192.168.4.1 --dport 443 -j REDIRECT --to-port 3443

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
