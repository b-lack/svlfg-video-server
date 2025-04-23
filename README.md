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
pm2 save
pm2 startup # run the output command
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
