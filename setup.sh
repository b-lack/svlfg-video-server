#!/bin/bash

# Install required packages
sudo apt update
sudo apt install -y hostapd dnsmasq

# Stop services to configure
sudo systemctl stop hostapd
sudo systemctl stop dnsmasq

# Configure static IP for wlan0
sudo tee /etc/dhcpcd.conf > /dev/null <<EOF
interface wlan0
    static ip_address=192.168.4.1/24
    nohook wpa_supplicant
EOF

sudo service dhcpcd restart

# Configure hostapd (open network)
sudo tee /etc/hostapd/hostapd.conf > /dev/null <<EOF
interface=wlan0
driver=nl80211
ssid=SVLFG
hw_mode=g
channel=7
auth_algs=1
wmm_enabled=0
EOF

sudo sed -i 's|#DAEMON_CONF=""|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

# Configure dnsmasq for DHCP and DNS
sudo tee /etc/dnsmasq.conf > /dev/null <<EOF
interface=wlan0
dhcp-range=192.168.4.2,192.168.4.20,255.255.255.0,24h
address=/pi1.gruenecho.de/192.168.4.1
EOF

# Enable IP forwarding
sudo sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sudo sysctl -p

# Start services
sudo systemctl unmask hostapd
sudo systemctl enable hostapd
sudo systemctl enable dnsmasq
sudo systemctl start hostapd
sudo systemctl start dnsmasq

echo "Wi-Fi AP 'SVLFG' created. Devices connecting to 'pi1.gruenecho.de' will be directed to 192.168.4.1."

echo "To redirect all HTTP traffic to your Node.js server on port 3000, add this iptables rule:"
sudo iptables -t nat -A PREROUTING -i wlan0 -p tcp --dport 80 -j REDIRECT --to-port 3000