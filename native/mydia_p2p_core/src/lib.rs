//! mydia_p2p_core - Iroh-based P2P networking for Mydia
//!
//! This crate provides the core P2P functionality using iroh for
//! NAT traversal and QUIC-based connections.

use iroh::{
    dns::DnsResolver,
    endpoint::{Connection, SendStream},
    Endpoint, EndpointAddr, EndpointId, RelayConfig, RelayMap, RelayMode, RelayUrl, SecretKey,
    Watcher,
};
#[cfg(feature = "dns-over-https")]
use iroh_relay::dns::DnsProtocol;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::OnceLock;
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, oneshot, Mutex};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter, Layer};

// Protocol identifier for mydia connections
const ALPN: &[u8] = b"/mydia/1.0.0";

// Request/Response Types (using Serde/CBOR)
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum MydiaRequest {
    Ping,
    Pairing(PairingRequest),
    ReadMedia(ReadMediaRequest),
    GraphQL(GraphQLRequest),
    HlsStream(HlsRequest),
    BlobDownload(BlobDownloadRequest),
    Custom(Vec<u8>),
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct PairingRequest {
    pub claim_code: String,
    pub device_name: String,
    pub device_type: String,
    pub device_os: Option<String>,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct ReadMediaRequest {
    pub file_path: String,
    pub offset: u64,
    pub length: u32,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct GraphQLRequest {
    pub query: String,
    pub variables: Option<String>, // JSON-encoded
    pub operation_name: Option<String>,
    pub auth_token: Option<String>, // Access token for authorization
}

/// HLS request for streaming manifests and segments over P2P
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct HlsRequest {
    pub session_id: String,
    pub path: String,             // "index.m3u8" or "segment_001.ts"
    pub range_start: Option<u64>, // For HTTP Range requests
    pub range_end: Option<u64>,
    pub auth_token: Option<String>,
}

/// HLS response header (sent first, then raw bytes stream)
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct HlsResponseHeader {
    pub status: u16,
    pub content_type: String,
    pub content_length: u64,
    pub content_range: Option<String>, // e.g., "bytes 0-1023/4096"
    pub cache_control: Option<String>,
}

/// Request to download a file as an iroh-blob
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct BlobDownloadRequest {
    pub job_id: String,
    pub auth_token: Option<String>,
}

/// Response with blob ticket for downloading
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct BlobDownloadResponse {
    pub success: bool,
    /// The iroh-blobs ticket as a serialized string
    pub ticket: Option<String>,
    /// Original filename for the downloaded file
    pub filename: Option<String>,
    /// File size in bytes
    pub file_size: Option<u64>,
    /// Error message if failed
    pub error: Option<String>,
}

/// Progress event for blob downloads
#[derive(Debug, Clone)]
pub enum BlobDownloadProgress {
    /// Download started with total size
    Started { total_size: u64 },
    /// Progress update with bytes downloaded
    Progress { downloaded: u64, total: u64 },
    /// Download completed with file path
    Completed { file_path: String },
    /// Download failed with error
    Failed { error: String },
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct GraphQLResponse {
    pub data: Option<String>,   // JSON-encoded
    pub errors: Option<String>, // JSON-encoded array
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum MydiaResponse {
    Pong,
    Pairing(PairingResponse),
    MediaChunk(Vec<u8>),
    GraphQL(GraphQLResponse),
    HlsHeader(HlsResponseHeader),
    BlobDownload(BlobDownloadResponse),
    Custom(Vec<u8>),
    Error(String),
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct PairingResponse {
    pub success: bool,
    pub media_token: Option<String>,
    pub access_token: Option<String>,
    pub device_token: Option<String>,
    pub error: Option<String>,
    #[serde(default)]
    pub direct_urls: Vec<String>,
}

/// Streaming response for HLS requests on client side
pub struct HlsStreamResponse {
    /// Response header
    pub header: HlsResponseHeader,
    /// Receiver for data chunks
    pub chunk_rx: mpsc::Receiver<Vec<u8>>,
}

/// Commands that can be sent to the Host
enum Command {
    Dial {
        endpoint_addr_json: String,
        reply: oneshot::Sender<Result<(), String>>,
    },
    SendRequest {
        node_id: String,
        request: MydiaRequest,
        reply: oneshot::Sender<Result<MydiaResponse, String>>,
    },
    SendResponse {
        request_id: String,
        response: MydiaResponse,
    },
    SendHlsHeader {
        stream_id: String,
        header: HlsResponseHeader,
        reply: oneshot::Sender<Result<(), String>>,
    },
    SendHlsChunk {
        stream_id: String,
        data: Vec<u8>,
        reply: oneshot::Sender<Result<(), String>>,
    },
    FinishHlsStream {
        stream_id: String,
        reply: oneshot::Sender<Result<(), String>>,
    },
    SendHlsRequest {
        node_id: String,
        request: HlsRequest,
        reply: oneshot::Sender<Result<HlsStreamResponse, String>>,
    },
    GetNodeAddr {
        reply: oneshot::Sender<String>,
    },
    GetNetworkStats {
        reply: oneshot::Sender<NetworkStats>,
    },
}

/// Events emitted by the Host
#[derive(Debug)]
pub enum Event {
    Connected {
        peer_id: String,
        connection_type: PeerConnectionType,
    },
    Disconnected(String),
    RequestReceived {
        peer: String,
        request: MydiaRequest,
        request_id: String,
    },
    /// HLS streaming request - requires streaming response via send_hls_header/chunk/finish
    HlsStreamRequest {
        peer: String,
        request: HlsRequest,
        stream_id: String,
    },
    /// Connection type changed (e.g. relay -> direct after hole-punching)
    ConnectionTypeChanged {
        peer_id: String,
        connection_type: PeerConnectionType,
    },
    RelayConnected,
    Ready {
        node_addr: String,
    },
    /// Log message from Rust/iroh
    Log {
        level: LogLevel,
        target: String,
        message: String,
    },
}

/// Log level for forwarded logs
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogLevel {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
}

impl From<tracing::Level> for LogLevel {
    fn from(level: tracing::Level) -> Self {
        match level {
            tracing::Level::TRACE => LogLevel::Trace,
            tracing::Level::DEBUG => LogLevel::Debug,
            tracing::Level::INFO => LogLevel::Info,
            tracing::Level::WARN => LogLevel::Warn,
            tracing::Level::ERROR => LogLevel::Error,
        }
    }
}

/// Connection type for a peer (relay vs direct)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PeerConnectionType {
    /// Direct peer-to-peer connection
    Direct,
    /// Connection via relay server
    Relay,
    /// Using both relay and direct paths
    Mixed,
    /// No active connection
    None,
}

impl PeerConnectionType {
    /// Determine connection type from a Connection's paths
    pub fn from_connection(conn: &Connection) -> Self {
        let mut paths = conn.paths();
        let paths_list = paths.get();
        if paths_list.is_empty() {
            return PeerConnectionType::None;
        }
        let has_relay = paths_list.iter().any(|p| p.is_relay());
        let has_direct = paths_list.iter().any(|p| p.is_ip());
        match (has_direct, has_relay) {
            (true, true) => PeerConnectionType::Mixed,
            (true, false) => PeerConnectionType::Direct,
            (false, true) => PeerConnectionType::Relay,
            (false, false) => PeerConnectionType::None,
        }
    }

    /// Return a string representation of the connection type
    pub fn as_str(&self) -> &'static str {
        match self {
            PeerConnectionType::Direct => "direct",
            PeerConnectionType::Relay => "relay",
            PeerConnectionType::Mixed => "mixed",
            PeerConnectionType::None => "none",
        }
    }
}

/// Global log channel for forwarding logs to Elixir
static LOG_TX: OnceLock<mpsc::Sender<Event>> = OnceLock::new();

/// Custom tracing layer that forwards logs to Elixir via the event channel
struct ElixirLogLayer;

impl<S> Layer<S> for ElixirLogLayer
where
    S: tracing::Subscriber,
{
    fn on_event(
        &self,
        event: &tracing::Event<'_>,
        _ctx: tracing_subscriber::layer::Context<'_, S>,
    ) {
        if let Some(tx) = LOG_TX.get() {
            // Extract message from event
            let mut message = String::new();
            let mut visitor = MessageVisitor(&mut message);
            event.record(&mut visitor);

            let log_event = Event::Log {
                level: (*event.metadata().level()).into(),
                target: event.metadata().target().to_string(),
                message,
            };

            // Non-blocking send - drop if channel is full
            let _ = tx.try_send(log_event);
        }
    }
}

/// Visitor to extract the message field from a tracing event
struct MessageVisitor<'a>(&'a mut String);

impl<'a> tracing::field::Visit for MessageVisitor<'a> {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            *self.0 = format!("{:?}", value);
        } else if self.0.is_empty() {
            // If no message field, use the first field
            *self.0 = format!("{}: {:?}", field.name(), value);
        }
    }

    fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
        if field.name() == "message" {
            *self.0 = value.to_string();
        } else if self.0.is_empty() {
            *self.0 = format!("{}: {}", field.name(), value);
        }
    }
}

