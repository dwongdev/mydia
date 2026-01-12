use libp2p::{
    identity,
    ping,
    mdns,
    kad,
    noise,
    tcp,
    yamux,
    PeerId,
    SwarmBuilder,
    swarm::{NetworkBehaviour, SwarmEvent},
};
use std::time::Duration;
use tokio::runtime::Runtime;
use tokio::sync::mpsc;
use libp2p::futures::StreamExt;

// Define the Network Behaviour
#[derive(NetworkBehaviour)]
pub struct MydiaBehaviour {
    ping: ping::Behaviour,
    mdns: mdns::tokio::Behaviour,
    kad: kad::Behaviour<kad::store::MemoryStore>,
}

// Commands that can be sent to the Host
pub enum Command {
    Listen(String),
}

// The core Host struct that manages the Libp2p Swarm
pub struct Host {
    pub cmd_tx: mpsc::Sender<Command>,
    pub peer_id: PeerId,
}

impl Host {
    pub fn new() -> (Self, String) {
        let id_keys = identity::Keypair::generate_ed25519();
        let peer_id = PeerId::from(id_keys.public());
        let peer_id_str = peer_id.to_string();

        let (cmd_tx, mut cmd_rx) = mpsc::channel::<Command>(32);

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
                        let mdns = mdns::tokio::Behaviour::new(mdns::Config::default(), peer_id).unwrap();
                        let kad_store = kad::store::MemoryStore::new(peer_id);
                        let kad = kad::Behaviour::new(peer_id, kad_store);
                        
                        MydiaBehaviour {
                            ping: ping::Behaviour::new(ping::Config::new().with_interval(Duration::from_secs(1))),
                            mdns,
                            kad,
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
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::Ping(event)) => {
                                println!("Libp2p Ping: {:?}", event);
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::Mdns(mdns::Event::Discovered(list))) => {
                                for (peer_id, _multiaddr) in list {
                                    println!("mDNS discovered: {:?}", peer_id);
                                    swarm.behaviour_mut().kad.add_address(&peer_id, _multiaddr);
                                }
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::Mdns(mdns::Event::Expired(list))) => {
                                for (peer_id, _multiaddr) in list {
                                    println!("mDNS expired: {:?}", peer_id);
                                }
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::Kad(kad::Event::RoutingUpdated { peer, .. })) => {
                                println!("Kad routing updated: {:?}", peer);
                            }
                            _ => {}
                        },
                        command = cmd_rx.recv() => match command {
                            Some(Command::Listen(addr_str)) => {
                                match addr_str.parse() {
                                    Ok(addr) => {
                                        match swarm.listen_on(addr) {
                                            Ok(_) => println!("Listening on {}", addr_str),
                                            Err(e) => println!("Failed to listen on {}: {:?}", addr_str, e),
                                        }
                                    }
                                    Err(e) => println!("Invalid multiaddr {}: {:?}", addr_str, e),
                                }
                            }
                            None => return, // Channel closed
                        }
                    }
                }
            });
        });

        (Host { cmd_tx, peer_id }, peer_id_str)
    }

    pub fn listen(&self, addr: String) -> Result<(), String> {
        match self.cmd_tx.blocking_send(Command::Listen(addr)) {
            Ok(_) => Ok(()),
            Err(_) => Err("send_failed".to_string()),
        }
    }
}
