const express = require('express');
const http = require('http');
const https = require('https');
const fs = require('fs');
const { Server } = require('socket.io');
const cors = require('cors');
const app = express();

const canonicalHost = 'pi1.gruenecho.de';

// Configure middleware
app.use(cors());

// Simple domain-based routing middleware
app.use((req, res, next) => {
  // Log all requests
  console.log(`${req.method} ${req.hostname}${req.originalUrl} from ${req.ip}`);
  
  // If it's our canonical host, proceed to normal handling
  if (req.hostname === canonicalHost) {
    return next();
  }
  
  // For all other domains, just return 204 No Content
  // This prevents captive portal and "no internet" notifications
  return res.sendStatus(204);
});

// Serve static files
app.use(express.static('public'));

// Default route handler
app.use((req, res) => {
  res.sendFile('index.html', { root: 'public' });
});

// Set up HTTP server
const httpServer = http.createServer(app);

// Set up Socket.io
const io = new Server(httpServer, {
  cors: {
    origin: '*',
  }
});

// WebRTC signaling
let broadcaster;

io.on('connection', (socket) => {
  socket.on('broadcaster', () => {
    broadcaster = socket.id;
    socket.broadcast.emit('broadcaster');
  });

  socket.on('watcher', () => {
    if (broadcaster) {
      socket.to(broadcaster).emit('watcher', socket.id);
    }
  });

  socket.on('offer', (id, message) => {
    socket.to(id).emit('offer', socket.id, message);
  });

  socket.on('answer', (id, message) => {
    socket.to(id).emit('answer', socket.id, message);
  });

  socket.on('candidate', (id, message) => {
    socket.to(id).emit('candidate', socket.id, message);
  });

  socket.on('disconnect', () => {
    socket.broadcast.emit('disconnectPeer', socket.id);
    if (socket.id === broadcaster) {
      broadcaster = null;
    }
  });
});

// Start HTTP server
const PORT = process.env.PORT || 3000;
httpServer.listen(PORT, '0.0.0.0', () => {
  console.log(`HTTP server running on port ${PORT}`);
  console.log(`Serving ${canonicalHost}, returning 204 for all other domains`);
});