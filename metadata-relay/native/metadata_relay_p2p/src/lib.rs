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

/// Start a P2P host using iroh.
///
/// Note: With the migration to iroh, the metadata-relay no longer needs to run
/// its own relay server. iroh uses its own public relay infrastructure.
/// This function is kept for backwards compatibility but the host doesn't
/// provide relay functionality - it's just a regular iroh endpoint.
#[rustler::nif]
fn start_relay() -> Result<(ResourceArc<HostResource>, String), rustler::Error> {
    // Get secret key path from environment variable for persistent identity
    let secret_key_path = std::env::var("LIBP2P_KEYPAIR_PATH").ok();

    // Simplified config for iroh - no relay server functionality
    let config = HostConfig {
        relay_url: None,  // Use default iroh relays
        secret_key_path,
    };

    let (host, node_id_str) = Host::new(config);

    let resource = HostResource { host };
    Ok((ResourceArc::new(resource), node_id_str))
}

/// Get the node address for this host.
/// Returns the EndpointAddr as a JSON string.
#[rustler::nif]
fn get_node_addr(resource: ResourceArc<HostResource>) -> String {
    resource.host.get_node_addr()
}

rustler::init!("Elixir.MetadataRelay.P2p", load = load);
