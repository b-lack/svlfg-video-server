const WebSocket = require('ws');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const http = require('http');

// Create WebSocket server
const wss = new WebSocket.Server({ port: 3000 });
console.log('WebSocket server started on port 3000');

wss.on('connection', (ws) => {
  console.log('Browser connected');
  
  // Create temp directory for video chunks
  const tempDir = fs.mkdtempSync(path.join(require('os').tmpdir(), 'rtsp-'));
  const inputPath = path.join(tempDir, 'input.webm');
  const outputPath = path.join(tempDir, 'output.mp4');
  
  let ffmpeg;
  let isConnected = false;
  
  try {
    // Switch to HLS output format which is more compatible
    ffmpeg = spawn('ffmpeg', [
        '-fflags', '+nobuffer+flush_packets',
        '-flags', 'low_delay',
        '-f', 'webm',
        '-i', 'pipe:0',
        '-c:v', 'libx264',
        '-preset', 'ultrafast',
        '-tune', 'zerolatency',
        '-x264-params', 'keyint=30:min-keyint=30',
        '-pix_fmt', 'yuv420p',
        '-profile:v', 'baseline',
        '-f', 'hls',
        '-hls_time', '0.2',                    // Very short segments
        '-hls_list_size', '2',                 // Keep very few segments
        '-hls_flags', 'delete_segments+append_list+omit_endlist+independent_segments',
        '-hls_segment_type', 'fmp4',           // Use fMP4 segments
        '-method', 'PUT',                      // Enable HTTP PUT for part uploads
        '-hls_segment_filename', path.join(tempDir, 'segment_%03d.m4s'),
        path.join(tempDir, 'playlist.m3u8')
    ]);
    
    ffmpeg.on('error', (err) => {
      console.error('FFmpeg process error:', err);
    });
    
    ffmpeg.stderr.on('data', (data) => {
      const msg = data.toString();
      if (msg.includes('Error') || msg.includes('error')) {
        console.log(`FFmpeg: ${msg}`);
      }
    });
    
    // Create HTTP server to serve HLS content
    const httpServer = http.createServer((req, res) => {
      const url = new URL(req.url, 'http://localhost');
      let filePath;
      
      if (url.pathname === '/video') {
        filePath = path.join(tempDir, 'playlist.m3u8');
      } else if (url.pathname.includes('.ts')) {
        filePath = path.join(tempDir, path.basename(url.pathname));
      } else {
        // Serve an HTML page with video player
        res.writeHead(200, {'Content-Type': 'text/html'});
        // Update the HTML player section with low-latency settings
        res.end(`
            <!DOCTYPE html>
            <html>
            <head>
                <title>Live Stream Player</title>
                <script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
            </head>
            <body>
                <h1>Live Stream</h1>
                <video id="video" controls width="640" height="480"></video>
                <script>
                const video = document.getElementById('video');
                if(Hls.isSupported()) {
                    const hls = new Hls({
                    lowLatencyMode: true,
                    liveSyncDuration: 0.5,
                    liveMaxLatencyDuration: 2,
                    liveDurationInfinity: true,
                    enableWorker: true
                    });
                    hls.loadSource('/video');
                    hls.attachMedia(video);
                    hls.on(Hls.Events.MANIFEST_PARSED, function() {
                    video.play();
                    });
                }
                </script>
            </body>
            </html>
        `);
        return;
      }
      
      // Serve playlist or segment file
      try {
        if (fs.existsSync(filePath)) {
          const content = fs.readFileSync(filePath);
          const contentType = filePath.endsWith('.m3u8') ? 'application/vnd.apple.mpegurl' : 'video/MP2T';
          res.writeHead(200, {
            'Content-Type': contentType,
            'Access-Control-Allow-Origin': '*'
          });
          res.end(content);
        } else {
          res.writeHead(404);
          res.end('File not found');
        }
      } catch (err) {
        res.writeHead(500);
        res.end('Internal server error');
      }
    }).listen(9000);
    
    console.log('HTTP server for video streaming started on http://localhost:9000');
    
    ws.on('message', (data) => {
      try {
        if (ffmpeg.stdin.writable) {
          ffmpeg.stdin.write(data);
        }
      } catch (err) {
        console.error('Error writing to FFmpeg:', err);
      }
    });
    
    ws.on('close', () => {
      console.log('Browser disconnected');
      try {
        if (ffmpeg.stdin.writable) {
          ffmpeg.stdin.end();
        }
        
        // Clean up on disconnect
        setTimeout(() => {
          try {
            httpServer.close();
            fs.rmdirSync(tempDir, { recursive: true });
          } catch (err) {
            console.error('Error during cleanup:', err);
          }
        }, 5000); // Give time for any pending requests
      } catch (err) {
        console.error('Error cleaning up:', err);
      }
    });
    
  } catch (err) {
    console.error('Failed to start FFmpeg:', err);
    ws.close();
  }
});