/// Initialize tracing with the Elixir log layer
fn init_tracing(event_tx: mpsc::Sender<Event>) {
    // Only initialize once
    if LOG_TX.set(event_tx).is_err() {
        return;
    }

    // Set up tracing with env filter (default to info, but can be overridden with RUST_LOG)
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info,iroh=info,quinn=warn,rustls=warn"));

    let _ = tracing_subscriber::registry()
        .with(filter)
        .with(ElixirLogLayer)
        .try_init();
}

/// Network statistics
#[derive(Debug, Clone, Default)]
pub struct NetworkStats {
    pub connected_peers: usize,
    pub relay_connected: bool,
    /// The relay URL currently in use (None if using iroh defaults)
    pub relay_url: Option<String>,
    /// Connection type for the first connected peer (for UI display)
    pub peer_connection_type: PeerConnectionType,
}

impl Default for PeerConnectionType {
    fn default() -> Self {
        PeerConnectionType::None
    }
}

/// Configuration for the Host
#[derive(Clone, Default)]
pub struct HostConfig {
    /// Custom relay URL for NAT traversal. If None, uses iroh's default relays.
    pub relay_url: Option<String>,
    /// UDP port for direct connections. If None or 0, uses a random port.
    pub bind_port: Option<u16>,
    /// Path to store/load keypair (optional). If not set, a new random keypair is generated.
    pub keypair_path: Option<String>,
}

/// Load or generate an Ed25519 keypair for the node identity
fn load_or_generate_keypair(path: Option<&str>) -> SecretKey {
    if let Some(path) = path {
        if let Ok(bytes) = std::fs::read(path) {
            if bytes.len() == 32 {
                let mut arr = [0u8; 32];
                arr.copy_from_slice(&bytes);
                tracing::info!("Loaded keypair from {}", path);
                return SecretKey::from_bytes(&arr);
            }
        }
    }

    // Generate new
    let secret_key = SecretKey::generate(&mut rand::rng());

    // Save if path provided
    if let Some(path) = path {
        if let Err(e) = std::fs::write(path, secret_key.to_bytes()) {
            tracing::warn!("Failed to save keypair to {}: {}", path, e);
        } else {
            tracing::info!("Generated and saved new keypair to {}", path);
        }
    }

    secret_key
}

