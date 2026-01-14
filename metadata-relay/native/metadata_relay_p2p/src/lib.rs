use rustler::{Env, ResourceArc, Term};
use mydia_p2p_core::{Host, HostConfig};

// Resource to hold the Host state
struct HostResource {
    host: Host,
}

fn load(env: Env, _info: Term) -> bool {
    rustler::resource!(HostResource, env);
    true
}

#[rustler::nif]
fn start_relay() -> Result<(ResourceArc<HostResource>, String), rustler::Error> {
    // Get keypair path from environment variable for persistent peer ID
    let keypair_path = std::env::var("LIBP2P_KEYPAIR_PATH").ok();
    
    // Enable Relay Server with default bootstrap peers
    let config = HostConfig { 
        enable_relay_server: true,
        enable_rendezvous_server: true,
        bootstrap_peers: vec![],
        keypair_path,
        ..Default::default()
    };
    let (host, peer_id_str) = Host::new(config);
    
    // We can also start listening immediately on a standard port if configured,
    // or let Elixir call listen().
    
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
fn add_external_address(resource: ResourceArc<HostResource>, addr: String) -> Result<String, rustler::Error> {
    match resource.host.add_external_address(addr) {
        Ok(_) => Ok("ok".to_string()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

rustler::init!("Elixir.MetadataRelay.P2p", [start_relay, listen, add_external_address], load = load);
