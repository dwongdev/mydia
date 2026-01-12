use rustler::{Env, ResourceArc, Term};
use mydia_p2p_core::Host;

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

rustler::init!("Elixir.Mydia.Libp2p", [start_host, listen], load = load);