/// Serialize EndpointAddr to JSON for sharing
fn endpoint_addr_to_json(addr: &EndpointAddr) -> String {
    serde_json::to_string(addr).unwrap_or_default()
}

/// Deserialize EndpointAddr from JSON
fn endpoint_addr_from_json(json: &str) -> Result<EndpointAddr, String> {
    serde_json::from_str(json).map_err(|e| format!("Invalid EndpointAddr JSON: {}", e))
}

/// The core Host struct that manages the iroh Endpoint
pub struct Host {
    pub(crate) cmd_tx: mpsc::Sender<Command>,
    pub event_rx: Arc<Mutex<mpsc::Receiver<Event>>>,
    node_id: String,
}

impl Host {
    pub fn new(config: HostConfig) -> (Self, String) {
        let secret_key = load_or_generate_keypair(config.keypair_path.as_deref());
        let node_id = secret_key.public().to_string();
        let node_id_str = node_id.clone();

        let (cmd_tx, cmd_rx) = mpsc::channel::<Command>(32);
        let (event_tx, event_rx) = mpsc::channel::<Event>(100);

        // Spawn the event loop in a background thread with its own runtime
        std::thread::spawn(move || {
            let rt = Runtime::new().expect("Failed to create Tokio runtime");
            rt.block_on(run_event_loop(secret_key, config, cmd_rx, event_tx));
        });

        (
            Host {
                cmd_tx,
                event_rx: Arc::new(Mutex::new(event_rx)),
                node_id: node_id_str.clone(),
            },
            node_id_str,
        )
    }

    /// Dial a peer using their EndpointAddr JSON
    pub fn dial(&self, endpoint_addr_json: String) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.cmd_tx
            .blocking_send(Command::Dial {
                endpoint_addr_json,
                reply: tx,
            })
            .map_err(|_| "send_failed".to_string())?;
        rx.blocking_recv().map_err(|_| "recv_failed".to_string())?
    }

    /// Get this node's address as JSON for sharing
    pub fn get_node_addr(&self) -> String {
        let (tx, rx) = oneshot::channel();
        if self
            .cmd_tx
            .blocking_send(Command::GetNodeAddr { reply: tx })
            .is_err()
        {
            return String::new();
        }
        rx.blocking_recv().unwrap_or_default()
    }

    /// Send a request to a peer and wait for a response
    pub async fn send_request(
        &self,
        node_id: String,
        request: MydiaRequest,
    ) -> Result<MydiaResponse, String> {
        let (tx, rx) = oneshot::channel();
        self.cmd_tx
            .send(Command::SendRequest {
                node_id,
                request,
                reply: tx,
            })
            .await
            .map_err(|_| "send_failed".to_string())?;
        rx.await.map_err(|_| "recv_failed".to_string())?
    }

    /// Send a response to an incoming request
    pub fn send_response(&self, request_id: String, response: MydiaResponse) -> Result<(), String> {
        self.cmd_tx
            .blocking_send(Command::SendResponse {
                request_id,
                response,
            })
            .map_err(|_| "send_failed".to_string())
    }

    /// Send a response to an incoming request (async version)
    pub async fn send_response_async(
        &self,
        request_id: String,
        response: MydiaResponse,
    ) -> Result<(), String> {
        self.cmd_tx
            .send(Command::SendResponse {
                request_id,
                response,
            })
            .await
            .map_err(|_| "send_failed".to_string())
    }

    /// Get network statistics
    pub fn get_network_stats(&self) -> NetworkStats {
        let (tx, rx) = oneshot::channel();
        if self
            .cmd_tx
            .blocking_send(Command::GetNetworkStats { reply: tx })
            .is_err()
        {
            return NetworkStats::default();
        }
        rx.blocking_recv().unwrap_or_default()
    }

    /// Get this node's ID
    pub fn node_id(&self) -> &str {
        &self.node_id
    }

    /// Send an HLS response header for a streaming request.
    /// Must be called before any send_hls_chunk calls.
    pub fn send_hls_header(
        &self,
        stream_id: String,
        header: HlsResponseHeader,
    ) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.cmd_tx
            .blocking_send(Command::SendHlsHeader {
                stream_id,
                header,
                reply: tx,
            })
            .map_err(|_| "send_failed".to_string())?;
        rx.blocking_recv().map_err(|_| "recv_failed".to_string())?
    }

    /// Send a chunk of HLS data.
    /// Must be called after send_hls_header and before finish_hls_stream.
    pub fn send_hls_chunk(&self, stream_id: String, data: Vec<u8>) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.cmd_tx
            .blocking_send(Command::SendHlsChunk {
                stream_id,
                data,
                reply: tx,
            })
            .map_err(|_| "send_failed".to_string())?;
        rx.blocking_recv().map_err(|_| "recv_failed".to_string())?
    }

    /// Finish an HLS stream.
    /// Must be called after all chunks have been sent.
    pub fn finish_hls_stream(&self, stream_id: String) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.cmd_tx
            .blocking_send(Command::FinishHlsStream {
                stream_id,
                reply: tx,
            })
            .map_err(|_| "send_failed".to_string())?;
        rx.blocking_recv().map_err(|_| "recv_failed".to_string())?
    }

    /// Send an HLS streaming request to a peer (client-side).
    /// Returns a streaming response with header and chunk receiver.
    pub async fn send_hls_request(
        &self,
        node_id: String,
        request: HlsRequest,
    ) -> Result<HlsStreamResponse, String> {
        let (tx, rx) = oneshot::channel();
        self.cmd_tx
            .send(Command::SendHlsRequest {
                node_id,
                request,
                reply: tx,
            })
            .await
            .map_err(|_| "send_failed".to_string())?;
        rx.await.map_err(|_| "recv_failed".to_string())?
    }
}

