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

  // Set authentication cookie
  res.cookie('authenticated', 'true', { 
    maxAge: 24 * 60 * 60 * 1000, // 24 hours
    httpOnly: true,
    secure: req.secure
  });
  
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
  
  // Google/Android connectivity checks - respond with proper 204 status for these domains
  // (using 204 instead of redirects to reduce overhead)
  if (hostname.includes('connectivitycheck.gstatic.com') || 
      hostname.includes('clients3.google.com') ||
      hostname.includes('www.google.com')) {
    console.log(`Handling Google connectivity check for ${hostname}`);
    // Return 204 No Content to indicate success without redirection
    return res.status(204).end();
  }

  // Apple connectivity checks
  if (hostname.includes('captive.apple.com') || 
      hostname.includes('www.apple.com') ||
      hostname.includes('appleiphonecell.com')) {
    console.log(`Handling Apple connectivity check for ${hostname}`);
    // Return success HTML that Apple expects
    return res.status(200).send('<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>');
  }

  // Microsoft connectivity checks
  if (hostname.includes('msftconnecttest.com') || 
      hostname.includes('msftncsi.com')) {
    console.log(`Handling Microsoft connectivity check for ${hostname}`);
    return res.status(200).send('Microsoft NCSI');
  }
  
  // Handle connectivity checks based on path for non-canonical hosts
  const path = req.path.toLowerCase();
  
  // Apple devices
  if (path.includes('hotspot-detect') || path.includes('success.html')) {
    return res.redirect(302, 'http://pi1.gruenecho.de');
  }
  
  // Microsoft NCSI
  if (path.includes('ncsi.txt') || path.includes('connecttest.txt')) {
    return res.redirect(302, 'http://pi1.gruenecho.de');
  }
  
  // Google/Android path-based checks
  if (path.includes('generate_204') || path.includes('gen_204')) {
    return res.redirect(302, 'http://pi1.gruenecho.de');
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
let peerConnections = {}; // Track all active peer connections
let lastConnectionCheck = Date.now();
const CONNECTION_CHECK_INTERVAL = 60000; // Check connections every minute

// Memory usage monitoring
const monitorMemoryUsage = () => {
  const memoryUsage = process.memoryUsage();
  console.log(`Memory usage: RSS ${Math.round(memoryUsage.rss / 1024 / 1024)}MB, Heap ${Math.round(memoryUsage.heapUsed / 1024 / 1024)}/${Math.round(memoryUsage.heapTotal / 1024 / 1024)}MB`);
  
  // If memory usage is high, force garbage collection if available
  if (global.gc && memoryUsage.heapUsed > 0.8 * memoryUsage.heapTotal) {
    console.log('Forcing garbage collection');
    global.gc();
  }
};

// Set up periodic memory checks
const memoryInterval = setInterval(monitorMemoryUsage, 300000); // Every 5 minutes

io.on('connection', (socket) => {
  console.log(`New socket connection: ${socket.id}`);
  
  // Set up ping/pong to keep connections healthy
  const pingInterval = setInterval(() => {
    socket.emit('ping');
  }, 25000);
  
  socket.on('pong', () => {
    // Reset socket timeout on pong response
    if (socket.conn) {
      socket.conn.resetTimeout();
    }
  });
  
  socket.on('broadcaster', () => {
    // Cleanup previous broadcaster if it exists
    if (broadcaster && broadcaster !== socket.id) {
      io.to(broadcaster).emit('broadcaster_replaced');
    }
    
    broadcaster = socket.id;
    peerConnections[socket.id] = { role: 'broadcaster', timestamp: Date.now() };
    socket.broadcast.emit('broadcaster');
  });

  socket.on('watcher', () => {
    if (broadcaster) {
      peerConnections[socket.id] = { role: 'watcher', timestamp: Date.now() };
      socket.to(broadcaster).emit('watcher', socket.id);
    }
  });

  socket.on('offer', (id, message) => {
    if (peerConnections[socket.id]) {
      peerConnections[socket.id].timestamp = Date.now();
    }
    socket.to(id).emit('offer', socket.id, message);
  });

  socket.on('answer', (id, message) => {
    if (peerConnections[socket.id]) {
      peerConnections[socket.id].timestamp = Date.now();
    }
    socket.to(id).emit('answer', socket.id, message);
  });

  socket.on('candidate', (id, message) => {
    socket.to(id).emit('candidate', socket.id, message);
  });

  // Cleanup function for a socket
  const cleanupConnection = (socketId) => {
    // Clear any timers for this socket
    if (pingInterval) {
      clearInterval(pingInterval);
    }
    
    // Notify peers about disconnection
    socket.broadcast.emit('disconnectPeer', socketId);
    
    // Handle broadcaster disconnect
    if (socketId === broadcaster) {
      broadcaster = null;
      console.log('Broadcaster disconnected');
    }
    
    // Remove from tracked connections
    delete peerConnections[socketId];
  };

  socket.on('disconnect', () => {
    console.log(`Socket disconnected: ${socket.id}`);
    cleanupConnection(socket.id);
  });
  
  // Add connection quality reporting
  socket.on('connection_stats', (stats) => {
    console.log(`Connection stats from ${socket.id}:`, stats);
    // Could store these stats for monitoring/alerts
  });
  
  // Check for stale connections periodically
  if (Date.now() - lastConnectionCheck > CONNECTION_CHECK_INTERVAL) {
    lastConnectionCheck = Date.now();
    const staleThreshold = Date.now() - (5 * 60 * 1000); // 5 minutes
    
    Object.keys(peerConnections).forEach(id => {
      if (peerConnections[id].timestamp < staleThreshold) {
        console.log(`Removing stale connection: ${id}`);
        io.to(id).emit('connection_timeout');
        delete peerConnections[id];
        
        // If it was the broadcaster, reset broadcaster
        if (id === broadcaster) {
          broadcaster = null;
        }
      }
    });
  }
});

// Cleanup on server shutdown
process.on('SIGINT', () => {
  clearInterval(memoryInterval);
  console.log('Shutting down server...');
  process.exit(0);
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