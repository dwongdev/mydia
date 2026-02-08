//! NIF bindings for mydia_p2p_core (iroh-based)
//!
//! Provides Erlang/Elixir interop for the p2p networking functionality.

use rustler::{Env, LocalPid, ResourceArc, Term, OwnedEnv, Encoder, NifStruct, NifTaggedEnum};
use mydia_p2p_core::{Host, Event, MydiaRequest, MydiaResponse, PairingResponse, GraphQLResponse, HlsResponseHeader, HostConfig, LogLevel, BlobDownloadResponse};
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
/// keypair_path: Path to store/load the node's keypair for persistent identity.
/// Returns (resource, node_id_string).
#[rustler::nif]
fn start_host(relay_url: Option<String>, bind_port: Option<u16>, keypair_path: Option<String>) -> Result<(ResourceArc<HostResource>, String), rustler::Error> {
    let config = HostConfig {
        relay_url,
        bind_port,
        keypair_path,
        ..Default::default()
    };
    let (host, node_id_str) = Host::new(config);
    let resource = HostResource { host };
    Ok((ResourceArc::new(resource), node_id_str))
}

/// Dial a peer using their EndpointAddr JSON.
#[rustler::nif(schedule = "DirtyIo")]
fn dial(resource: ResourceArc<HostResource>, endpoint_addr_json: String) -> Result<String, rustler::Error> {
    match resource.host.dial(endpoint_addr_json) {
        Ok(_) => Ok("ok".to_string()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

/// Get this node's EndpointAddr as JSON for sharing.
#[rustler::nif(schedule = "DirtyIo")]
fn get_node_addr(resource: ResourceArc<HostResource>) -> String {
    resource.host.get_node_addr()
}

/// Get network statistics.
#[rustler::nif(schedule = "DirtyIo")]
fn get_network_stats(resource: ResourceArc<HostResource>) -> ElixirNetworkStats {
    let stats = resource.host.get_network_stats();
    ElixirNetworkStats {
        connected_peers: stats.connected_peers,
        relay_connected: stats.relay_connected,
        relay_url: stats.relay_url,
    }
}

// Mirror structs for Elixir interop
#[derive(NifStruct)]
#[module = "Mydia.P2p.NetworkStats"]
struct ElixirNetworkStats {
    pub connected_peers: usize,
    pub relay_connected: bool,
    pub relay_url: Option<String>,
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
    pub direct_urls: Vec<String>,
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

#[derive(NifStruct)]
#[module = "Mydia.P2p.HlsRequest"]
struct ElixirHlsRequest {
    pub session_id: String,
    pub path: String,
    pub range_start: Option<u64>,
    pub range_end: Option<u64>,
    pub auth_token: Option<String>,
}

#[derive(NifStruct)]
#[module = "Mydia.P2p.HlsResponseHeader"]
struct ElixirHlsResponseHeader {
    pub status: u16,
    pub content_type: String,
    pub content_length: u64,
    pub content_range: Option<String>,
    pub cache_control: Option<String>,
}

#[derive(NifStruct)]
#[module = "Mydia.P2p.BlobDownloadRequest"]
struct ElixirBlobDownloadRequest {
    pub job_id: String,
    pub auth_token: Option<String>,
}

#[derive(NifStruct)]
#[module = "Mydia.P2p.BlobDownloadResponse"]
struct ElixirBlobDownloadResponse {
    pub success: bool,
    pub ticket: Option<String>,
    pub filename: Option<String>,
    pub file_size: Option<u64>,
    pub error: Option<String>,
}

#[derive(NifTaggedEnum)]
enum ElixirResponse {
    Pairing(ElixirPairingResponse),
    MediaChunk(Vec<u8>),
    Graphql(ElixirGraphQLResponse),
    BlobDownload(ElixirBlobDownloadResponse),
    Error(String),
}

/// Send a response to an incoming request.
#[rustler::nif(schedule = "DirtyIo")]
fn send_response(resource: ResourceArc<HostResource>, request_id: String, response: ElixirResponse) -> Result<String, rustler::Error> {
    let core_response = match response {
        ElixirResponse::Pairing(r) => MydiaResponse::Pairing(PairingResponse {
            success: r.success,
            media_token: r.media_token,
            access_token: r.access_token,
            device_token: r.device_token,
            error: r.error,
            direct_urls: r.direct_urls,
        }),
        ElixirResponse::MediaChunk(data) => MydiaResponse::MediaChunk(data),
        ElixirResponse::Graphql(r) => MydiaResponse::GraphQL(GraphQLResponse {
            data: r.data,
            errors: r.errors,
        }),
        ElixirResponse::BlobDownload(r) => MydiaResponse::BlobDownload(BlobDownloadResponse {
            success: r.success,
            ticket: r.ticket,
            filename: r.filename,
            file_size: r.file_size,
            error: r.error,
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

/// Send an HLS response header for a streaming request.
/// Must be called before any send_hls_chunk calls.
/// Uses DirtyIo scheduler because blocking_send/blocking_recv block the thread.
#[rustler::nif(schedule = "DirtyIo")]
fn send_hls_header(resource: ResourceArc<HostResource>, stream_id: String, header: ElixirHlsResponseHeader) -> Result<String, rustler::Error> {
    let core_header = HlsResponseHeader {
        status: header.status,
        content_type: header.content_type,
        content_length: header.content_length,
        content_range: header.content_range,
        cache_control: header.cache_control,
    };

    match resource.host.send_hls_header(stream_id, core_header) {
        Ok(_) => Ok("ok".to_string()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

/// Send a chunk of HLS data.
/// Must be called after send_hls_header and before finish_hls_stream.
/// Uses DirtyIo scheduler because blocking_send/blocking_recv block the thread.
#[rustler::nif(schedule = "DirtyIo")]
fn send_hls_chunk(resource: ResourceArc<HostResource>, stream_id: String, data: Vec<u8>) -> Result<String, rustler::Error> {
    match resource.host.send_hls_chunk(stream_id, data) {
        Ok(_) => Ok("ok".to_string()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

/// Finish an HLS stream.
/// Must be called after all chunks have been sent.
/// Uses DirtyIo scheduler because blocking_send/blocking_recv block the thread.
#[rustler::nif(schedule = "DirtyIo")]
fn finish_hls_stream(resource: ResourceArc<HostResource>, stream_id: String) -> Result<String, rustler::Error> {
    match resource.host.finish_hls_stream(stream_id) {
        Ok(_) => Ok("ok".to_string()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

/// Create a blob ticket from a file for P2P download.
///
/// This computes the content hash and creates a ticket that clients can use
/// to verify and download the file. The file is served via HLS streaming.
///
/// Returns a JSON ticket containing:
/// - hash: BLAKE3 hash of the file content
/// - file_size: size in bytes
/// - filename: original filename
#[rustler::nif(schedule = "DirtyCpu")]
fn create_blob_ticket(file_path: String, filename: String) -> Result<String, rustler::Error> {
    use std::io::BufReader;

    // Open and read the file
    let file = match File::open(&file_path) {
        Ok(f) => f,
        Err(e) => return Err(rustler::Error::Term(Box::new(format!("Failed to open file: {}", e)))),
    };

    let metadata = match file.metadata() {
        Ok(m) => m,
        Err(e) => return Err(rustler::Error::Term(Box::new(format!("Failed to get metadata: {}", e)))),
    };

    let file_size = metadata.len();

    // Compute BLAKE3 hash (matching iroh-blobs which uses BLAKE3)
    let mut reader = BufReader::new(file);
    let mut hasher = blake3::Hasher::new();
    let mut buffer = [0u8; 64 * 1024]; // 64KB buffer

    loop {
        let bytes_read = match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => return Err(rustler::Error::Term(Box::new(format!("Failed to read file: {}", e)))),
        };
        hasher.update(&buffer[..bytes_read]);
    }

    let hash = hasher.finalize();

    // Create a JSON ticket
    let ticket = serde_json::json!({
        "hash": hash.to_string(),
        "file_size": file_size,
        "filename": filename,
        "file_path": file_path,
    });

    Ok(ticket.to_string())
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
                                    MydiaRequest::BlobDownload(req) => {
                                        let elixir_req = ElixirBlobDownloadRequest {
                                            job_id: req.job_id,
                                            auth_token: req.auth_token,
                                        };
                                        (atoms::ok(), "request_received", "blob_download", request_id, elixir_req).encode(env)
                                    },
                                    MydiaRequest::Ping => {
                                        (atoms::ok(), "request_received", "ping", request_id).encode(env)
                                    }
                                    _ => (atoms::ok(), "unknown_request").encode(env)
                                }
                            }
                            Event::HlsStreamRequest { peer: _, request, stream_id } => {
                                let elixir_req = ElixirHlsRequest {
                                    session_id: request.session_id,
                                    path: request.path,
                                    range_start: request.range_start,
                                    range_end: request.range_end,
                                    auth_token: request.auth_token,
                                };
                                (atoms::ok(), "hls_stream", stream_id, elixir_req).encode(env)
                            }
                            Event::RelayConnected => {
                                (atoms::ok(), "relay_connected").encode(env)
                            }
                            Event::Ready { node_addr } => {
                                (atoms::ok(), "ready", node_addr).encode(env)
                            }
                            Event::Log { level, target, message } => {
                                let level_str = match level {
                                    LogLevel::Trace => "trace",
                                    LogLevel::Debug => "debug",
                                    LogLevel::Info => "info",
                                    LogLevel::Warn => "warn",
                                    LogLevel::Error => "error",
                                };
                                (atoms::ok(), "log", level_str, target, message).encode(env)
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