/// Shared state for pending responses
struct SharedState {
    pending_responses: HashMap<String, oneshot::Sender<MydiaResponse>>,
    /// Active HLS streaming connections - stores the send half of the stream
    hls_streams: HashMap<String, SendStream>,
}

/// Create a DNS resolver, using DNS-over-HTTPS when the feature is enabled.
/// This is needed on Android where raw UDP/TCP DNS sockets are blocked by SELinux.
fn create_dns_resolver() -> DnsResolver {
    #[cfg(feature = "dns-over-https")]
    {
        tracing::info!("Using DNS-over-HTTPS resolver");
        DnsResolver::builder()
            .with_nameserver("8.8.8.8:443".parse().unwrap(), DnsProtocol::Https)
            .with_nameserver("1.1.1.1:443".parse().unwrap(), DnsProtocol::Https)
            .build()
    }
    #[cfg(not(feature = "dns-over-https"))]
    {
        DnsResolver::default()
    }
}

/// Main event loop that runs in a background thread
async fn run_event_loop(
    secret_key: SecretKey,
    config: HostConfig,
    mut cmd_rx: mpsc::Receiver<Command>,
    event_tx: mpsc::Sender<Event>,
) {
    // Initialize tracing to forward logs to Elixir
    init_tracing(event_tx.clone());

    // Build the endpoint
    let mut builder = Endpoint::builder()
        .secret_key(secret_key)
        .alpns(vec![ALPN.to_vec()])
        .dns_resolver(create_dns_resolver());

    // Configure relay
    if let Some(relay_url) = &config.relay_url {
        if let Ok(url) = relay_url.parse::<RelayUrl>() {
            builder = builder.relay_mode(RelayMode::Custom(RelayMap::from(RelayConfig {
                url,
                quic: None,
            })));
        }
    }

    // Configure bind port
    if let Some(port) = config.bind_port {
        if port > 0 {
            match builder.bind_addr(std::net::SocketAddrV4::new(
                std::net::Ipv4Addr::UNSPECIFIED,
                port,
            )) {
                Ok(b) => builder = b,
                Err(e) => {
                    tracing::error!("Failed to set bind address: {}", e);
                    return;
                }
            }
        }
    }

    let endpoint = match builder.bind().await {
        Ok(ep) => ep,
        Err(e) => {
            tracing::error!("Failed to bind iroh endpoint: {}", e);
            return;
        }
    };

    let endpoint_id = endpoint.id();
    tracing::info!("Iroh endpoint bound, endpoint_id: {}", endpoint_id);

    // Track state
    let mut connected_peers: HashMap<String, Connection> = HashMap::new();
    let shared_state = Arc::new(Mutex::new(SharedState {
        pending_responses: HashMap::new(),
        hls_streams: HashMap::new(),
    }));
    let mut relay_connected = false;

    // Wait for endpoint to be online (relay connected + local IP available)
    // Use a timeout to avoid blocking indefinitely if relay is unreachable
    tracing::info!("Waiting for relay connection...");
    match tokio::time::timeout(std::time::Duration::from_secs(30), endpoint.online()).await {
        Ok(()) => {
            relay_connected = true;
            tracing::info!("Relay connection established");
            let _ = event_tx.send(Event::RelayConnected).await;
        }
        Err(_) => {
            tracing::warn!("Relay connection timed out after 30s - continuing without relay");
        }
    }

    // Get endpoint address and emit Ready event
    let addr = endpoint.addr();
    let addr_json = endpoint_addr_to_json(&addr);
    let _ = event_tx
        .send(Event::Ready {
            node_addr: addr_json,
        })
        .await;

    loop {
        tokio::select! {
            // Handle incoming connections
            Some(incoming) = endpoint.accept() => {
                // Accept the connection
                let accepting = match incoming.accept() {
                    Ok(accepting) => accepting,
                    Err(e) => {
                        tracing::warn!("Failed to accept connection: {}", e);
                        continue;
                    }
                };

                // Check ALPN
                let mut accepting = accepting;
                let alpn = match accepting.alpn().await {
                    Ok(alpn) => alpn,
                    Err(e) => {
                        tracing::warn!("Failed to get ALPN: {}", e);
                        continue;
                    }
                };

                if alpn.as_slice() != ALPN {
                    tracing::warn!("Unknown ALPN: {:?}", alpn);
                    continue;
                }

                // Complete the connection
                let conn = match accepting.await {
                    Ok(conn) => conn,
                    Err(e) => {
                        tracing::warn!("Connection failed: {}", e);
                        continue;
                    }
                };

                let peer_id = conn.remote_id().to_string();
                let connection_type = PeerConnectionType::from_connection(&conn);
                tracing::info!("Peer connected: {} ({:?})", peer_id, connection_type);

                connected_peers.insert(peer_id.clone(), conn.clone());
                let _ = event_tx.send(Event::Connected {
                    peer_id: peer_id.clone(),
                    connection_type,
                }).await;

                // Spawn a task to handle incoming streams from this peer
                let event_tx_clone = event_tx.clone();
                let peer_id_clone = peer_id.clone();
                let shared_state_clone = shared_state.clone();
                let conn_clone = conn.clone();
                tokio::spawn(async move {
                    handle_connection(conn_clone, peer_id_clone, event_tx_clone, shared_state_clone).await;
                });

                // Monitor connection type changes (relay -> direct)
                let monitor_tx = event_tx.clone();
                tokio::spawn(async move {
                    monitor_connection_type(conn, peer_id, monitor_tx).await;
                });
            }

            // Handle commands
            Some(cmd) = cmd_rx.recv() => {
                match cmd {
                    Command::Dial { endpoint_addr_json, reply } => {
                        let result = handle_dial(&endpoint, &endpoint_addr_json, &mut connected_peers, &event_tx, &shared_state).await;
                        let _ = reply.send(result);
                    }
                    Command::SendRequest { node_id, request, reply } => {
                        let result = handle_send_request(&connected_peers, &node_id, request).await;
                        let _ = reply.send(result);
                    }
                    Command::SendResponse { request_id, response } => {
                        let mut state = shared_state.lock().await;
                        if let Some(tx) = state.pending_responses.remove(&request_id) {
                            let _ = tx.send(response);
                        }
                    }
                    Command::GetNodeAddr { reply } => {
                        let addr = endpoint.addr();
                        let addr_json = endpoint_addr_to_json(&addr);
                        let _ = reply.send(addr_json);
                    }
                    Command::GetNetworkStats { reply } => {
                        // Get the actual relay URL from the endpoint address
                        let addr = endpoint.addr();
                        let relay_url = addr.relay_urls().next().map(|u| u.to_string());

                        // Get connection type for the first connected peer
                        let peer_connection_type = if let Some((peer_key, conn)) = connected_peers.iter().next() {
                            let peer_id = conn.remote_id();
                            tracing::info!("GetNetworkStats: checking paths for peer {} (key={})", peer_id, peer_key);
                            let ct = PeerConnectionType::from_connection(conn);
                            tracing::info!("GetNetworkStats: connection type for {} = {:?}", peer_id, ct);
                            ct
                        } else {
                            tracing::info!("GetNetworkStats: no connected peers (map len={})", connected_peers.len());
                            PeerConnectionType::None
                        };

                        tracing::info!("GetNetworkStats: peers={}, relay_url={:?}, peer_conn_type={:?}",
                            connected_peers.len(), relay_url, peer_connection_type);
                        let stats = NetworkStats {
                            connected_peers: connected_peers.len(),
                            relay_connected,
                            relay_url,
                            peer_connection_type,
                        };
                        let _ = reply.send(stats);
                    }
                    Command::SendHlsHeader { stream_id, header, reply } => {
                        let result = {
                            let mut state = shared_state.lock().await;
                            if let Some(send) = state.hls_streams.get_mut(&stream_id) {
                                // First write the HlsHeader response
                                let header_response = MydiaResponse::HlsHeader(header);
                                match serde_cbor::to_vec(&header_response) {
                                    Ok(header_data) => {
                                        // Write length prefix (4 bytes) then header
                                        let len = header_data.len() as u32;
                                        let len_bytes = len.to_be_bytes();
                                        if let Err(e) = send.write(&len_bytes).await {
                                            Err(format!("Failed to write header length: {}", e))
                                        } else if let Err(e) = send.write(&header_data).await {
                                            Err(format!("Failed to write header: {}", e))
                                        } else {
                                            Ok(())
                                        }
                                    }
                                    Err(e) => Err(format!("Failed to encode header: {}", e)),
                                }
                            } else {
                                Err(format!("HLS stream not found: {}", stream_id))
                            }
                        };
                        let _ = reply.send(result);
                    }
                    Command::SendHlsChunk { stream_id, data, reply } => {
                        let result = {
                            let mut state = shared_state.lock().await;
                            if let Some(send) = state.hls_streams.get_mut(&stream_id) {
                                // Write chunk length (4 bytes) then data
                                let len = data.len() as u32;
                                let len_bytes = len.to_be_bytes();
                                if let Err(e) = send.write(&len_bytes).await {
                                    Err(format!("Failed to write chunk length: {}", e))
                                } else if let Err(e) = send.write(&data).await {
                                    Err(format!("Failed to write chunk: {}", e))
                                } else {
                                    Ok(())
                                }
                            } else {
                                Err(format!("HLS stream not found: {}", stream_id))
                            }
                        };
                        let _ = reply.send(result);
                    }
                    Command::FinishHlsStream { stream_id, reply } => {
                        let result = {
                            let mut state = shared_state.lock().await;
                            if let Some(mut send) = state.hls_streams.remove(&stream_id) {
                                // Write zero-length terminator
                                let zero_bytes = [0u8; 4];
                                if let Err(e) = send.write(&zero_bytes).await {
                                    Err(format!("Failed to write terminator: {}", e))
                                } else if let Err(e) = send.finish() {
                                    Err(format!("Failed to finish stream: {}", e))
                                } else {
                                    tracing::debug!("HLS stream {} finished", stream_id);
                                    Ok(())
                                }
                            } else {
                                Err(format!("HLS stream not found: {}", stream_id))
                            }
                        };
                        let _ = reply.send(result);
                    }
                    Command::SendHlsRequest { node_id, request, reply } => {
                        let result = handle_send_hls_request(&connected_peers, &node_id, request).await;
                        let _ = reply.send(result);
                    }
                }
            }

            else => break,
        }
    }

    tracing::info!("Event loop terminated");
}

