use rustler::{Env, LocalPid, ResourceArc, Term, OwnedEnv, Encoder};
use mydia_p2p_core::{Host, Event};
use std::thread;

// Resource to hold the Host state
struct HostResource {
    host: Host,
}

fn load(env: Env, _info: Term) -> bool {
    rustler::resource!(HostResource, env);
    true
}

#[rustler::nif]
fn start_host() -> Result<(ResourceArc<HostResource>, String), rustler::Error> {
    let (host, peer_id_str) = Host::new();
    let resource = HostResource { host };
    Ok((ResourceArc::new(resource), peer_id_str))
}

#[rustler::nif]
fn listen(resource: ResourceArc<HostResource>, addr: String) -> Result<String, rustler::Error> {
    match resource.host.listen(addr) {
        Ok(_) => Ok("ok".to_string()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

#[rustler::nif]
fn dial(resource: ResourceArc<HostResource>, addr: String) -> Result<String, rustler::Error> {
    match resource.host.dial(addr) {
        Ok(_) => Ok("ok".to_string()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

#[rustler::nif]
fn start_listening(env: Env, resource: ResourceArc<HostResource>, pid: LocalPid) -> Result<String, rustler::Error> {
    let host = &resource.host;
    let event_rx = host.event_rx.clone();
    
    // We need to keep a reference to the PID's process monitoring or similar? 
    // Rustler OwnedEnv allows sending messages to a Pid.
    
    thread::spawn(move || {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let mut rx = event_rx.lock().await;
            loop {
                if let Some(event) = rx.recv().await {
                    let mut msg_env = OwnedEnv::new();
                    msg_env.send_and_clear(&pid, |env| {
                        match event {
                            Event::PeerDiscovered(peer_id) => {
                                (rustler::atoms::ok(), "peer_discovered", peer_id).encode(env)
                            }
                            Event::PeerExpired(peer_id) => {
                                (rustler::atoms::ok(), "peer_expired", peer_id).encode(env)
                            }
                            // Stub for request/response for now
                            _ => (rustler::atoms::ok(), "unknown_event").encode(env)
                        }
                    });
                } else {
                    break;
                }
            }
        });
    });

    Ok("ok".to_string())
}

rustler::init!("Elixir.Mydia.Libp2p", [start_host, listen, dial, start_listening], load = load);
