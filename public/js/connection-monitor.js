/**
 * WebRTC Connection Monitor
 * 
 * This script helps monitor and optimize WebRTC connections to prevent
 * degradation over time.
 */

class ConnectionMonitor {
  constructor(peerConnection, socket, options = {}) {
    this.pc = peerConnection;
    this.socket = socket;
    this.options = {
      statsInterval: 3000,
      lowBandwidthThreshold: 100000, // 100 Kbps
      ...options
    };
    
    this.statsInterval = null;
    this.lastBitrate = 0;
    this.bitrateHistory = [];
    
    // Handle pings from server
    this.socket.on('ping', () => {
      this.socket.emit('pong');
    });
    
    // Handle connection timeout
    this.socket.on('connection_timeout', () => {
      console.warn('Connection timed out, refreshing...');
      window.location.reload();
    });
    
    // Handle if we're replaced as a broadcaster
    this.socket.on('broadcaster_replaced', () => {
      console.warn('You have been replaced as the broadcaster');
      // Optional: reload or show message to user
    });
  }
  
  start() {
    // Start monitoring stats
    this.statsInterval = setInterval(() => this.gatherStats(), this.options.statsInterval);
    return this;
  }
  
  stop() {
    if (this.statsInterval) {
      clearInterval(this.statsInterval);
      this.statsInterval = null;
    }
  }
  
  async gatherStats() {
    if (!this.pc) return;
    
    try {
      const stats = await this.pc.getStats();
      let videoStat = null;
      let audioStat = null;
      let connectionStat = null;
      
      stats.forEach(stat => {
        if (stat.type === 'outbound-rtp' && stat.kind === 'video') {
          videoStat = stat;
        } else if (stat.type === 'outbound-rtp' && stat.kind === 'audio') {
          audioStat = stat;
        } else if (stat.type === 'transport') {
          connectionStat = stat;
        }
      });
      
      if (videoStat && this.lastBitrate) {
        const bitrate = 8 * (videoStat.bytesSent - this.lastBitrate.bytesSent) / 
                         ((videoStat.timestamp - this.lastBitrate.timestamp) / 1000);
        
        this.bitrateHistory.push(bitrate);
        if (this.bitrateHistory.length > 30) this.bitrateHistory.shift();
        
        const avgBitrate = this.bitrateHistory.reduce((a, b) => a + b, 0) / this.bitrateHistory.length;
        
        console.log(`Video bitrate: ${Math.round(bitrate / 1000)} Kbps (avg: ${Math.round(avgBitrate / 1000)} Kbps)`);
        
        // Report stats to server
        this.socket.emit('connection_stats', {
          bitrate,
          avgBitrate,
          bytesSent: videoStat.bytesSent,
          packetsLost: videoStat.packetsLost,
          frameRate: videoStat.framesPerSecond || 0
        });
        
        // Check for low bandwidth and reduce quality if needed
        if (avgBitrate < this.options.lowBandwidthThreshold && window.localStream) {
          this.adjustQuality(avgBitrate);
        }
      }
      
      if (videoStat) {
        this.lastBitrate = videoStat;
      }
      
    } catch (err) {
      console.error('Error getting WebRTC stats:', err);
    }
  }
  
  adjustQuality(currentBitrate) {
    // If we have access to the local stream, we can adjust video quality
    if (!window.localStream) return;
    
    const videoTrack = window.localStream.getVideoTracks()[0];
    if (!videoTrack) return;
    
    try {
      const constraints = videoTrack.getConstraints();
      let newConstraints = { ...constraints };
      
      // Very low bandwidth - drastically reduce quality
      if (currentBitrate < 50000) { // Less than 50 Kbps
        newConstraints.width = { ideal: 320 };
        newConstraints.height = { ideal: 240 };
        newConstraints.frameRate = { ideal: 10 };
      } 
      // Low bandwidth - reduce quality
      else if (currentBitrate < 200000) { // Less than 200 Kbps
        newConstraints.width = { ideal: 640 };
        newConstraints.height = { ideal: 480 };
        newConstraints.frameRate = { ideal: 15 };
      }
      
      videoTrack.applyConstraints(newConstraints)
        .then(() => console.log('Adjusted video quality to match bandwidth'))
        .catch(err => console.error('Failed to adjust video quality:', err));
        
    } catch (err) {
      console.error('Error adjusting video quality:', err);
    }
  }
}

// Make available globally
window.ConnectionMonitor = ConnectionMonitor;