/// Handle dialing a peer
async fn handle_dial(
    endpoint: &Endpoint,
    endpoint_addr_json: &str,
    connected_peers: &mut HashMap<String, Connection>,
    event_tx: &mpsc::Sender<Event>,
    shared_state: &Arc<Mutex<SharedState>>,
) -> Result<(), String> {
    let endpoint_addr = endpoint_addr_from_json(endpoint_addr_json)?;
    let endpoint_id: EndpointId = endpoint_addr.id;
    let node_id = endpoint_id.to_string();

    tracing::info!("Dialing peer: {}", node_id);

    let conn = endpoint
        .connect(endpoint_addr, ALPN)
        .await
        .map_err(|e| format!("Failed to connect: {}", e))?;

    let connection_type = PeerConnectionType::from_connection(&conn);
    tracing::info!("Connected to peer: {} ({:?})", node_id, connection_type);

    connected_peers.insert(node_id.clone(), conn.clone());
    let _ = event_tx.send(Event::Connected {
        peer_id: node_id.clone(),
        connection_type,
    }).await;

    // Spawn a task to handle incoming streams from this peer
    let event_tx_clone = event_tx.clone();
    let shared_state_clone = shared_state.clone();
    let conn_clone = conn.clone();
    let node_id_clone = node_id.clone();
    tokio::spawn(async move {
        handle_connection(conn_clone, node_id_clone, event_tx_clone, shared_state_clone).await;
    });

    // Monitor connection type changes (relay -> direct)
    let monitor_tx = event_tx.clone();
    tokio::spawn(async move {
        monitor_connection_type(conn, node_id, monitor_tx).await;
    });

    Ok(())
}

