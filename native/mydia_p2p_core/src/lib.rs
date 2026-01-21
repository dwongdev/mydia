//! mydia_p2p_core - Iroh-based P2P networking for Mydia
//!
//! This crate provides the core P2P functionality using iroh for
//! NAT traversal and QUIC-based connections.

use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayConfig, RelayMap, RelayMode, RelayUrl, SecretKey,
    endpoint::Connection,
};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, oneshot, Mutex};

// Protocol identifier for mydia connections
const ALPN: &[u8] = b"/mydia/1.0.0";

// Request/Response Types (using Serde/CBOR)
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum MydiaRequest {
    Ping,
    Pairing(PairingRequest),
    ReadMedia(ReadMediaRequest),
    GraphQL(GraphQLRequest),
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
    pub variables: Option<String>,      // JSON-encoded
    pub operation_name: Option<String>,
    pub auth_token: Option<String>,     // Access token for authorization
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
    Connected(String),
    Disconnected(String),
    RequestReceived {
        peer: String,
        request: MydiaRequest,
        request_id: String,
    },
    RelayConnected,
    Ready {
        node_addr: String,
    },
}

/// Network statistics
#[derive(Debug, Clone, Default)]
pub struct NetworkStats {
    pub connected_peers: usize,
    pub relay_connected: bool,
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
                log::info!("Loaded keypair from {}", path);
                return SecretKey::from_bytes(&arr);
            }
        }
    }

    // Generate new
    let secret_key = SecretKey::generate(&mut rand::rng());

    // Save if path provided
    if let Some(path) = path {
        if let Err(e) = std::fs::write(path, secret_key.to_bytes()) {
            log::warn!("Failed to save keypair to {}: {}", path, e);
        } else {
            log::info!("Generated and saved new keypair to {}", path);
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
    cmd_tx: mpsc::Sender<Command>,
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
        if self.cmd_tx.blocking_send(Command::GetNodeAddr { reply: tx }).is_err() {
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
        if self.cmd_tx.blocking_send(Command::GetNetworkStats { reply: tx }).is_err() {
            return NetworkStats::default();
        }
        rx.blocking_recv().unwrap_or_default()
    }

    /// Get this node's ID
    pub fn node_id(&self) -> &str {
        &self.node_id
    }
}

/// Shared state for pending responses
struct SharedState {
    pending_responses: HashMap<String, oneshot::Sender<MydiaResponse>>,
}

/// Main event loop that runs in a background thread
async fn run_event_loop(
    secret_key: SecretKey,
    config: HostConfig,
    mut cmd_rx: mpsc::Receiver<Command>,
    event_tx: mpsc::Sender<Event>,
) {
    // Build the endpoint
    let mut builder = Endpoint::builder()
        .secret_key(secret_key)
        .alpns(vec![ALPN.to_vec()]);

    // Configure relay
    if let Some(relay_url) = &config.relay_url {
        if let Ok(url) = relay_url.parse::<RelayUrl>() {
            builder = builder.relay_mode(RelayMode::Custom(
                RelayMap::from(RelayConfig {
                    url,
                    quic: None,
                })
            ));
        }
    }

    // Configure bind port
    if let Some(port) = config.bind_port {
        if port > 0 {
            builder = builder.bind_addr_v4(std::net::SocketAddrV4::new(
                std::net::Ipv4Addr::UNSPECIFIED,
                port,
            ));
        }
    }

    let endpoint = match builder.bind().await {
        Ok(ep) => ep,
        Err(e) => {
            log::error!("Failed to bind iroh endpoint: {}", e);
            return;
        }
    };

    let endpoint_id = endpoint.id();
    log::info!("Iroh endpoint bound, endpoint_id: {}", endpoint_id);

    // Track state
    let mut connected_peers: HashMap<String, Connection> = HashMap::new();
    let shared_state = Arc::new(Mutex::new(SharedState {
        pending_responses: HashMap::new(),
    }));
    let mut relay_connected = false;

    // Get initial endpoint address and emit Ready event
    let addr = endpoint.addr();
    let addr_json = endpoint_addr_to_json(&addr);
    let _ = event_tx.send(Event::Ready { node_addr: addr_json }).await;

    // Check relay status - if we have relay addresses, we're connected
    if addr.relay_urls().next().is_some() {
        relay_connected = true;
        let _ = event_tx.send(Event::RelayConnected).await;
    }

    loop {
        tokio::select! {
            // Handle incoming connections
            Some(incoming) = endpoint.accept() => {
                // Accept the connection
                let accepting = match incoming.accept() {
                    Ok(accepting) => accepting,
                    Err(e) => {
                        log::warn!("Failed to accept connection: {}", e);
                        continue;
                    }
                };

                // Check ALPN
                let mut accepting = accepting;
                let alpn = match accepting.alpn().await {
                    Ok(alpn) => alpn,
                    Err(e) => {
                        log::warn!("Failed to get ALPN: {}", e);
                        continue;
                    }
                };

                if alpn.as_slice() != ALPN {
                    log::warn!("Unknown ALPN: {:?}", alpn);
                    continue;
                }

                // Complete the connection
                let conn = match accepting.await {
                    Ok(conn) => conn,
                    Err(e) => {
                        log::warn!("Connection failed: {}", e);
                        continue;
                    }
                };

                let peer_id = conn.remote_id().to_string();
                log::info!("Peer connected: {}", peer_id);

                connected_peers.insert(peer_id.clone(), conn.clone());
                let _ = event_tx.send(Event::Connected(peer_id.clone())).await;

                // Spawn a task to handle incoming streams from this peer
                let event_tx_clone = event_tx.clone();
                let peer_id_clone = peer_id.clone();
                let shared_state_clone = shared_state.clone();
                tokio::spawn(async move {
                    handle_connection(conn, peer_id_clone, event_tx_clone, shared_state_clone).await;
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
                        let stats = NetworkStats {
                            connected_peers: connected_peers.len(),
                            relay_connected,
                        };
                        let _ = reply.send(stats);
                    }
                }
            }

            else => break,
        }
    }

    log::info!("Event loop terminated");
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

    log::info!("Dialing peer: {}", node_id);

    let conn = endpoint
        .connect(endpoint_addr, ALPN)
        .await
        .map_err(|e| format!("Failed to connect: {}", e))?;

    log::info!("Connected to peer: {}", node_id);

    connected_peers.insert(node_id.clone(), conn.clone());
    let _ = event_tx.send(Event::Connected(node_id.clone())).await;

    // Spawn a task to handle incoming streams from this peer
    let event_tx_clone = event_tx.clone();
    let shared_state_clone = shared_state.clone();
    tokio::spawn(async move {
        handle_connection(conn, node_id, event_tx_clone, shared_state_clone).await;
    });

    Ok(())
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
            Ok((mut send, mut recv)) => {
                let request_id = uuid::Uuid::new_v4().to_string();

                // Read the request
                let data = match recv.read_to_end(64 * 1024).await {
                    Ok(data) => data,
                    Err(e) => {
                        log::warn!("Failed to read request from {}: {}", peer_id, e);
                        continue;
                    }
                };

                let request: MydiaRequest = match serde_cbor::from_slice(&data) {
                    Ok(req) => req,
                    Err(e) => {
                        log::warn!("Failed to decode request from {}: {}", peer_id, e);
                        continue;
                    }
                };

                log::debug!("Received request from {}: {:?}", peer_id, request);

                // For Ping requests, respond immediately
                if matches!(request, MydiaRequest::Ping) {
                    let response = MydiaResponse::Pong;
                    if let Ok(response_data) = serde_cbor::to_vec(&response) {
                        let _ = send.write_all(&response_data).await;
                        let _ = send.finish();
                    }
                    continue;
                }

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
                            log::warn!("Response channel closed for request {}", request_id_clone);
                        }
                        Err(_) => {
                            log::warn!("Response timeout for request {}", request_id_clone);
                            let error_response = MydiaResponse::Error("Request timeout".to_string());
                            if let Ok(response_data) = serde_cbor::to_vec(&error_response) {
                                let _ = send.write_all(&response_data).await;
                                let _ = send.finish();
                            }
                        }
                    }
                });
            }
            Err(e) => {
                log::info!("Connection closed for peer {}: {}", peer_id, e);
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
    let conn = connected_peers
        .get(node_id)
        .ok_or_else(|| format!("Not connected to peer: {}", node_id))?;

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
}
