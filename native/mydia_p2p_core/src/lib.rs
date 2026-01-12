use libp2p::{
    identity,
    ping,
    mdns,
    kad,
    noise,
    tcp,
    yamux,
    relay,
    dcutr,
    request_response::{self, ProtocolSupport, OutboundRequestId},
    PeerId,
    SwarmBuilder,
    Multiaddr,
    swarm::{NetworkBehaviour, SwarmEvent, Config as SwarmConfig},
};
use std::time::Duration;
use std::collections::HashMap;
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, oneshot};
use libp2p::futures::StreamExt;
use sha2::{Sha256, Digest};

// Define the Network Behaviour
#[derive(NetworkBehaviour)]
pub struct MydiaBehaviour {
    ping: ping::Behaviour,
    mdns: mdns::tokio::Behaviour,
    kad: kad::Behaviour<kad::store::MemoryStore>,
    request_response: request_response::cbor::Behaviour<MydiaRequest, MydiaResponse>,
    relay_client: relay::client::Behaviour,
    dcutr: dcutr::Behaviour,
    relay_server: relay::Behaviour,
}

// Request/Response Types (using Serde/CBOR)
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum MydiaRequest {
    Ping,
    Pairing(PairingRequest),
    ReadMedia(ReadMediaRequest),
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
pub enum MydiaResponse {
    Pong,
    Pairing(PairingResponse),
    MediaChunk(Vec<u8>),
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

// Commands that can be sent to the Host
pub enum Command {
    Listen(String),
    Dial(String),
    Bootstrap(String), // Add a bootstrap peer address
    SendRequest { 
        peer: String, 
        request: MydiaRequest, 
        reply: oneshot::Sender<Result<MydiaResponse, String>> 
    },
    SendResponse { request_id: String, response: MydiaResponse },
    // DHT commands for claim code discovery
    ProvideClaimCode { 
        claim_code: String,
        reply: oneshot::Sender<Result<(), String>>,
    },
    LookupClaimCode { 
        claim_code: String,
        reply: oneshot::Sender<Result<LookupResult, String>>,
    },
    // Get DHT statistics
    GetDhtStats {
        reply: oneshot::Sender<DhtStats>,
    },
}

/// Result of a DHT lookup for a claim code
#[derive(Debug, Clone)]
pub struct LookupResult {
    pub peer_id: String,
    pub addresses: Vec<String>,
}

/// DHT statistics
#[derive(Debug, Clone)]
pub struct DhtStats {
    pub routing_table_size: usize,
    pub provided_keys_count: usize,
    pub bootstrap_complete: bool,
}

// Events emitted by the Host
#[derive(Debug)]
pub enum Event {
    PeerDiscovered(String),
    PeerExpired(String),
    RequestReceived { 
        peer: String, 
        request: MydiaRequest, 
        request_id: String,
    },
    BootstrapCompleted,
}

/// Converts a claim code to a Kademlia record key using SHA256 hash
fn claim_code_to_key(claim_code: &str) -> kad::RecordKey {
    let mut hasher = Sha256::new();
    hasher.update(b"mydia-claim:");
    hasher.update(claim_code.to_uppercase().as_bytes());
    let hash = hasher.finalize();
    let hash_vec: Vec<u8> = hash.to_vec();
    kad::RecordKey::new(&hash_vec)
}

// Configuration for the Host
pub struct HostConfig {
    pub enable_relay_server: bool,
    /// Optional list of bootstrap peer addresses (multiaddr format with peer ID)
    /// e.g., "/dnsaddr/bootstrap.libp2p.io/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN"
    pub bootstrap_peers: Vec<String>,
}

impl Default for HostConfig {
    fn default() -> Self {
        Self {
            enable_relay_server: false,
            bootstrap_peers: vec![],
        }
    }
}

/// Public IPFS/libp2p bootstrap nodes (official list from ipfs.io)
pub const IPFS_BOOTSTRAP_NODES: &[&str] = &[
    "/dnsaddr/bootstrap.libp2p.io/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
    "/dnsaddr/bootstrap.libp2p.io/p2p/QmQCU2EcMqAqQPR2i9bChDtGNJchTbq5TbXJJ16u19uLTa",
    "/dnsaddr/bootstrap.libp2p.io/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
    "/dnsaddr/bootstrap.libp2p.io/p2p/QmcZf59bWwK5XFi76CZX8cbJ4BhTzzA3gU1ZjYZcYW3dwt",
    "/ip4/104.131.131.82/tcp/4001/p2p/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
];

/// Helper function to add bootstrap peer to swarm
fn add_bootstrap_peer(swarm: &mut libp2p::Swarm<MydiaBehaviour>, addr_str: &str) -> bool {
    if let Ok(addr) = addr_str.parse::<Multiaddr>() {
        // Extract peer ID from /p2p/... component
        let peer_id = addr.iter().find_map(|p| {
            if let libp2p::multiaddr::Protocol::P2p(id) = p {
                Some(id)
            } else {
                None
            }
        });
        
        if let Some(peer_id) = peer_id {
            // Add address to Kademlia routing table
            swarm.behaviour_mut().kad.add_address(&peer_id, addr.clone());
            // Dial the peer
            let _ = swarm.dial(addr);
            return true;
        }
    }
    false
}

// The core Host struct that manages the Libp2p Swarm
pub struct Host {
    pub cmd_tx: mpsc::Sender<Command>,
    pub event_rx: std::sync::Arc<tokio::sync::Mutex<mpsc::Receiver<Event>>>,
    pub peer_id: PeerId,
}

impl Host {
    pub fn new(config: HostConfig) -> (Self, String) {
        let id_keys = identity::Keypair::generate_ed25519();
        let peer_id = PeerId::from(id_keys.public());
        let peer_id_str = peer_id.to_string();

        let (cmd_tx, mut cmd_rx) = mpsc::channel::<Command>(32);
        let (event_tx, event_rx) = mpsc::channel::<Event>(100);

        // Spawn the Swarm in a background thread/runtime
        std::thread::spawn(move || {
            let rt = Runtime::new().unwrap();
            rt.block_on(async move {
                let mut swarm = SwarmBuilder::with_existing_identity(id_keys)
                    .with_tokio()
                    .with_tcp(
                        tcp::Config::default(),
                        noise::Config::new,
                        yamux::Config::default,
                    )
                    .unwrap()
                    .with_dns()
                    .unwrap()
                    .with_relay_client(noise::Config::new, yamux::Config::default)
                    .unwrap()
                    .with_behaviour(|key: &identity::Keypair, relay_client: relay::client::Behaviour| {
                        let peer_id = PeerId::from(key.public());
                        
                        let mdns = mdns::tokio::Behaviour::new(mdns::Config::default(), peer_id).unwrap();
                        let kad_store = kad::store::MemoryStore::new(peer_id);
                        let kad = kad::Behaviour::new(peer_id, kad_store);
                        
                        let request_response = request_response::cbor::Behaviour::new(
                            [(
                                libp2p::StreamProtocol::new("/mydia/1.0.0"),
                                ProtocolSupport::Full,
                            )],
                            request_response::Config::default(),
                        );

                        let dcutr = dcutr::Behaviour::new(peer_id);
                        let relay_server = relay::Behaviour::new(peer_id, relay::Config::default());

                        MydiaBehaviour {
                            ping: ping::Behaviour::new(ping::Config::new().with_interval(Duration::from_secs(1))),
                            mdns,
                            kad,
                            request_response,
                            relay_client,
                            dcutr,
                            relay_server,
                        }
                    })
                    .unwrap()
                    .with_swarm_config(|c: SwarmConfig| c.with_idle_connection_timeout(Duration::from_secs(60)))
                    .build();

                swarm.behaviour_mut().kad.set_mode(Some(kad::Mode::Server));

                // Auto-bootstrap to IPFS nodes
                let mut bootstrap_peers_added = 0;
                for addr_str in IPFS_BOOTSTRAP_NODES {
                    if add_bootstrap_peer(&mut swarm, addr_str) {
                        bootstrap_peers_added += 1;
                    }
                }
                // Also add any custom bootstrap peers from config
                for addr_str in &config.bootstrap_peers {
                    if add_bootstrap_peer(&mut swarm, addr_str) {
                        bootstrap_peers_added += 1;
                    }
                }
                
                // Trigger bootstrap if we added any peers
                if bootstrap_peers_added > 0 {
                    println!("Added {} bootstrap peers, starting DHT bootstrap...", bootstrap_peers_added);
                    let _ = swarm.behaviour_mut().kad.bootstrap();
                }

                let mut response_channels = std::collections::HashMap::new();
                let mut pending_requests: std::collections::HashMap<OutboundRequestId, oneshot::Sender<Result<MydiaResponse, String>>> = std::collections::HashMap::new();
                
                // Track pending DHT operations
                let mut pending_provides: HashMap<kad::QueryId, oneshot::Sender<Result<(), String>>> = HashMap::new();
                let mut pending_lookups: HashMap<kad::QueryId, oneshot::Sender<Result<LookupResult, String>>> = HashMap::new();
                
                // Track state
                let mut bootstrap_complete = false;
                let mut provided_keys_count: usize = 0;

                loop {
                    tokio::select! {
                        event = swarm.select_next_some() => match event {
                            SwarmEvent::NewListenAddr { address, .. } => {
                                println!("Libp2p listening on {:?}", address);
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::Mdns(mdns::Event::Discovered(list))) => {
                                for (peer_id, _multiaddr) in list {
                                    swarm.behaviour_mut().kad.add_address(&peer_id, _multiaddr);
                                    let _ = event_tx.send(Event::PeerDiscovered(peer_id.to_string())).await;
                                }
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::Mdns(mdns::Event::Expired(list))) => {
                                for (peer_id, _multiaddr) in list {
                                    let _ = event_tx.send(Event::PeerExpired(peer_id.to_string())).await;
                                }
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::RequestResponse(event)) => {
                                match event {
                                    request_response::Event::Message { peer, message, .. } => {
                                        match message {
                                            request_response::Message::Request { request, channel, .. } => {
                                                let request_id = uuid::Uuid::new_v4().to_string();
                                                response_channels.insert(request_id.clone(), channel);
                                                
                                                let _ = event_tx.send(Event::RequestReceived {
                                                    peer: peer.to_string(),
                                                    request,
                                                    request_id,
                                                }).await;
                                            }
                                            request_response::Message::Response { response, request_id } => {
                                                if let Some(reply) = pending_requests.remove(&request_id) {
                                                    let _ = reply.send(Ok(response));
                                                }
                                            }
                                        }
                                    }
                                    request_response::Event::OutboundFailure { request_id, error, .. } => {
                                        if let Some(reply) = pending_requests.remove(&request_id) {
                                            let _ = reply.send(Err(format!("Outbound failure: {:?}", error)));
                                        }
                                    }
                                    _ => {}
                                }
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::RelayServer(relay::Event::ReservationReqAccepted { src_peer_id, .. })) => {
                                if config.enable_relay_server {
                                    println!("Relay reservation accepted for {:?}", src_peer_id);
                                }
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::Kad(kad::Event::OutboundQueryProgressed { id, result, .. })) => {
                                match result {
                                    kad::QueryResult::StartProviding(Ok(_)) => {
                                        provided_keys_count += 1;
                                        if let Some(reply) = pending_provides.remove(&id) {
                                            let _ = reply.send(Ok(()));
                                        }
                                    }
                                    kad::QueryResult::StartProviding(Err(e)) => {
                                        if let Some(reply) = pending_provides.remove(&id) {
                                            let _ = reply.send(Err(format!("Failed to provide: {:?}", e)));
                                        }
                                    }
                                    kad::QueryResult::GetProviders(Ok(kad::GetProvidersOk::FoundProviders { providers, .. })) => {
                                        if let Some(reply) = pending_lookups.remove(&id) {
                                            if let Some(provider) = providers.into_iter().next() {
                                                // Get addresses for this peer from Kademlia routing table
                                                let addresses: Vec<String> = swarm
                                                    .behaviour_mut()
                                                    .kad
                                                    .kbuckets()
                                                    .filter_map(|bucket| {
                                                        bucket.iter().find_map(|entry| {
                                                            if entry.node.key.preimage() == &provider {
                                                                Some(entry.node.value.iter().map(|a| a.to_string()).collect::<Vec<_>>())
                                                            } else {
                                                                None
                                                            }
                                                        })
                                                    })
                                                    .flatten()
                                                    .collect();
                                                
                                                let _ = reply.send(Ok(LookupResult {
                                                    peer_id: provider.to_string(),
                                                    addresses,
                                                }));
                                            } else {
                                                let _ = reply.send(Err("No providers found".to_string()));
                                            }
                                        }
                                    }
                                    kad::QueryResult::GetProviders(Ok(kad::GetProvidersOk::FinishedWithNoAdditionalRecord { .. })) => {
                                        if let Some(reply) = pending_lookups.remove(&id) {
                                            let _ = reply.send(Err("Lookup finished with no results".to_string()));
                                        }
                                    }
                                    kad::QueryResult::GetProviders(Err(e)) => {
                                        if let Some(reply) = pending_lookups.remove(&id) {
                                            let _ = reply.send(Err(format!("Lookup failed: {:?}", e)));
                                        }
                                    }
                                    kad::QueryResult::Bootstrap(Ok(_)) => {
                                        println!("Kademlia bootstrap completed");
                                        bootstrap_complete = true;
                                        let _ = event_tx.send(Event::BootstrapCompleted).await;
                                    }
                                    kad::QueryResult::Bootstrap(Err(e)) => {
                                        println!("Kademlia bootstrap failed: {:?}", e);
                                    }
                                    _ => {}
                                }
                            }
                            _ => {}
                        },
                        command = cmd_rx.recv() => match command {
                            Some(Command::Listen(addr_str)) => {
                                if let Ok(addr) = addr_str.parse() {
                                    let _ = swarm.listen_on(addr);
                                }
                            }
                            Some(Command::Dial(addr_str)) => {
                                if let Ok(addr) = addr_str.parse::<Multiaddr>() {
                                    let _ = swarm.dial(addr);
                                }
                            }
                            Some(Command::Bootstrap(addr_str)) => {
                                // Parse the multiaddr and extract peer ID
                                if let Ok(addr) = addr_str.parse::<Multiaddr>() {
                                    // Extract peer ID from /p2p/... component
                                    let peer_id = addr.iter().find_map(|p| {
                                        if let libp2p::multiaddr::Protocol::P2p(id) = p {
                                            Some(id)
                                        } else {
                                            None
                                        }
                                    });
                                    
                                    if let Some(peer_id) = peer_id {
                                        // Add address to Kademlia routing table
                                        swarm.behaviour_mut().kad.add_address(&peer_id, addr.clone());
                                        // Dial the peer
                                        let _ = swarm.dial(addr);
                                        // Trigger bootstrap
                                        let _ = swarm.behaviour_mut().kad.bootstrap();
                                    }
                                }
                            }
                            Some(Command::ProvideClaimCode { claim_code, reply }) => {
                                let key = claim_code_to_key(&claim_code);
                                match swarm.behaviour_mut().kad.start_providing(key) {
                                    Ok(query_id) => {
                                        pending_provides.insert(query_id, reply);
                                    }
                                    Err(e) => {
                                        let _ = reply.send(Err(format!("Failed to start providing: {:?}", e)));
                                    }
                                }
                            }
                            Some(Command::LookupClaimCode { claim_code, reply }) => {
                                let key = claim_code_to_key(&claim_code);
                                let query_id = swarm.behaviour_mut().kad.get_providers(key);
                                pending_lookups.insert(query_id, reply);
                            }
                            Some(Command::SendRequest { peer, request, reply }) => {
                                if let Ok(peer_id) = peer.parse::<PeerId>() {
                                    let request_id = swarm.behaviour_mut().request_response.send_request(&peer_id, request);
                                    pending_requests.insert(request_id, reply);
                                } else {
                                    let _ = reply.send(Err("Invalid peer ID".to_string()));
                                }
                            }
                            Some(Command::SendResponse { request_id, response }) => {
                                if let Some(channel) = response_channels.remove(&request_id) {
                                    let _ = swarm.behaviour_mut().request_response.send_response(channel, response);
                                }
                            }
                            Some(Command::GetDhtStats { reply }) => {
                                // Count peers in routing table
                                let routing_table_size: usize = swarm
                                    .behaviour_mut()
                                    .kad
                                    .kbuckets()
                                    .map(|bucket| bucket.num_entries())
                                    .sum();
                                
                                let _ = reply.send(DhtStats {
                                    routing_table_size,
                                    provided_keys_count,
                                    bootstrap_complete,
                                });
                            }
                            None => return,
                        }
                    }
                }
            });
        });

        (Host { cmd_tx, event_rx: std::sync::Arc::new(tokio::sync::Mutex::new(event_rx)), peer_id }, peer_id_str)
    }

    pub fn listen(&self, addr: String) -> Result<(), String> {
        match self.cmd_tx.blocking_send(Command::Listen(addr)) {
            Ok(_) => Ok(()),
            Err(_) => Err("send_failed".to_string()),
        }
    }

    pub fn dial(&self, addr: String) -> Result<(), String> {
        match self.cmd_tx.blocking_send(Command::Dial(addr)) {
            Ok(_) => Ok(()),
            Err(_) => Err("send_failed".to_string()),
        }
    }

    pub async fn send_request(&self, peer: String, request: MydiaRequest) -> Result<MydiaResponse, String> {
        let (tx, rx) = oneshot::channel();
        match self.cmd_tx.send(Command::SendRequest { peer, request, reply: tx }).await {
            Ok(_) => {
                match rx.await {
                    Ok(res) => res,
                    Err(_) => Err("Response channel closed".to_string()),
                }
            }
            Err(_) => Err("send_failed".to_string()),
        }
    }

    pub fn send_response(&self, request_id: String, response: MydiaResponse) -> Result<(), String> {
        match self.cmd_tx.blocking_send(Command::SendResponse { request_id, response }) {
            Ok(_) => Ok(()),
            Err(_) => Err("send_failed".to_string()),
        }
    }

    /// Add a bootstrap peer and initiate DHT bootstrap.
    /// The address should include the peer ID, e.g., "/ip4/1.2.3.4/tcp/4001/p2p/12D3..."
    pub fn bootstrap(&self, addr: String) -> Result<(), String> {
        match self.cmd_tx.blocking_send(Command::Bootstrap(addr)) {
            Ok(_) => Ok(()),
            Err(_) => Err("send_failed".to_string()),
        }
    }

    /// Provide a claim code on the DHT, announcing this peer as the provider.
    /// Call this when a new claim code is generated.
    /// This is a blocking version suitable for calling from NIFs.
    pub fn provide_claim_code(&self, claim_code: String) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        match self.cmd_tx.blocking_send(Command::ProvideClaimCode { claim_code, reply: tx }) {
            Ok(_) => {
                // Block waiting for the result
                match rx.blocking_recv() {
                    Ok(res) => res,
                    Err(_) => Err("Response channel closed".to_string()),
                }
            }
            Err(_) => Err("send_failed".to_string()),
        }
    }

    /// Lookup a claim code on the DHT to find the provider peer.
    /// Returns the peer ID and addresses of the server that provided this claim code.
    pub async fn lookup_claim_code(&self, claim_code: String) -> Result<LookupResult, String> {
        let (tx, rx) = oneshot::channel();
        match self.cmd_tx.send(Command::LookupClaimCode { claim_code, reply: tx }).await {
            Ok(_) => {
                match rx.await {
                    Ok(res) => res,
                    Err(_) => Err("Response channel closed".to_string()),
                }
            }
            Err(_) => Err("send_failed".to_string()),
        }
    }

    /// Get DHT statistics (routing table size, provided keys, bootstrap status).
    /// This is a blocking call suitable for NIFs.
    pub fn get_dht_stats(&self) -> DhtStats {
        let (tx, rx) = oneshot::channel();
        match self.cmd_tx.blocking_send(Command::GetDhtStats { reply: tx }) {
            Ok(_) => {
                rx.blocking_recv().unwrap_or(DhtStats {
                    routing_table_size: 0,
                    provided_keys_count: 0,
                    bootstrap_complete: false,
                })
            }
            Err(_) => DhtStats {
                routing_table_size: 0,
                provided_keys_count: 0,
                bootstrap_complete: false,
            },
        }
    }
}