/// Monitor a peer connection for type changes (e.g. relay -> direct after hole-punching).
/// Checks every 5 seconds for up to 2 minutes, then stops.
async fn monitor_connection_type(
    conn: Connection,
    peer_id: String,
    event_tx: mpsc::Sender<Event>,
) {
    let mut current_type = PeerConnectionType::from_connection(&conn);

    // Check for connection type changes for up to 2 minutes
    // (hole-punching typically completes within this window)
    for _ in 0..24 {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        let new_type = PeerConnectionType::from_connection(&conn);
        if new_type != current_type {
            tracing::info!(
                "Connection type changed for {}: {:?} -> {:?}",
                peer_id,
                current_type,
                new_type
            );
            let _ = event_tx
                .send(Event::ConnectionTypeChanged {
                    peer_id: peer_id.clone(),
                    connection_type: new_type,
                })
                .await;
            current_type = new_type;

            // If we reached Direct, no need to keep monitoring
            if new_type == PeerConnectionType::Direct {
                break;
            }
        }
    }
}

/// Handle incoming streams from a peer connection
async fn handle_connection(
    conn: Connection,
    peer_id: String,
    event_tx: mpsc::Sender<Event>,
    shared_state: Arc<Mutex<SharedState>>,
) {
    loop {
        match conn.accept_bi().await {
            Ok((send, mut recv)) => {
                let request_id = uuid::Uuid::new_v4().to_string();

                // Read the request
                let data = match recv.read_to_end(64 * 1024).await {
                    Ok(data) => data,
                    Err(e) => {
                        tracing::warn!("Failed to read request from {}: {}", peer_id, e);
                        continue;
                    }
                };

                let request: MydiaRequest = match serde_cbor::from_slice(&data) {
                    Ok(req) => req,
                    Err(e) => {
                        tracing::warn!("Failed to decode request from {}: {}", peer_id, e);
                        continue;
                    }
                };

                tracing::debug!("Received request from {}: {:?}", peer_id, request);

                // For Ping requests, respond immediately
                if matches!(request, MydiaRequest::Ping) {
                    let mut send = send;
                    let response = MydiaResponse::Pong;
                    if let Ok(response_data) = serde_cbor::to_vec(&response) {
                        let _ = send.write_all(&response_data).await;
                        let _ = send.finish();
                    }
                    continue;
                }

                // For HLS streaming requests, store the send stream and emit event
                if let MydiaRequest::HlsStream(hls_request) = request {
                    let stream_id = request_id.clone();
                    tracing::debug!(
                        "HLS stream request: session={}, path={}",
                        hls_request.session_id,
                        hls_request.path
                    );

                    // Store the send stream for later use
                    {
                        let mut state = shared_state.lock().await;
                        state.hls_streams.insert(stream_id.clone(), send);
                    }

                    // Emit the HLS stream event
                    let _ = event_tx
                        .send(Event::HlsStreamRequest {
                            peer: peer_id.clone(),
                            request: hls_request,
                            stream_id,
                        })
                        .await;

                    continue;
                }

                // For all other requests, use the standard request/response pattern
                let mut send = send;

                // Create a oneshot channel for the response
                let (resp_tx, resp_rx) = oneshot::channel::<MydiaResponse>();

                // Store the response sender
                {
                    let mut state = shared_state.lock().await;
                    state.pending_responses.insert(request_id.clone(), resp_tx);
                }

                // Emit the request event
                let _ = event_tx
                    .send(Event::RequestReceived {
                        peer: peer_id.clone(),
                        request,
                        request_id: request_id.clone(),
                    })
                    .await;

                // Wait for the response and send it
                let request_id_clone = request_id.clone();
                tokio::spawn(async move {
                    match tokio::time::timeout(std::time::Duration::from_secs(30), resp_rx).await {
                        Ok(Ok(response)) => {
                            if let Ok(response_data) = serde_cbor::to_vec(&response) {
                                let _ = send.write_all(&response_data).await;
                                let _ = send.finish();
                            }
                        }
                        Ok(Err(_)) => {
                            tracing::warn!(
                                "Response channel closed for request {}",
                                request_id_clone
                            );
                        }
                        Err(_) => {
                            tracing::warn!("Response timeout for request {}", request_id_clone);
                            let error_response =
                                MydiaResponse::Error("Request timeout".to_string());
                            if let Ok(response_data) = serde_cbor::to_vec(&error_response) {
                                let _ = send.write_all(&response_data).await;
                                let _ = send.finish();
                            }
                        }
                    }
                });
            }
            Err(e) => {
                tracing::info!("Connection closed for peer {}: {}", peer_id, e);
                let _ = event_tx.send(Event::Disconnected(peer_id)).await;
                break;
            }
        }
    }
}

