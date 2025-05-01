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
app.use(express.urlencoded({ extended: true })); // For parsing form submissions

// Simple domain-based routing middleware
app.use((req, res, next) => {
  // Log all requests
  console.log(`${req.method} ${req.hostname}${req.originalUrl} from ${req.ip}`);
  
  // Check if we're getting binary data that might be SSH traffic
  if (req.headers['content-type'] && req.headers['content-type'].includes('application/ssh')) {
    console.log('Detected possible SSH connection attempt, responding with HTTP');
    return res.status(400).send('This is an HTTP server, not SSH');
  }
  
  // If it's our canonical host, proceed to normal application
  if (req.hostname === canonicalHost) {
    return next();
  }
  
  // Handle specific domains for connectivity checks
  const hostname = req.hostname.toLowerCase();
  
  // Google/Android connectivity checks - explicitly handle these domains
  if (hostname.includes('connectivitycheck.gstatic.com') || 
      hostname.includes('clients3.google.com') ||
      hostname.includes('www.google.com')) {
    console.log(`Handling Google connectivity check for ${hostname}`);
    return res.sendStatus(204);
  }

  // Apple connectivity checks
  if (hostname.includes('captive.apple.com') || 
      hostname.includes('www.apple.com') ||
      hostname.includes('appleiphonecell.com')) {
    console.log(`Handling Apple connectivity check for ${hostname}`);
    res.setHeader('Content-Type', 'text/html');
    return res.send('<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>');
  }

  // Microsoft connectivity checks
  if (hostname.includes('msftconnecttest.com') || 
      hostname.includes('msftncsi.com')) {
    console.log(`Handling Microsoft connectivity check for ${hostname}`);
    res.setHeader('Content-Type', 'text/plain');
    return res.send('Microsoft NCSI');
  }
  
  // Handle connectivity checks based on path for non-canonical hosts
  const path = req.path.toLowerCase();
  
  // Apple devices
  if (path.includes('hotspot-detect') || path.includes('success.html')) {
    res.setHeader('Content-Type', 'text/html');
    return res.send('<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>');
  }
  
  // Microsoft NCSI
  if (path.includes('ncsi.txt') || path.includes('connecttest.txt')) {
    res.setHeader('Content-Type', 'text/plain');
    return res.send('Microsoft NCSI');
  }
  
  // Google/Android path-based checks
  if (path.includes('generate_204') || path.includes('gen_204')) {
    return res.sendStatus(204);
  }
  
  // For all other non-recognized requests, proceed to the app
  next();
});

// Handle login endpoint
app.post('/login', (req, res) => {
  console.log('Login request received:', req.body);
  
  // Always authenticate in this demo
  // In a real system, you would check credentials here
  
  // Set a session cookie to maintain login state
  res.cookie('authenticated', 'true', { 
    maxAge: 24 * 60 * 60 * 1000, // 24 hours
    httpOnly: true
  });
  
  // Redirect to success page
  res.redirect('/success.html');
});

// Serve static files for our application
app.use(express.static('public'));

// Default route handler for our application
app.use((req, res) => {
  res.sendFile('index.html', { root: 'public' });
});

// Set up HTTP server
const httpServer = http.createServer(app);

// Set up HTTPS server if certificates are available
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

// Set up Socket.io
const io = new Server(httpsServer || httpServer, {
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
});

// Start HTTPS server if available
if (httpsServer) {
  const HTTPS_PORT = process.env.HTTPS_PORT || 3443;
  httpsServer.listen(HTTPS_PORT, '0.0.0.0', () => {
    console.log(`HTTPS Server running on port ${HTTPS_PORT}`);
  });
}