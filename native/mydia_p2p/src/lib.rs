//! NIF bindings for mydia_p2p_core (iroh-based)
//!
//! Provides Erlang/Elixir interop for the p2p networking functionality.

use rustler::{Env, LocalPid, ResourceArc, Term, OwnedEnv, Encoder, NifStruct, NifTaggedEnum};
use mydia_p2p_core::{Host, Event, MydiaRequest, MydiaResponse, PairingResponse, GraphQLResponse, HostConfig};
use std::thread;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};

mod atoms {
    rustler::atoms! {
        ok,
    }
}

// Resource to hold the Host state
struct HostResource {
    host: Host,
}

fn load(env: Env, _info: Term) -> bool {
    let _ = rustler::resource!(HostResource, env);
    true
}

/// Start the p2p host with configuration.
/// relay_url: Custom relay URL for NAT traversal (uses default relays if None).
/// bind_port: UDP port for direct connections (0 or None for random port).
/// Returns (resource, node_id_string).
#[rustler::nif]
fn start_host(relay_url: Option<String>, bind_port: Option<u16>) -> Result<(ResourceArc<HostResource>, String), rustler::Error> {
    let config = HostConfig {
        relay_url,
        bind_port,
        ..Default::default()
    };
    let (host, node_id_str) = Host::new(config);
    let resource = HostResource { host };
    Ok((ResourceArc::new(resource), node_id_str))
}