/// Send a request to a connected peer
async fn handle_send_request(
    connected_peers: &HashMap<String, Connection>,
    node_id: &str,
    request: MydiaRequest,
) -> Result<MydiaResponse, String> {
    // The node_id parameter might be either:
    // 1. A bare node ID string (e.g., "09ecb63dd2...")
    // 2. A full EndpointAddr JSON (e.g., {"id":"09ecb63dd2...", ...})
    // We need to extract the actual node ID in both cases.
    let actual_node_id = if node_id.starts_with('{') {
        // Try to parse as EndpointAddr JSON
        match endpoint_addr_from_json(node_id) {
            Ok(addr) => addr.id.to_string(),
            Err(_) => node_id.to_string(),
        }
    } else {
        node_id.to_string()
    };

    let conn = connected_peers
        .get(&actual_node_id)
        .ok_or_else(|| format!("Not connected to peer: {}", actual_node_id))?;

    // Open a bidirectional stream
    let (mut send, mut recv) = conn
        .open_bi()
        .await
        .map_err(|e| format!("Failed to open stream: {}", e))?;

    // Send the request
    let request_data =
        serde_cbor::to_vec(&request).map_err(|e| format!("Failed to encode request: {}", e))?;

    send.write_all(&request_data)
        .await
        .map_err(|e| format!("Failed to send request: {}", e))?;

    send.finish()
        .map_err(|e| format!("Failed to finish send: {}", e))?;

    // Read the response
    let response_data = recv
        .read_to_end(64 * 1024)
        .await
        .map_err(|e| format!("Failed to read response: {}", e))?;

    let response: MydiaResponse = serde_cbor::from_slice(&response_data)
        .map_err(|e| format!("Failed to decode response: {}", e))?;

    Ok(response)
}

