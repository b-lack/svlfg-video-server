# SVLFG - Video-Server

## Description

## Requirements
- [Node.js](https://nodejs.org/en/download/) (v22.x.x)

## Install

```bash
git clone https://github.com/b-lack/svlfg-video-server.git
cd svlfg-video-server
npm install
npm install pm2 -g

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
sudo apt install dnsmasq
sudo nano /etc/dnsmasq.d/captiveportal.conf
192.168.8.195


sudo nmcli connection modify "Hotspot" \
    ipv4.method manual \
    ipv4.addresses 192.168.1.10/24 \
    ipv4.gateway 192.168.1.1 \
    ipv4.dns "8.8.8.8,1.1.1.1"