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
# Redirect specific domains for connectivity checks
address=/connectivitycheck.gstatic.com/192.168.4.1
address=/www.gstatic.com/192.168.4.1
address=/www.google.com/192.168.4.1
address=/clients3.google.com/192.168.4.1
address=/captive.apple.com/192.168.4.1
# Redirect our application domain
address=/pi1.gruenecho.de/192.168.4.1
# Allow all other domains to resolve normally
server=8.8.8.8
server=8.8.4.4
EOF

# Create improved captive portal handling
cat > /etc/nginx/sites-available/captive-portal << EOF
server {
    listen 80 default_server;
    
    # Handle Google connectivity checks
    location /generate_204 {
        return 204;
    }
    
    location /ncsi.txt {
        add_header Content-Type text/plain;
        return 200 "Microsoft NCSI";
    }
    
    location /connecttest.txt {
        add_header Content-Type text/plain;
        return 200 "Microsoft Connect Test";
    }
    
    # Apple CNA handling
    location /hotspot-detect.html {
        add_header Content-Type text/html;
        return 200 '<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>';
    }
    
    # Catch-all for other connectivity checks
    location / {
        if (\$http_user_agent ~* "CaptiveNetworkSupport|ConnectivityCheck") {
            add_header Content-Type text/html;
            return 200 '<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>';
        }
        
        # Only redirect pi1.gruenecho.de to the Node.js server
        if (\$host = "pi1.gruenecho.de") {
            proxy_pass http://127.0.0.1:3000;
        }
    }
}
EOF

ln -s /etc/nginx/sites-available/captive-portal /etc/nginx/sites-enabled/

# Enable IP forwarding
echo "Enabling IP forwarding..."
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Configure iptables for redirection and NAT
echo "Setting up redirection rules..."
# Clear existing rules
iptables -t nat -F

# If we have an internet-connected interface (like eth0), set up NAT
if ip link show eth0 >/dev/null 2>&1; then
    echo "Setting up NAT for possible internet sharing..."
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
fi

# Only redirect pi1.gruenecho.de to port 3000
iptables -t nat -A PREROUTING -i wlan1 -p tcp --dport 80 -d 192.168.4.1 -j REDIRECT --to-port 80

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