/// Send an HLS streaming request to a connected peer (client-side).
/// Returns a streaming response with header and channel for chunks.
async fn handle_send_hls_request(
    connected_peers: &HashMap<String, Connection>,
    node_id: &str,
    request: HlsRequest,
) -> Result<HlsStreamResponse, String> {
    // Handle both bare node ID and full EndpointAddr JSON
    let actual_node_id = if node_id.starts_with('{') {
        match endpoint_addr_from_json(node_id) {
            Ok(addr) => addr.id.to_string(),
            Err(_) => node_id.to_string(),
        }
    } else {
        node_id.to_string()
    };

    let conn = connected_peers
        .get(&actual_node_id)
        .ok_or_else(|| format!("Not connected to peer: {}", actual_node_id))?;

    // Open a bidirectional stream
    let (mut send, mut recv) = conn
        .open_bi()
        .await
        .map_err(|e| format!("Failed to open stream: {}", e))?;

    // Send the request
    let request = MydiaRequest::HlsStream(request);
    let request_data =
        serde_cbor::to_vec(&request).map_err(|e| format!("Failed to encode request: {}", e))?;

    send.write_all(&request_data)
        .await
        .map_err(|e| format!("Failed to send request: {}", e))?;

    send.finish()
        .map_err(|e| format!("Failed to finish send: {}", e))?;

    // Read the header (length-prefixed)
    let mut len_buf = [0u8; 4];
    recv.read_exact(&mut len_buf)
        .await
        .map_err(|e| format!("Failed to read header length: {}", e))?;
    let header_len = u32::from_be_bytes(len_buf) as usize;

    if header_len == 0 {
        return Err("Empty header received".to_string());
    }

    let mut header_data = vec![0u8; header_len];
    recv.read_exact(&mut header_data)
        .await
        .map_err(|e| format!("Failed to read header: {}", e))?;

    let header_response: MydiaResponse = serde_cbor::from_slice(&header_data)
        .map_err(|e| format!("Failed to decode header: {}", e))?;

    let header = match header_response {
        MydiaResponse::HlsHeader(h) => h,
        MydiaResponse::Error(e) => return Err(format!("Server error: {}", e)),
        _ => return Err("Unexpected response type".to_string()),
    };

    // Create a channel for streaming chunks
    let (chunk_tx, chunk_rx) = mpsc::channel::<Vec<u8>>(16);

    // Spawn a task to read chunks and send them through the channel
    tokio::spawn(async move {
        loop {
            // Read chunk length
            let mut len_buf = [0u8; 4];
            if let Err(e) = recv.read_exact(&mut len_buf).await {
                tracing::debug!("HLS chunk read completed or error: {}", e);
                break;
            }
            let chunk_len = u32::from_be_bytes(len_buf) as usize;

            // Zero length indicates end of stream
            if chunk_len == 0 {
                tracing::debug!("HLS stream end marker received");
                break;
            }

            // Read the chunk
            let mut chunk_data = vec![0u8; chunk_len];
            if let Err(e) = recv.read_exact(&mut chunk_data).await {
                tracing::error!("Failed to read chunk data: {}", e);
                break;
            }

            // Send chunk through channel
            if chunk_tx.send(chunk_data).await.is_err() {
                tracing::debug!("HLS chunk receiver dropped");
                break;
            }
        }
    });

    Ok(HlsStreamResponse { header, chunk_rx })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_request_serialization() {
        let request = MydiaRequest::Ping;
        let data = serde_cbor::to_vec(&request).unwrap();
        let decoded: MydiaRequest = serde_cbor::from_slice(&data).unwrap();
        assert_eq!(request, decoded);
    }

    #[test]
    fn test_pairing_request_serialization() {
        let request = MydiaRequest::Pairing(PairingRequest {
            claim_code: "ABC123".to_string(),
            device_name: "Test Device".to_string(),
            device_type: "mobile".to_string(),
            device_os: Some("Android".to_string()),
        });
        let data = serde_cbor::to_vec(&request).unwrap();
        let decoded: MydiaRequest = serde_cbor::from_slice(&data).unwrap();
        assert_eq!(request, decoded);
    }

    #[test]
    fn test_response_serialization() {
        let response = MydiaResponse::Pairing(PairingResponse {
            success: true,
            media_token: Some("token123".to_string()),
            access_token: Some("access456".to_string()),
            device_token: Some("device789".to_string()),
            error: None,
            direct_urls: vec![],
        });
        let data = serde_cbor::to_vec(&response).unwrap();
        let decoded: MydiaResponse = serde_cbor::from_slice(&data).unwrap();
        assert_eq!(response, decoded);
    }

    #[test]
    fn test_graphql_request_serialization() {
        let request = MydiaRequest::GraphQL(GraphQLRequest {
            query: "query { movies { id title } }".to_string(),
            variables: Some(r#"{"limit": 10}"#.to_string()),
            operation_name: Some("GetMovies".to_string()),
            auth_token: Some("test_token_123".to_string()),
        });
        let data = serde_cbor::to_vec(&request).unwrap();
        let decoded: MydiaRequest = serde_cbor::from_slice(&data).unwrap();
        assert_eq!(request, decoded);
    }

    #[test]
    fn test_graphql_response_serialization() {
        let response = MydiaResponse::GraphQL(GraphQLResponse {
            data: Some(r#"{"movies": [{"id": "1", "title": "Test"}]}"#.to_string()),
            errors: None,
        });
        let data = serde_cbor::to_vec(&response).unwrap();
        let decoded: MydiaResponse = serde_cbor::from_slice(&data).unwrap();
        assert_eq!(response, decoded);
    }

    #[test]
    fn test_graphql_response_with_errors() {
        let response = MydiaResponse::GraphQL(GraphQLResponse {
            data: None,
            errors: Some(r#"[{"message": "Not found"}]"#.to_string()),
        });
        let data = serde_cbor::to_vec(&response).unwrap();
        let decoded: MydiaResponse = serde_cbor::from_slice(&data).unwrap();
        assert_eq!(response, decoded);
    }

    #[test]
    fn test_hls_request_serialization() {
        let request = MydiaRequest::HlsStream(HlsRequest {
            session_id: "session_123".to_string(),
            path: "index.m3u8".to_string(),
            range_start: None,
            range_end: None,
            auth_token: Some("token_abc".to_string()),
        });
        let data = serde_cbor::to_vec(&request).unwrap();
        let decoded: MydiaRequest = serde_cbor::from_slice(&data).unwrap();
        assert_eq!(request, decoded);
    }

    #[test]
    fn test_hls_request_with_range() {
        let request = MydiaRequest::HlsStream(HlsRequest {
            session_id: "session_456".to_string(),
            path: "segment_001.ts".to_string(),
            range_start: Some(0),
            range_end: Some(1023),
            auth_token: None,
        });
        let data = serde_cbor::to_vec(&request).unwrap();
        let decoded: MydiaRequest = serde_cbor::from_slice(&data).unwrap();
        assert_eq!(request, decoded);
    }

    #[test]
    fn test_hls_response_header_serialization() {
        let response = MydiaResponse::HlsHeader(HlsResponseHeader {
            status: 200,
            content_type: "application/vnd.apple.mpegurl".to_string(),
            content_length: 1024,
            content_range: None,
            cache_control: Some("max-age=3600".to_string()),
        });
        let data = serde_cbor::to_vec(&response).unwrap();
        let decoded: MydiaResponse = serde_cbor::from_slice(&data).unwrap();
        assert_eq!(response, decoded);
    }

    #[test]
    fn test_hls_response_header_with_range() {
        let response = MydiaResponse::HlsHeader(HlsResponseHeader {
            status: 206,
            content_type: "video/mp2t".to_string(),
            content_length: 1024,
            content_range: Some("bytes 0-1023/4096".to_string()),
            cache_control: None,
        });
        let data = serde_cbor::to_vec(&response).unwrap();
        let decoded: MydiaResponse = serde_cbor::from_slice(&data).unwrap();
        assert_eq!(response, decoded);
    }

    #[test]
    fn test_blob_download_request_serialization() {
        let request = MydiaRequest::BlobDownload(BlobDownloadRequest {
            job_id: "job_123".to_string(),
            auth_token: Some("token_abc".to_string()),
        });
        let data = serde_cbor::to_vec(&request).unwrap();
        let decoded: MydiaRequest = serde_cbor::from_slice(&data).unwrap();
        assert_eq!(request, decoded);
    }

    #[test]
    fn test_blob_download_response_serialization() {
        let response = MydiaResponse::BlobDownload(BlobDownloadResponse {
            success: true,
            ticket: Some("blob_ticket_xyz".to_string()),
            filename: Some("movie.mp4".to_string()),
            file_size: Some(1024 * 1024 * 100),
            error: None,
        });
        let data = serde_cbor::to_vec(&response).unwrap();
        let decoded: MydiaResponse = serde_cbor::from_slice(&data).unwrap();
        assert_eq!(response, decoded);
    }

    #[test]
    fn test_blob_download_response_error_serialization() {
        let response = MydiaResponse::BlobDownload(BlobDownloadResponse {
            success: false,
            ticket: None,
            filename: None,
            file_size: None,
            error: Some("Job not found".to_string()),
        });
        let data = serde_cbor::to_vec(&response).unwrap();
        let decoded: MydiaResponse = serde_cbor::from_slice(&data).unwrap();
        assert_eq!(response, decoded);
    }
}
