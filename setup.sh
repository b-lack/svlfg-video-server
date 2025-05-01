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
# Redirect ALL domains to our IP (except pi1.gruenecho.de which is already handled)
address=/#/192.168.4.1
EOF

# Replace the Nginx captive portal with a more comprehensive reverse proxy
cat > /etc/nginx/sites-available/captive-portal << EOF
server {
    listen 80 default_server;
    
    # Handle connectivity check endpoints directly
    location /generate_204 {
        return 204;
    }
    
    location /ncsi.txt {
        add_header Content-Type text/plain;
        return 200 "Microsoft NCSI";
    }
    
    location /hotspot-detect.html {
        add_header Content-Type text/html;
        return 200 '<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>';
    }
    
    # Specific handling for pi1.gruenecho.de
    location / {
        # Handle known connectivity check endpoints
        if (\$request_uri ~* "/generate_204") {
            return 204;
        }
        
        # Forward everything else to our Node.js app
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

# Remove any old symbolic links and create a new one
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-enabled/captive-portal
ln -sf /etc/nginx/sites-available/captive-portal /etc/nginx/sites-enabled/

# Enable IP forwarding
echo "Enabling IP forwarding..."
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Configure iptables for forwarding all traffic
echo "Setting up redirection rules..."
# Clear existing rules
iptables -t nat -F

# Redirect all HTTP traffic to the Nginx server
iptables -t nat -A PREROUTING -i wlan1 -p tcp --dport 80 -j REDIRECT --to-port 80
iptables -t nat -A PREROUTING -i wlan1 -p tcp --dport 443 -j REDIRECT --to-port 80

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
echo "All internet traffic will be forwarded to your Node.js server on port 3000."
