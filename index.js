const express = require('express');
const http = require('http');
const https = require('https');
const fs = require('fs');
const { Server } = require('socket.io');
const cors = require('cors');
const app = express();

// Redirect all requests not using the canonical domain to the canonical domain
app.use((req, res, next) => {
  const canonicalHost = 'pi1.gruenecho.de';
  // Check if the request is already for the canonical domain and using HTTPS
  if (
    req.hostname !== canonicalHost ||
    req.protocol !== 'https'
  ) {
    // Build the redirect URL
    const redirectUrl = `https://${canonicalHost}${req.originalUrl}`;
    return res.redirect(301, redirectUrl);
  }
  next();
});

// Use both HTTP and HTTPS
const httpServer = http.createServer(app);

// HTTPS options - with error handling for certificates
let httpsServer;
try {
  const options = {
    key: fs.readFileSync('./certificates/privkey.pem'),
    cert: fs.readFileSync('./certificates/fullchain.pem')
  };
  httpsServer = https.createServer(options, app);
} catch (err) {
  console.error('Error loading certificates:', err);
  console.log('Falling back to HTTP only');
  httpsServer = null;
}

// Set up Socket.io on the HTTPS server if available, otherwise HTTP
const io = new Server(httpsServer || httpServer, {
  cors: {
    origin: '*',
  }
});

app.use(cors());
app.use(express.static('public'));

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

// Start both servers
const PORT = process.env.PORT || 3000;
httpServer.listen(PORT, '0.0.0.0', () => {
  console.log(`HTTP Server running on port ${PORT}`);
});

if (httpsServer) {
  const HTTPS_PORT = process.env.HTTPS_PORT || 3443;
  httpsServer.listen(HTTPS_PORT, '0.0.0.0', () => {
    console.log(`HTTPS Server running on port ${HTTPS_PORT}`);
  });
}