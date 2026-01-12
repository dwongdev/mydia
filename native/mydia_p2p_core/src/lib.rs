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
    swarm::{NetworkBehaviour, SwarmEvent},
};
use std::time::Duration;
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, oneshot};
use libp2p::futures::StreamExt;
use std::iter;

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
    SendRequest { 
        peer: String, 
        request: MydiaRequest, 
        reply: oneshot::Sender<Result<MydiaResponse, String>> 
    },
    SendResponse { request_id: String, response: MydiaResponse },
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
}

// Configuration for the Host
pub struct HostConfig {
    pub enable_relay_server: bool,
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
                    .or_transport(relay_transport)
                    .with_dns()
                    .unwrap()
                    .with_behaviour(|key| {
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

                        let (relay_transport, relay_client) = relay::client::new(peer_id);
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
                    .with_swarm_config(|c| c.with_idle_connection_timeout(Duration::from_secs(60)))
                    .build();

                swarm.behaviour_mut().kad.set_mode(Some(kad::Mode::Server));

                let mut response_channels = std::collections::HashMap::new();
                let mut pending_requests: std::collections::HashMap<OutboundRequestId, oneshot::Sender<Result<MydiaResponse, String>>> = std::collections::HashMap::new();

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
                                    request_response::Event::Message { peer, message } => {
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
}
