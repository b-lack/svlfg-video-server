# SVLFG - Video-Server
SVLFG Video Server creates a self-contained Wi-Fi hotspot on a Raspberry Pi that automatically redirects connected devices to a video streaming interface. The server facilitates WebRTC-based video streaming where one device broadcasts video that can be viewed simultaneously by multiple other devices connected to the Pi's Wi-Fi network.

## Requirements
- [Node.js](https://nodejs.org/en/download/) (v22.x.x)

## Setup

```bash
git clone https://github.com/b-lack/svlfg-video-server.git
cd svlfg-video-server
cp .env.example .env
````

## Install dependencies

```bash
# Install Node.js dependencies
npm install

# Install PM2 globally
npm install pm2 -g

# Start with a single instance
pm2 start npm --name "video-server" -i 1 -- run start

# Save the process list
pm2 save

# Set up to start on boot (run the command that is output)
pm2 startup

```

## Create self-signed certificate

```bash
mkdir -p certificates
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout certificates/key.pem -out certificates/cert.pem
```

## RUN

```bash
npm run pm2:start
```

## Hardware
- Raspberry Pi 5
- EDUP WiFi 6E USB WLAN Stick

## Software
- Default Raspberry Pi OS
- dnsmasq

## Setup

Prompt: how to setup dnsmasq on rasperry pi 5 to forward all connected devices to localhost:3000

```bash
chmod +x setup.sh
sudo ./setup.sh
```


## Certificate Security Warnings

When connecting to the video server via HTTPS, browsers will show security warnings because:

1. The certificate is self-signed (not issued by a trusted authority)
2. The certificate was generated for the Pi's IP address, but you're accessing it via a domain name

This is expected behavior in this local setup. Simply click "Advanced" and "Proceed" in your browser to continue to the video interface.