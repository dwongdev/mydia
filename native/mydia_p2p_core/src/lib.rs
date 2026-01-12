use libp2p::{
    identity,
    ping,
    mdns,
    kad,
    noise,
    tcp,
    yamux,
    request_response::{self, ProtocolSupport},
    PeerId,
    SwarmBuilder,
    Multiaddr,
    swarm::{NetworkBehaviour, SwarmEvent},
};
use std::time::Duration;
use tokio::runtime::Runtime;
use tokio::sync::mpsc;
use libp2p::futures::StreamExt;
use std::iter;

// Define the Network Behaviour
#[derive(NetworkBehaviour)]
pub struct MydiaBehaviour {
    ping: ping::Behaviour,
    mdns: mdns::tokio::Behaviour,
    kad: kad::Behaviour<kad::store::MemoryStore>,
    request_response: request_response::cbor::Behaviour<MydiaRequest, MydiaResponse>,
}

// Request/Response Types (using Serde/CBOR)
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum MydiaRequest {
    Ping,
    Custom(Vec<u8>),
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum MydiaResponse {
    Pong,
    Custom(Vec<u8>),
    Error(String),
}

// Commands that can be sent to the Host
pub enum Command {
    Listen(String),
    Dial(String),
    SendRequest { peer: String, request: MydiaRequest },
}

// Events emitted by the Host
#[derive(Debug)]
pub enum Event {
    PeerDiscovered(String),
    PeerExpired(String),
    RequestReceived { peer: String, request: MydiaRequest, response_channel: request_response::ResponseChannel<MydiaResponse> },
    ResponseReceived { peer: String, response: MydiaResponse, request_id: String },
}

// The core Host struct that manages the Libp2p Swarm
pub struct Host {
    pub cmd_tx: mpsc::Sender<Command>,
    pub event_rx: std::sync::Arc<tokio::sync::Mutex<mpsc::Receiver<Event>>>, // Wrapped in Mutex for easy sharing (though Rx is not Sync, Arc<Mutex> is)
    pub peer_id: PeerId,
}

impl Host {
    pub fn new() -> (Self, String) {
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
                    .with_behaviour(|key| {
                        let peer_id = PeerId::from(key.public());
                        
                        // mDNS
                        let mdns = mdns::tokio::Behaviour::new(mdns::Config::default(), peer_id).unwrap();
                        
                        // Kademlia
                        let kad_store = kad::store::MemoryStore::new(peer_id);
                        let kad = kad::Behaviour::new(peer_id, kad_store);
                        
                        // Request Response
                        let request_response = request_response::cbor::Behaviour::new(
                            [(
                                libp2p::StreamProtocol::new("/mydia/1.0.0"),
                                ProtocolSupport::Full,
                            )],
                            request_response::Config::default(),
                        );

                        MydiaBehaviour {
                            ping: ping::Behaviour::new(ping::Config::new().with_interval(Duration::from_secs(1))),
                            mdns,
                            kad,
                            request_response,
                        }
                    })
                    .unwrap()
                    .with_swarm_config(|c| c.with_idle_connection_timeout(Duration::from_secs(60)))
                    .build();

                // Use Server mode for Kademlia
                swarm.behaviour_mut().kad.set_mode(Some(kad::Mode::Server));

                loop {
                    tokio::select! {
                        event = swarm.select_next_some() => match event {
                            SwarmEvent::NewListenAddr { address, .. } => {
                                println!("Libp2p listening on {:?}", address);
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::Mdns(mdns::Event::Discovered(list))) => {
                                for (peer_id, _multiaddr) in list {
                                    println!("mDNS discovered: {:?}", peer_id);
                                    swarm.behaviour_mut().kad.add_address(&peer_id, _multiaddr);
                                    let _ = event_tx.send(Event::PeerDiscovered(peer_id.to_string())).await;
                                }
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::Mdns(mdns::Event::Expired(list))) => {
                                for (peer_id, _multiaddr) in list {
                                    println!("mDNS expired: {:?}", peer_id);
                                    let _ = event_tx.send(Event::PeerExpired(peer_id.to_string())).await;
                                }
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::RequestResponse(request_response::Event::Message { peer, message })) => {
                                match message {
                                    request_response::Message::Request { request, channel, .. } => {
                                        let _ = event_tx.send(Event::RequestReceived {
                                            peer: peer.to_string(),
                                            request,
                                            response_channel: channel,
                                        }).await;
                                    }
                                    request_response::Message::Response { response, request_id } => {
                                        let _ = event_tx.send(Event::ResponseReceived {
                                            peer: peer.to_string(),
                                            response,
                                            request_id: request_id.to_string(),
                                        }).await;
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
                            Some(Command::SendRequest { peer, request }) => {
                                if let Ok(peer_id) = peer.parse::<PeerId>() {
                                    swarm.behaviour_mut().request_response.send_request(&peer_id, request);
                                }
                            }
                            None => return, // Channel closed
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
}
