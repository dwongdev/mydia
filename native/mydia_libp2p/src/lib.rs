use rustler::{Env, ResourceArc, Term};
use libp2p::{
    identity,
    ping,
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
struct MyBehaviour {
    ping: ping::Behaviour,
}

// Resource to hold the Host state (channel to the background task)
struct HostResource {
    cmd_tx: mpsc::Sender<Command>,
}

enum Command {
    Listen(String),
}

fn load(env: Env, _info: Term) -> bool {
    rustler::resource!(HostResource, env);
    true
}

#[rustler::nif]
fn start_host() -> Result<(ResourceArc<HostResource>, String), rustler::Error> {
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
                .with_behaviour(|_| MyBehaviour {
                    ping: ping::Behaviour::new(ping::Config::new().with_interval(Duration::from_secs(1))),
                })
                .unwrap()
                .with_swarm_config(|c| c.with_idle_connection_timeout(Duration::from_secs(60)))
                .build();

            loop {
                tokio::select! {
                    event = swarm.select_next_some() => match event {
                        SwarmEvent::NewListenAddr { address, .. } => {
                            println!("Libp2p listening on {:?}", address);
                        }
                        SwarmEvent::Behaviour(MyBehaviourEvent::Ping(event)) => {
                            println!("Libp2p Ping: {:?}", event);
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

    let resource = HostResource { cmd_tx };
    Ok((ResourceArc::new(resource), peer_id_str))
}

#[rustler::nif]
fn listen(resource: ResourceArc<HostResource>, addr: String) -> Result<String, rustler::Error> {
    let tx = resource.cmd_tx.clone();
    // Use blocking_send since we are not in an async context
    match tx.blocking_send(Command::Listen(addr)) {
        Ok(_) => Ok("ok".to_string()),
        Err(_) => Err(rustler::Error::Term(Box::new("send_failed"))),
    }
}

rustler::init!("Elixir.Mydia.Libp2p", [start_host, listen], load = load);
