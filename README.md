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
npm install
npm install pm2 -g
pm2 save
pm2 startup # run the output command

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
