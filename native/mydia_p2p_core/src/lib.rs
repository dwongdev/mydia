use libp2p::{
    identity,
    identify,
    ping,
    mdns,
    kad,
    noise,
    tcp,
    yamux,
    relay,
    dcutr,
    rendezvous,
    request_response::{self, ProtocolSupport, OutboundRequestId},
    PeerId,
    SwarmBuilder,
    Multiaddr,
    swarm::{NetworkBehaviour, SwarmEvent, Config as SwarmConfig, behaviour::toggle::Toggle},
};
use std::time::Duration;
use std::collections::HashMap;
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, oneshot};
use libp2p::futures::StreamExt;

// Define the Network Behaviour with optional components using Toggle
#[derive(NetworkBehaviour)]
pub struct MydiaBehaviour {
    ping: ping::Behaviour,
    identify: identify::Behaviour,
    mdns: Toggle<mdns::tokio::Behaviour>,
    kad: Toggle<kad::Behaviour<kad::store::MemoryStore>>,
    request_response: request_response::cbor::Behaviour<MydiaRequest, MydiaResponse>,
    relay_client: relay::client::Behaviour,
    dcutr: dcutr::Behaviour,
    relay_server: Toggle<relay::Behaviour>,
    rendezvous_client: Toggle<rendezvous::client::Behaviour>,
    rendezvous_server: Toggle<rendezvous::server::Behaviour>,
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
    AddExternalAddress(String), // Add an external address to announce
    SendRequest { 
        peer: String, 
        request: MydiaRequest, 
        reply: oneshot::Sender<Result<MydiaResponse, String>> 
    },
    SendResponse { request_id: String, response: MydiaResponse },
    // Rendezvous commands for claim code discovery
    RegisterNamespace {
        namespace: String,
        ttl_secs: u64,
        reply: oneshot::Sender<Result<(), String>>,
    },
    DiscoverNamespace {
        namespace: String,
        reply: oneshot::Sender<Result<Vec<DiscoveredPeer>, String>>,
    },
    UnregisterNamespace {
        namespace: String,
    },
    // Get network statistics
    GetNetworkStats {
        reply: oneshot::Sender<NetworkStats>,
    },
}

/// A peer discovered via rendezvous
#[derive(Debug, Clone)]
pub struct DiscoveredPeer {
    pub peer_id: String,
    pub addresses: Vec<String>,
}

/// Network statistics (replaces DhtStats)
#[derive(Debug, Clone)]
pub struct NetworkStats {
    pub routing_table_size: usize,
    pub active_registrations: usize,
    pub rendezvous_connected: bool,
    pub kademlia_enabled: bool,
}

// Events emitted by the Host
#[derive(Debug)]
pub enum Event {
    PeerDiscovered(String),
    PeerExpired(String),
    PeerConnected(String),
    PeerDisconnected(String),
    RequestReceived { 
        peer: String, 
        request: MydiaRequest, 
        request_id: String,
    },
    BootstrapCompleted,
    NewListenAddr(String),
    RelayReservationReady { relay_peer_id: String, relayed_addr: String },
    RelayReservationFailed { relay_peer_id: String, error: String },
    RendezvousRegistered { namespace: String },
    RendezvousRegistrationFailed { namespace: String, error: String },
    RendezvousDiscovered { namespace: String, peers: Vec<DiscoveredPeer> },
}