/// Dial a peer using their EndpointAddr JSON.
#[rustler::nif]
fn dial(resource: ResourceArc<HostResource>, endpoint_addr_json: String) -> Result<String, rustler::Error> {
    match resource.host.dial(endpoint_addr_json) {
        Ok(_) => Ok("ok".to_string()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

/// Get this node's EndpointAddr as JSON for sharing.
#[rustler::nif]
fn get_node_addr(resource: ResourceArc<HostResource>) -> String {
    resource.host.get_node_addr()
}

/// Get network statistics.
#[rustler::nif]
fn get_network_stats(resource: ResourceArc<HostResource>) -> ElixirNetworkStats {
    let stats = resource.host.get_network_stats();
    ElixirNetworkStats {
        connected_peers: stats.connected_peers,
        relay_connected: stats.relay_connected,
    }
}

// Mirror structs for Elixir interop
#[derive(NifStruct)]
#[module = "Mydia.P2p.NetworkStats"]
struct ElixirNetworkStats {
    pub connected_peers: usize,
    pub relay_connected: bool,
}

#[derive(NifStruct)]
#[module = "Mydia.P2p.PairingRequest"]
struct ElixirPairingRequest {
    pub claim_code: String,
    pub device_name: String,
    pub device_type: String,
    pub device_os: Option<String>,
}

#[derive(NifStruct)]
#[module = "Mydia.P2p.PairingResponse"]
struct ElixirPairingResponse {
    pub success: bool,
    pub media_token: Option<String>,
    pub access_token: Option<String>,
    pub device_token: Option<String>,
    pub error: Option<String>,
}

#[derive(NifStruct)]
#[module = "Mydia.P2p.ReadMediaRequest"]
struct ElixirReadMediaRequest {
    pub file_path: String,
    pub offset: u64,
    pub length: u32,
}

#[derive(NifStruct)]
#[module = "Mydia.P2p.GraphQLRequest"]
struct ElixirGraphQLRequest {
    pub query: String,
    pub variables: Option<String>,
    pub operation_name: Option<String>,
    pub auth_token: Option<String>,
}

#[derive(NifStruct)]
#[module = "Mydia.P2p.GraphQLResponse"]
struct ElixirGraphQLResponse {
    pub data: Option<String>,
    pub errors: Option<String>,
}

#[derive(NifTaggedEnum)]
enum ElixirResponse {
    Pairing(ElixirPairingResponse),
    MediaChunk(Vec<u8>),
    GraphQL(ElixirGraphQLResponse),
    Error(String),
}

/// Send a response to an incoming request.
#[rustler::nif]
fn send_response(resource: ResourceArc<HostResource>, request_id: String, response: ElixirResponse) -> Result<String, rustler::Error> {
    let core_response = match response {
        ElixirResponse::Pairing(r) => MydiaResponse::Pairing(PairingResponse {
            success: r.success,
            media_token: r.media_token,
            access_token: r.access_token,
            device_token: r.device_token,
            error: r.error,
        }),
        ElixirResponse::MediaChunk(data) => MydiaResponse::MediaChunk(data),
        ElixirResponse::GraphQL(r) => MydiaResponse::GraphQL(GraphQLResponse {
            data: r.data,
            errors: r.errors,
        }),
        ElixirResponse::Error(e) => MydiaResponse::Error(e),
    };

    match resource.host.send_response(request_id, core_response) {
        Ok(_) => Ok("ok".to_string()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

/// Read a file chunk and send it as a response.
/// This is done in a separate thread to avoid blocking the NIF.
#[rustler::nif]
fn respond_with_file_chunk(resource: ResourceArc<HostResource>, request_id: String, file_path: String, offset: u64, length: u32) -> Result<String, rustler::Error> {
    let resource_clone = resource.clone();

    thread::spawn(move || {
        let response = match File::open(&file_path) {
            Ok(mut file) => {
                if file.seek(SeekFrom::Start(offset)).is_ok() {
                    let mut buffer = vec![0; length as usize];
                    match file.read(&mut buffer) {
                        Ok(n) => {
                            buffer.truncate(n);
                            MydiaResponse::MediaChunk(buffer)
                        }
                        Err(e) => MydiaResponse::Error(format!("Read error: {}", e))
                    }
                } else {
                    MydiaResponse::Error("Seek error".to_string())
                }
            }
            Err(e) => MydiaResponse::Error(format!("File open error: {}", e))
        };

        let _ = resource_clone.host.send_response(request_id, response);
    });

    Ok("ok".to_string())
}

/// Start listening for events and forward them to the given Elixir process.
#[rustler::nif]
#[allow(unused_variables)]
fn start_listening(env: Env, resource: ResourceArc<HostResource>, pid: LocalPid) -> Result<String, rustler::Error> {
    let host = &resource.host;
    let event_rx = host.event_rx.clone();

    thread::spawn(move || {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let mut rx = event_rx.lock().await;
            loop {
                if let Some(event) = rx.recv().await {
                    let mut msg_env = OwnedEnv::new();
                    let _ = msg_env.send_and_clear(&pid, |env| {
                        match event {
                            Event::Connected(peer_id) => {
                                (atoms::ok(), "peer_connected", peer_id).encode(env)
                            }
                            Event::Disconnected(peer_id) => {
                                (atoms::ok(), "peer_disconnected", peer_id).encode(env)
                            }
                            Event::RequestReceived { peer: _, request, request_id } => {
                                match request {
                                    MydiaRequest::Pairing(req) => {
                                        let elixir_req = ElixirPairingRequest {
                                            claim_code: req.claim_code,
                                            device_name: req.device_name,
                                            device_type: req.device_type,
                                            device_os: req.device_os,
                                        };
                                        (atoms::ok(), "request_received", "pairing", request_id, elixir_req).encode(env)
                                    },
                                    MydiaRequest::ReadMedia(req) => {
                                        let elixir_req = ElixirReadMediaRequest {
                                            file_path: req.file_path,
                                            offset: req.offset,
                                            length: req.length,
                                        };
                                        (atoms::ok(), "request_received", "read_media", request_id, elixir_req).encode(env)
                                    },
                                    MydiaRequest::GraphQL(req) => {
                                        let elixir_req = ElixirGraphQLRequest {
                                            query: req.query,
                                            variables: req.variables,
                                            operation_name: req.operation_name,
                                            auth_token: req.auth_token,
                                        };
                                        (atoms::ok(), "request_received", "graphql", request_id, elixir_req).encode(env)
                                    },
                                    MydiaRequest::Ping => {
                                        (atoms::ok(), "request_received", "ping", request_id).encode(env)
                                    }
                                    _ => (atoms::ok(), "unknown_request").encode(env)
                                }
                            }
                            Event::RelayConnected => {
                                (atoms::ok(), "relay_connected").encode(env)
                            }
                            Event::Ready { node_addr } => {
                                (atoms::ok(), "ready", node_addr).encode(env)
                            }
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

rustler::init!("Elixir.Mydia.P2p", load = load);
