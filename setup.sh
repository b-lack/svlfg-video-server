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
apt-get install -y hostapd dnsmasq iptables nginx

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
domain=local
# Only redirect the specific domain we want
address=/pi1.gruenecho.de/192.168.4.1
# Allow all other domains to resolve normally
server=8.8.8.8
server=8.8.4.4
EOF

# Add captive portal handling 
cat > /etc/nginx/sites-available/captive-portal << EOF
server {
    listen 80;
    server_name captive.apple.com connectivitycheck.gstatic.com www.google.com clients3.google.com;

    location / {
        return 204;
    }
}
EOF

ln -s /etc/nginx/sites-available/captive-portal /etc/nginx/sites-enabled/

# Enable IP forwarding
echo "Enabling IP forwarding..."
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Configure iptables for redirection
echo "Setting up redirection rules..."
# Clear existing rules
iptables -t nat -F

# Only redirect pi1.gruenecho.de to port 3000
# First create a chain for our exceptions
iptables -t nat -N CAPTIVE_PORTAL_EXCEPTIONS 2>/dev/null || true
iptables -t nat -F CAPTIVE_PORTAL_EXCEPTIONS

# Add exceptions for captive portal detection domains
iptables -t nat -A CAPTIVE_PORTAL_EXCEPTIONS -d 8.8.8.8 -j RETURN
iptables -t nat -A CAPTIVE_PORTAL_EXCEPTIONS -d 8.8.4.4 -j RETURN
iptables -t nat -A CAPTIVE_PORTAL_EXCEPTIONS -d 208.67.222.222 -j RETURN
iptables -t nat -A CAPTIVE_PORTAL_EXCEPTIONS -p tcp --dport 80 -m string --string "captive.apple.com" --algo bm -j RETURN
iptables -t nat -A CAPTIVE_PORTAL_EXCEPTIONS -p tcp --dport 80 -m string --string "connectivitycheck.gstatic.com" --algo bm -j RETURN
iptables -t nat -A CAPTIVE_PORTAL_EXCEPTIONS -p tcp --dport 80 -m string --string "clients3.google.com" --algo bm -j RETURN
iptables -t nat -A CAPTIVE_PORTAL_EXCEPTIONS -p tcp --dport 80 -m string --string "www.google.com" --algo bm -j RETURN

# Only redirect traffic for pi1.gruenecho.de to port 3000
iptables -t nat -A PREROUTING -p tcp --dport 80 -m string --string "pi1.gruenecho.de" --algo bm -j REDIRECT --to-port 3000

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

# Enable and start services
echo "Enabling services..."
systemctl unmask hostapd
systemctl enable hostapd
systemctl enable dnsmasq
systemctl enable nginx

# Restart services
echo "Restarting services..."
systemctl restart dhcpcd
systemctl restart hostapd
systemctl restart dnsmasq
systemctl restart nginx

echo "Setup complete! The SVLFG WiFi network should now be available."
echo "When users connect and visit pi1.gruenecho.de, they will be redirected to your Node.js server on port 3000."
