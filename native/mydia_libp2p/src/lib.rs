use rustler::{Env, LocalPid, ResourceArc, Term, OwnedEnv, Encoder, NifStruct, NifTaggedEnum};
use mydia_p2p_core::{Host, Event, MydiaRequest, MydiaResponse, PairingResponse, HostConfig};
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
    rustler::resource!(HostResource, env);
    true
}

#[rustler::nif]
fn start_host() -> Result<(ResourceArc<HostResource>, String), rustler::Error> {
    let config = HostConfig {
        enable_relay_server: false,
        bootstrap_peers: vec![],  // Can be extended to accept custom bootstrap peers
    };
    let (host, peer_id_str) = Host::new(config);
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
fn bootstrap(resource: ResourceArc<HostResource>, addr: String) -> Result<String, rustler::Error> {
    match resource.host.bootstrap(addr) {
        Ok(_) => Ok("ok".to_string()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn provide_claim_code(resource: ResourceArc<HostResource>, claim_code: String) -> Result<String, rustler::Error> {
    match resource.host.provide_claim_code(claim_code) {
        Ok(_) => Ok("ok".to_string()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

#[rustler::nif]
fn get_dht_stats(resource: ResourceArc<HostResource>) -> ElixirDhtStats {
    let stats = resource.host.get_dht_stats();
    ElixirDhtStats {
        routing_table_size: stats.routing_table_size,
        provided_keys_count: stats.provided_keys_count,
        bootstrap_complete: stats.bootstrap_complete,
    }
}

// Mirror structs for Elixir interop
#[derive(NifStruct)]
#[module = "Mydia.Libp2p.DhtStats"]
struct ElixirDhtStats {
    pub routing_table_size: usize,
    pub provided_keys_count: usize,
    pub bootstrap_complete: bool,
}
#[derive(NifStruct)]
#[module = "Mydia.Libp2p.PairingRequest"]
struct ElixirPairingRequest {
    pub claim_code: String,
    pub device_name: String,
    pub device_type: String,
    pub device_os: Option<String>,
}

#[derive(NifStruct)]
#[module = "Mydia.Libp2p.PairingResponse"]
struct ElixirPairingResponse {
    pub success: bool,
    pub media_token: Option<String>,
    pub access_token: Option<String>,
    pub device_token: Option<String>,
    pub error: Option<String>,
}

#[derive(NifStruct)]
#[module = "Mydia.Libp2p.ReadMediaRequest"]
struct ElixirReadMediaRequest {
    pub file_path: String,
    pub offset: u64,
    pub length: u32,
}

#[derive(NifTaggedEnum)]
enum ElixirResponse {
    Pairing(ElixirPairingResponse),
    MediaChunk(Vec<u8>),
    Error(String),
}

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
        ElixirResponse::Error(e) => MydiaResponse::Error(e),
    };

    match resource.host.send_response(request_id, core_response) {
        Ok(_) => Ok("ok".to_string()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

// Helper NIF to read file chunk directly in Rust to avoid passing binary back and forth to Elixir if performance matters.
// But typically Elixir handles this fine. For "Going all the way", let's implement a NIF that reads the file and sends the response directly.
#[rustler::nif]
fn respond_with_file_chunk(resource: ResourceArc<HostResource>, request_id: String, file_path: String, offset: u64, length: u32) -> Result<String, rustler::Error> {
    // Open file, seek, read, send response
    // We should do this in a thread or task to not block the NIF
    // But for simplicity in Rustler, small reads are OK? No, disk I/O should be threaded.
    // Since we are inside a NIF, let's spawn a thread.
    
    // We can't move 'resource' into thread easily without Arc (it is Arc).
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

#[rustler::nif]
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
                    msg_env.send_and_clear(&pid, |env| {
                        match event {
                            Event::PeerDiscovered(peer_id) => {
                                (atoms::ok(), "peer_discovered", peer_id).encode(env)
                            }
                            Event::PeerExpired(peer_id) => {
                                (atoms::ok(), "peer_expired", peer_id).encode(env)
                            }
                            Event::RequestReceived { peer, request, request_id } => {
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
                                    MydiaRequest::Ping => {
                                        (atoms::ok(), "request_received", "ping", request_id).encode(env)
                                    }
                                    _ => (atoms::ok(), "unknown_request").encode(env)
                                }
                            }
                            Event::BootstrapCompleted => {
                                (atoms::ok(), "bootstrap_completed").encode(env)
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

rustler::init!("Elixir.Mydia.Libp2p", load = load);
