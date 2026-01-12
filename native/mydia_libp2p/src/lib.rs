use rustler::{Env, LocalPid, ResourceArc, Term, OwnedEnv, Encoder, NifStruct, NifTaggedEnum};
use mydia_p2p_core::{Host, Event, MydiaRequest, MydiaResponse, PairingRequest, PairingResponse};
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

// Mirror structs for Elixir interop
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

#[derive(NifTaggedEnum)]
enum ElixirResponse {
    Pairing(ElixirPairingResponse),
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
        ElixirResponse::Error(e) => MydiaResponse::Error(e),
    };

    match resource.host.send_response(request_id, core_response) {
        Ok(_) => Ok("ok".to_string()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
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
                                (rustler::atoms::ok(), "peer_discovered", peer_id).encode(env)
                            }
                            Event::PeerExpired(peer_id) => {
                                (rustler::atoms::ok(), "peer_expired", peer_id).encode(env)
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
                                        (rustler::atoms::ok(), "request_received", "pairing", request_id, elixir_req).encode(env)
                                    },
                                    MydiaRequest::Ping => {
                                        (rustler::atoms::ok(), "request_received", "ping", request_id).encode(env)
                                    }
                                    _ => (rustler::atoms::ok(), "unknown_request").encode(env)
                                }
                            }
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

rustler::init!("Elixir.Mydia.Libp2p", [start_host, listen, dial, start_listening, send_response], load = load);
