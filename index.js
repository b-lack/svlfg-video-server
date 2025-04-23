const express = require('express');
const http = require('http');
const https = require('https');
const fs = require('fs');
const { Server } = require('socket.io');
const cors = require('cors');
const app = express();

// Create a separate Express app for HTTP to HTTPS redirection
const redirectApp = express();
redirectApp.use((req, res) => {
  const canonicalHost = 'pi1.gruenecho.de';
  // Always redirect to HTTPS canonical domain
  const redirectUrl = `https://${canonicalHost}${req.originalUrl}`;
  res.redirect(301, redirectUrl);
});

// HTTP server ONLY for redirecting to HTTPS
const httpServer = http.createServer(redirectApp);

// Main app runs only on HTTPS
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

// Redirect HTTPS requests with wrong host to canonical host
const canonicalHost = 'pi1.gruenecho.de';
app.use((req, res, next) => {
  // If the host is not the canonical one, redirect
  if (req.hostname !== canonicalHost) {
    const redirectUrl = `https://${canonicalHost}${req.originalUrl}`;
    return res.redirect(301, redirectUrl);
  }
  next();
});

// Set up Socket.io on the HTTPS server if available, otherwise HTTP
const io = new Server(httpsServer || httpServer, {
  cors: {
    origin: '*',
  }
});

app.use(cors());
app.use(express.static('public'));

// Catch-all for SPA: serve index.html for any unknown route (after static)
app.use((req, res, next) => {
  res.sendFile('index.html', { root: 'public' });
});

app.get('*', (req, res) => {
  res.sendFile('index.html', { root: 'public' });
});

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

// Start HTTP redirect server
const PORT = process.env.PORT || 3000;
httpServer.listen(PORT, '0.0.0.0', () => {
  console.log(`HTTP redirect server running on port ${PORT}`);
});

// Start HTTPS server
if (httpsServer) {
  const HTTPS_PORT = process.env.HTTPS_PORT || 3443;
  httpsServer.listen(HTTPS_PORT, '0.0.0.0', () => {
    console.log(`HTTPS Server running on port ${HTTPS_PORT}`);
  });
}