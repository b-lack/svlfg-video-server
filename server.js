const RtspServer = require('rtsp-streaming-server').default;

const server = new RtspServer({
    serverPort: 5554,
    clientPort: 6554,
    rtpPortStart: 10000,
    rtpPortCount: 10000,
    // Add event handlers via configuration
    events: {
        onMount: (id, mountPath) => {
            console.log(`New stream mounted at path: ${mountPath}, with ID: ${id}`);
        },
        onClientConnect: (id, mountPath) => {
            console.log(`Client connected to stream at path: ${mountPath}, with ID: ${id}`);
        },
        onData: (data, channel) => {
            // Process incoming data here
            console.log(`Received data on channel: ${channel}, size: ${data.length} bytes`);
        }
    }
});

async function run () {
	try {
		await server.start();
        console.log('RTSP server started on rtsp://localhost:5554');
	} catch (e) {
		console.error(e);
	}
}

run();


//  Publishing: rtsp://localhost:5554/live/stream1
//  Consuming: rtsp://localhost:6554/live/stream1