// Configuration for the Host
#[derive(Clone)]
pub struct HostConfig {
    pub enable_relay_server: bool,
    pub enable_ipfs_bootstrap: bool,
    /// Enable mDNS for local peer discovery. Disable for isolated test environments.
    pub enable_mdns: bool,
    /// Enable Kademlia DHT. Set to false for mobile clients to save battery.
    pub enable_kademlia: bool,
    /// Enable rendezvous client behaviour for namespace discovery.
    pub enable_rendezvous_client: bool,
    /// Enable rendezvous server behaviour (for metadata-relay).
    pub enable_rendezvous_server: bool,
    /// Rendezvous point addresses to connect to (multiaddr format with peer ID).
    pub rendezvous_point_addresses: Vec<String>,
    /// Optional list of bootstrap peer addresses (multiaddr format with peer ID)
    /// e.g., "/dnsaddr/bootstrap.libp2p.io/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN"
    pub bootstrap_peers: Vec<String>,
    /// Path to store/load keypair (optional). If not set, a new random keypair is generated.
    pub keypair_path: Option<String>,
}

impl Default for HostConfig {
    fn default() -> Self {
        Self {
            enable_relay_server: false,
            enable_ipfs_bootstrap: true,
            enable_mdns: true,
            enable_kademlia: true,
            enable_rendezvous_client: false,
            enable_rendezvous_server: false,
            rendezvous_point_addresses: vec![],
            bootstrap_peers: vec![],
            keypair_path: None,
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
            // Add address to Kademlia routing table if enabled
            if let Some(kad) = swarm.behaviour_mut().kad.as_mut() {
                kad.add_address(&peer_id, addr.clone());
            }
            // Dial the peer
            let _ = swarm.dial(addr);
            return true;
        }
    }
    false
}

/// Extract peer ID from a multiaddr string
fn extract_peer_id(addr_str: &str) -> Option<PeerId> {
    if let Ok(addr) = addr_str.parse::<Multiaddr>() {
        addr.iter().find_map(|p| {
            if let libp2p::multiaddr::Protocol::P2p(id) = p {
                Some(id)
            } else {
                None
            }
        })
    } else {
        None
    }
}

fn load_or_generate_keypair(path: Option<&str>) -> identity::Keypair {
    if let Some(path) = path {
        if let Ok(mut file) = std::fs::File::open(path) {
            let mut bytes = Vec::new();
            use std::io::Read;
            if file.read_to_end(&mut bytes).is_ok() {
                if let Ok(keypair) = identity::Keypair::from_protobuf_encoding(&bytes) {
                    println!("Loaded keypair from {}", path);
                    return keypair;
                }
            }
        }
    }
    
    // Generate new
    let keypair = identity::Keypair::generate_ed25519();
    
    // Save if path provided
    if let Some(path) = path {
        if let Ok(bytes) = keypair.to_protobuf_encoding() {
            use std::io::Write;
            if let Ok(mut file) = std::fs::File::create(path) {
                let _ = file.write_all(&bytes);
                println!("Generated and saved new keypair to {}", path);
            }
        }
    }
    
    keypair
}

// The core Host struct that manages the Libp2p Swarm
pub struct Host {
    pub cmd_tx: mpsc::Sender<Command>,
    pub event_rx: std::sync::Arc<tokio::sync::Mutex<mpsc::Receiver<Event>>>,
    pub peer_id: PeerId,
}

