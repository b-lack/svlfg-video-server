const express = require('express');
const http = require('http');
const socketIo = require('socket.io');
const cors = require('cors');
const path = require('path');

// Create Express app and HTTP server
const app = express();
const server = http.createServer(app);

// Enable CORS
app.use(cors());
app.use(express.static(path.join(__dirname, '../client')));

// Set up Socket.IO
const io = socketIo(server, {
  cors: {
    origin: "*",
    methods: ["GET", "POST"]
  }
});

// Store connected clients
const clients = {};

io.on('connection', socket => {
  console.log('Client connected:', socket.id);
  clients[socket.id] = { socket };

  // Handle offer from a client
  socket.on('offer', (data) => {
    console.log('Received offer from', socket.id);
    // Broadcast to all other clients
    socket.broadcast.emit('offer', {
      sdp: data.sdp,
      socketId: socket.id
    });
  });

  // Handle answer
  socket.on('answer', (data) => {
    console.log('Received answer from', socket.id, 'to', data.target);
    // Send to specific target client
    if (clients[data.target]) {
      io.to(data.target).emit('answer', {
        sdp: data.sdp,
        socketId: socket.id
      });
    }
  });

  // Handle ICE candidates
  socket.on('ice-candidate', (data) => {
    console.log('Received ICE candidate from', socket.id);
    // Broadcast to all other clients or specific target
    if (data.target) {
      io.to(data.target).emit('ice-candidate', {
        candidate: data.candidate,
        socketId: socket.id
      });
    } else {
      socket.broadcast.emit('ice-candidate', {
        candidate: data.candidate,
        socketId: socket.id
      });
    }
  });

  // Handle disconnection
  socket.on('disconnect', () => {
    console.log('Client disconnected:', socket.id);
    delete clients[socket.id];
    // Notify other clients
    socket.broadcast.emit('peer-disconnect', { socketId: socket.id });
  });
});

// Listen on all network interfaces
server.listen(8080, '0.0.0.0', () => {
  console.log('WebRTC signaling server running on:');
  // Display all local IP addresses
  const { networkInterfaces } = require('os');
  const nets = networkInterfaces();
  
  for (const name of Object.keys(nets)) {
    for (const net of nets[name]) {
      if (net.family === 'IPv4' && !net.internal) {
        console.log(`http://${net.address}:8080`);
      }
    }
  }
});