impl Host {
    pub fn new(config: HostConfig) -> (Self, String) {
        let id_keys = load_or_generate_keypair(config.keypair_path.as_deref());
        let peer_id = PeerId::from(id_keys.public());
        let peer_id_str = peer_id.to_string();

        let (cmd_tx, mut cmd_rx) = mpsc::channel::<Command>(32);
        let (event_tx, event_rx) = mpsc::channel::<Event>(100);

        let config_clone = config.clone();

        // Spawn the Swarm in a background thread/runtime
        std::thread::spawn(move || {
            let config = config_clone;
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
                    .with_behaviour(move |key: &identity::Keypair, relay_client: relay::client::Behaviour| {
                        let peer_id = PeerId::from(key.public());
                        
                        // mDNS - optional
                        let mdns = if config.enable_mdns {
                            Toggle::from(Some(mdns::tokio::Behaviour::new(mdns::Config::default(), peer_id).unwrap()))
                        } else {
                            Toggle::from(None)
                        };
                        
                        // Kademlia - optional (disable for mobile to save battery)
                        let kad = if config.enable_kademlia {
                            let kad_store = kad::store::MemoryStore::new(peer_id);
                            let mut kad_config = kad::Config::default();
                            if !config.enable_ipfs_bootstrap {
                                // For small test networks, use higher replication
                                kad_config.set_replication_factor(std::num::NonZeroUsize::new(3).unwrap());
                                kad_config.set_query_timeout(Duration::from_secs(30));
                            }
                            let mut kad = kad::Behaviour::with_config(peer_id, kad_store, kad_config);
                            kad.set_mode(Some(kad::Mode::Server));
                            Toggle::from(Some(kad))
                        } else {
                            Toggle::from(None)
                        };
                        
                        let request_response = request_response::cbor::Behaviour::new(
                            [(
                                libp2p::StreamProtocol::new("/mydia/1.0.0"),
                                ProtocolSupport::Full,
                            )],
                            request_response::Config::default(),
                        );

                        let dcutr = dcutr::Behaviour::new(peer_id);
                        
                        // Relay server - optional
                        let relay_server = if config.enable_relay_server {
                            Toggle::from(Some(relay::Behaviour::new(peer_id, relay::Config::default())))
                        } else {
                            Toggle::from(None)
                        };
                        
                        let identify = identify::Behaviour::new(identify::Config::new(
                            "/mydia/1.0.0".to_string(),
                            key.public(),
                        ));

                        // Rendezvous client - optional (for home servers and players)
                        let rendezvous_client = if config.enable_rendezvous_client {
                            Toggle::from(Some(rendezvous::client::Behaviour::new(key.clone())))
                        } else {
                            Toggle::from(None)
                        };

                        // Rendezvous server - optional (for metadata-relay)
                        let rendezvous_server = if config.enable_rendezvous_server {
                            Toggle::from(Some(rendezvous::server::Behaviour::new(rendezvous::server::Config::default())))
                        } else {
                            Toggle::from(None)
                        };

                        MydiaBehaviour {
                            ping: ping::Behaviour::new(ping::Config::new().with_interval(Duration::from_secs(15))),
                            identify,
                            mdns,
                            kad,
                            request_response,
                            relay_client,
                            dcutr,
                            relay_server,
                            rendezvous_client,
                            rendezvous_server,
                        }
                    })
                    .unwrap()
                    .with_swarm_config(|c: SwarmConfig| c.with_idle_connection_timeout(Duration::from_secs(60)))
                    .build();

                // Auto-bootstrap to IPFS nodes if Kademlia is enabled
                let mut bootstrap_peers_added = 0;
                if config.enable_kademlia && config.enable_ipfs_bootstrap {
                    for addr_str in IPFS_BOOTSTRAP_NODES {
                        if add_bootstrap_peer(&mut swarm, addr_str) {
                            bootstrap_peers_added += 1;
                        }
                    }
                }
                // Also add any custom bootstrap peers from config
                if config.enable_kademlia {
                    for addr_str in &config.bootstrap_peers {
                        if add_bootstrap_peer(&mut swarm, addr_str) {
                            bootstrap_peers_added += 1;
                        }
                    }
                }
                
                // Trigger bootstrap if we added any peers
                if bootstrap_peers_added > 0 {
                    println!("Added {} bootstrap peers, starting DHT bootstrap...", bootstrap_peers_added);
                    if let Some(kad) = swarm.behaviour_mut().kad.as_mut() {
                        let _ = kad.bootstrap();
                    }
                }

                // Connect to rendezvous points if configured
                for addr_str in &config.rendezvous_point_addresses {
                    if let Ok(addr) = addr_str.parse::<Multiaddr>() {
                        println!("Dialing rendezvous point: {}", addr_str);
                        let _ = swarm.dial(addr);
                    }
                }

                let mut response_channels = std::collections::HashMap::new();
                let mut pending_requests: std::collections::HashMap<OutboundRequestId, oneshot::Sender<Result<MydiaResponse, String>>> = std::collections::HashMap::new();

                // Track state
                let mut _bootstrap_complete = false;
                
                // Track rendezvous state
                let mut active_registrations: HashMap<String, PeerId> = HashMap::new(); // namespace -> rendezvous point peer
                let pending_discoveries: HashMap<String, oneshot::Sender<Result<Vec<DiscoveredPeer>, String>>> = HashMap::new();
                let mut pending_discoveries = pending_discoveries;
                
                // Track rendezvous point peer IDs
                let rendezvous_points: Vec<PeerId> = config.rendezvous_point_addresses.iter()
                    .filter_map(|addr| extract_peer_id(addr))
                    .collect();

                // Cache of peer addresses discovered via Identify and Kademlia
                let mut peer_addresses: HashMap<PeerId, Vec<Multiaddr>> = HashMap::new();

                loop {
                    tokio::select! {
                        event = swarm.select_next_some() => match event {
                            SwarmEvent::NewListenAddr { address, .. } => {
                                println!("Libp2p listening on {:?}", address);
                                let _ = event_tx.send(Event::NewListenAddr(address.to_string())).await;
                            }
                            SwarmEvent::ConnectionEstablished { peer_id, .. } => {
                                let _ = event_tx.send(Event::PeerConnected(peer_id.to_string())).await;
                            }
                            SwarmEvent::ConnectionClosed { peer_id, .. } => {
                                let _ = event_tx.send(Event::PeerDisconnected(peer_id.to_string())).await;
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::Mdns(mdns::Event::Discovered(list))) => {
                                for (peer_id, addr) in list {
                                    if let Some(kad) = swarm.behaviour_mut().kad.as_mut() {
                                        kad.add_address(&peer_id, addr);
                                    }
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
                                println!("Relay reservation accepted for {:?}", src_peer_id);
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::RelayClient(event)) => {
                                match event {
                                    relay::client::Event::ReservationReqAccepted { relay_peer_id, renewal, .. } => {
                                        if !renewal {
                                            // Get the relayed address
                                            let relayed_addr = swarm.external_addresses()
                                                .find(|addr| addr.to_string().contains(&relay_peer_id.to_string()))
                                                .map(|a| a.to_string())
                                                .unwrap_or_default();
                                            let _ = event_tx.send(Event::RelayReservationReady {
                                                relay_peer_id: relay_peer_id.to_string(),
                                                relayed_addr,
                                            }).await;
                                        }
                                    }
                                    relay::client::Event::OutboundCircuitEstablished { .. } => {
                                        // Circuit established for relayed connection
                                    }
                                    relay::client::Event::InboundCircuitEstablished { .. } => {
                                        // Inbound circuit established
                                    }
                                }
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::Identify(identify::Event::Received { peer_id, info, .. })) => {
                                // Add discovered addresses to Kademlia routing table and our cache
                                println!("Identify received from {}: {} addresses", peer_id, info.listen_addrs.len());
                                let addrs = peer_addresses.entry(peer_id).or_default();
                                for addr in info.listen_addrs {
                                    if let Some(kad) = swarm.behaviour_mut().kad.as_mut() {
                                        kad.add_address(&peer_id, addr.clone());
                                    }
                                    if !addrs.contains(&addr) {
                                        addrs.push(addr);
                                    }
                                }
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::Kad(kad::Event::RoutingUpdated { peer, addresses, .. })) => {
                                println!("Kademlia routing updated: {} with {} addresses", peer, addresses.len());
                                // Also cache addresses from Kademlia updates
                                let addrs = peer_addresses.entry(peer).or_default();
                                for addr in addresses.iter() {
                                    if !addrs.contains(addr) {
                                        addrs.push(addr.clone());
                                    }
                                }
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::Kad(kad::Event::OutboundQueryProgressed { result, .. })) => {
                                match result {
                                    kad::QueryResult::Bootstrap(Ok(_)) => {
                                        println!("Kademlia bootstrap completed");
                                        _bootstrap_complete = true;
                                        let _ = event_tx.send(Event::BootstrapCompleted).await;
                                    }
                                    kad::QueryResult::Bootstrap(Err(e)) => {
                                        println!("Kademlia bootstrap failed: {:?}", e);
                                    }
                                    _ => {}
                                }
                            }
                            // Rendezvous client events
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::RendezvousClient(event)) => {
                                match event {
                                    rendezvous::client::Event::Registered { namespace, ttl, rendezvous_node } => {
                                        println!("Registered in namespace '{}' at {:?} for {} seconds", namespace, rendezvous_node, ttl);
                                        active_registrations.insert(namespace.to_string(), rendezvous_node);
                                        let _ = event_tx.send(Event::RendezvousRegistered {
                                            namespace: namespace.to_string(),
                                        }).await;
                                    }
                                    rendezvous::client::Event::RegisterFailed { namespace, rendezvous_node, error } => {
                                        println!("Failed to register in namespace '{}' at {:?}: {:?}", namespace, rendezvous_node, error);
                                        let _ = event_tx.send(Event::RendezvousRegistrationFailed {
                                            namespace: namespace.to_string(),
                                            error: format!("{:?}", error),
                                        }).await;
                                    }
                                    rendezvous::client::Event::Discovered { registrations, cookie, rendezvous_node } => {
                                        println!("Discovered {} peers from {:?}", registrations.len(), rendezvous_node);
                                        
                                        // Convert to DiscoveredPeer structs
                                        let discovered: Vec<DiscoveredPeer> = registrations.iter().map(|reg| {
                                            DiscoveredPeer {
                                                peer_id: reg.record.peer_id().to_string(),
                                                addresses: reg.record.addresses().iter().map(|a| a.to_string()).collect(),
                                            }
                                        }).collect();

                                        // Get namespace from cookie if possible, otherwise use a placeholder
                                        let namespace = registrations.first()
                                            .map(|r| r.namespace.to_string())
                                            .unwrap_or_else(|| "unknown".to_string());
                                        
                                        // Complete any pending discovery requests
                                        if let Some(reply) = pending_discoveries.remove(&namespace) {
                                            let _ = reply.send(Ok(discovered.clone()));
                                        }
                                        
                                        let _ = event_tx.send(Event::RendezvousDiscovered {
                                            namespace,
                                            peers: discovered,
                                        }).await;
                                        
                                        // Store cookie for subsequent discovery (pagination)
                                        let _ = cookie;
                                    }
                                    rendezvous::client::Event::DiscoverFailed { namespace, rendezvous_node, error } => {
                                        let ns_str = namespace.map(|ns| ns.to_string()).unwrap_or_else(|| "all".to_string());
                                        println!("Discovery failed for namespace '{}' at {:?}: {:?}", ns_str, rendezvous_node, error);
                                        if let Some(reply) = pending_discoveries.remove(&ns_str) {
                                            let _ = reply.send(Err(format!("Discovery failed: {:?}", error)));
                                        }
                                    }
                                    rendezvous::client::Event::Expired { peer } => {
                                        println!("Registration expired for peer {:?}", peer);
                                    }
                                }
                            }
                            // Rendezvous server events
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::RendezvousServer(event)) => {
                                match event {
                                    rendezvous::server::Event::PeerRegistered { peer, registration } => {
                                        println!("Peer {:?} registered in namespace '{}'", peer, registration.namespace);
                                    }
                                    rendezvous::server::Event::PeerNotRegistered { peer, namespace, error } => {
                                        println!("Peer {:?} failed to register in namespace '{}': {:?}", peer, namespace, error);
                                    }
                                    rendezvous::server::Event::PeerUnregistered { peer, namespace } => {
                                        println!("Peer {:?} unregistered from namespace '{}'", peer, namespace);
                                    }
                                    rendezvous::server::Event::DiscoverServed { enquirer, registrations } => {
                                        println!("Served {} registrations to {:?}", registrations.len(), enquirer);
                                    }
                                    rendezvous::server::Event::DiscoverNotServed { enquirer, error } => {
                                        println!("Failed to serve discovery to {:?}: {:?}", enquirer, error);
                                    }
                                    rendezvous::server::Event::RegistrationExpired(registration) => {
                                        println!("Registration expired: peer {:?} in namespace '{}'", registration.record.peer_id(), registration.namespace);
                                    }
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
                            Some(Command::AddExternalAddress(addr_str)) => {
                                if let Ok(addr) = addr_str.parse::<Multiaddr>() {
                                    swarm.add_external_address(addr);
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
                                        if let Some(kad) = swarm.behaviour_mut().kad.as_mut() {
                                            kad.add_address(&peer_id, addr.clone());
                                        }
                                        // Dial the peer
                                        let _ = swarm.dial(addr);
                                        // Trigger bootstrap
                                        if let Some(kad) = swarm.behaviour_mut().kad.as_mut() {
                                            let _ = kad.bootstrap();
                                        }
                                    }
                                }
                            }
                            Some(Command::RegisterNamespace { namespace, ttl_secs, reply }) => {
                                // Register with all known rendezvous points
                                if rendezvous_points.is_empty() {
                                    let _ = reply.send(Err("No rendezvous points configured".to_string()));
                                } else if let Some(rendezvous_client) = swarm.behaviour_mut().rendezvous_client.as_mut() {
                                    // Try to register with the first available rendezvous point
                                    let rendezvous_peer = rendezvous_points[0];
                                    println!("Registering namespace '{}' with rendezvous point {:?}", namespace, rendezvous_peer);
                                    
                                    match rendezvous::Namespace::new(namespace.clone()) {
                                        Ok(ns) => {
                                            let _ = rendezvous_client.register(ns, rendezvous_peer, Some(ttl_secs));
                                            // The actual result comes via event
                                            // For now we return success, the event will confirm
                                            let _ = reply.send(Ok(()));
                                        }
                                        Err(e) => {
                                            let _ = reply.send(Err(format!("Invalid namespace: {:?}", e)));
                                        }
                                    }
                                } else {
                                    let _ = reply.send(Err("Rendezvous client not enabled".to_string()));
                                }
                            }
                            Some(Command::DiscoverNamespace { namespace, reply }) => {
                                if rendezvous_points.is_empty() {
                                    let _ = reply.send(Err("No rendezvous points configured".to_string()));
                                } else if let Some(rendezvous_client) = swarm.behaviour_mut().rendezvous_client.as_mut() {
                                    let rendezvous_peer = rendezvous_points[0];
                                    println!("Discovering namespace '{}' from rendezvous point {:?}", namespace, rendezvous_peer);
                                    
                                    match rendezvous::Namespace::new(namespace.clone()) {
                                        Ok(ns) => {
                                            // Store the reply channel for when we get the result
                                            pending_discoveries.insert(namespace.clone(), reply);
                                            rendezvous_client.discover(Some(ns), None, None, rendezvous_peer);
                                        }
                                        Err(e) => {
                                            let _ = reply.send(Err(format!("Invalid namespace: {:?}", e)));
                                        }
                                    }
                                } else {
                                    let _ = reply.send(Err("Rendezvous client not enabled".to_string()));
                                }
                            }
                            Some(Command::UnregisterNamespace { namespace }) => {
                                if let Some(rendezvous_peer) = active_registrations.remove(&namespace) {
                                    if let Some(rendezvous_client) = swarm.behaviour_mut().rendezvous_client.as_mut() {
                                        if let Ok(ns) = rendezvous::Namespace::new(namespace.clone()) {
                                            rendezvous_client.unregister(ns, rendezvous_peer);
                                            println!("Unregistered from namespace '{}'", namespace);
                                        }
                                    }
                                }
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
                            Some(Command::GetNetworkStats { reply }) => {
                                // Check if Kademlia is enabled and count peers in routing table
                                let kademlia_enabled = swarm.behaviour().kad.is_enabled();
                                let routing_table_size: usize = swarm
                                    .behaviour_mut()
                                    .kad
                                    .as_mut()
                                    .map(|kad| kad.kbuckets().map(|bucket| bucket.num_entries()).sum())
                                    .unwrap_or(0);

                                let _ = reply.send(NetworkStats {
                                    routing_table_size,
                                    active_registrations: active_registrations.len(),
                                    rendezvous_connected: !rendezvous_points.is_empty(),
                                    kademlia_enabled,
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

    pub fn add_external_address(&self, addr: String) -> Result<(), String> {
        match self.cmd_tx.blocking_send(Command::AddExternalAddress(addr)) {
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

    /// Send a response to a request (async version for use in async contexts).
    pub async fn send_response_async(&self, request_id: String, response: MydiaResponse) -> Result<(), String> {
        match self.cmd_tx.send(Command::SendResponse { request_id, response }).await {
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

    /// Register this peer under a namespace with the rendezvous point.
    /// This is a blocking version suitable for calling from NIFs.
    pub fn register_namespace(&self, namespace: String, ttl_secs: u64) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        match self.cmd_tx.blocking_send(Command::RegisterNamespace { namespace, ttl_secs, reply: tx }) {
            Ok(_) => {
                match rx.blocking_recv() {
                    Ok(res) => res,
                    Err(_) => Err("Response channel closed".to_string()),
                }
            }
            Err(_) => Err("send_failed".to_string()),
        }
    }

    /// Discover peers registered under a namespace.
    /// Returns the list of discovered peers with their addresses.
    pub async fn discover_namespace(&self, namespace: String) -> Result<Vec<DiscoveredPeer>, String> {
        let (tx, rx) = oneshot::channel();
        match self.cmd_tx.send(Command::DiscoverNamespace { namespace, reply: tx }).await {
            Ok(_) => {
                match rx.await {
                    Ok(res) => res,
                    Err(_) => Err("Response channel closed".to_string()),
                }
            }
            Err(_) => Err("send_failed".to_string()),
        }
    }

    /// Unregister this peer from a namespace.
    pub fn unregister_namespace(&self, namespace: String) -> Result<(), String> {
        match self.cmd_tx.blocking_send(Command::UnregisterNamespace { namespace }) {
            Ok(_) => Ok(()),
            Err(_) => Err("send_failed".to_string()),
        }
    }

    /// Get network statistics.
    /// This is a blocking call suitable for NIFs.
    pub fn get_network_stats(&self) -> NetworkStats {
        let (tx, rx) = oneshot::channel();
        match self.cmd_tx.blocking_send(Command::GetNetworkStats { reply: tx }) {
            Ok(_) => {
                rx.blocking_recv().unwrap_or(NetworkStats {
                    routing_table_size: 0,
                    active_registrations: 0,
                    rendezvous_connected: false,
                    kademlia_enabled: false,
                })
            }
            Err(_) => NetworkStats {
                routing_table_size: 0,
                active_registrations: 0,
                rendezvous_connected: false,
                kademlia_enabled: false,
            },
        }
    }

    /// Connect to a relay and request a reservation.
    pub fn connect_relay(&self, relay_addr: String) -> Result<(), String> {
        // Parse the multiaddr to validate
        if relay_addr.parse::<Multiaddr>().is_ok() {
            // Dial first to establish connection
            self.dial(relay_addr)?;
            // The relay client behaviour will automatically request a reservation
            // when we dial a relay address
            Ok(())
        } else {
            Err("Invalid relay address".to_string())
        }
    }
}
