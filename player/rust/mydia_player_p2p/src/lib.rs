mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
use mydia_p2p_core::{Host, Event, MydiaRequest, MydiaResponse, PairingRequest, GraphQLRequest, HlsRequest, BlobDownloadRequest, HostConfig, PeerConnectionType};
use flutter_rust_bridge::frb;
use crate::frb_generated::StreamSink;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

#[frb(init)]
pub fn init_app() {
    // Default utilities - e.g. logging
    flutter_rust_bridge::setup_default_user_utils();

    // Initialize Android logging for log:: macros
    #[cfg(target_os = "android")]
    android_logger::init_once(
        android_logger::Config::default()
            .with_max_level(log::LevelFilter::Debug)
            .with_filter(android_logger::FilterBuilder::new()
                .parse("info,mydia=debug,iroh=info,iroh_quinn=warn,iroh_quinn_proto=warn,yamux=warn,netlink_proto=warn")
                .build())
            .with_tag("mydia_p2p"),
    );

    // Initialize tracing for mydia_p2p_core and iroh (which use tracing:: macros)
    // This must be done BEFORE Host::new() is called to capture iroh's startup logs
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info,mydia_p2p_core=debug,iroh=info,quinn=warn,rustls=warn"));

    #[cfg(target_os = "android")]
    {
        // On Android, use tracing-android to forward tracing events to logcat
        let _ = tracing_subscriber::registry()
            .with(filter)
            .with(tracing_android::layer("mydia_p2p").unwrap())
            .try_init();
    }

    #[cfg(not(target_os = "android"))]
    {
        // On other platforms, use standard fmt subscriber
        let _ = tracing_subscriber::registry()
            .with(filter)
            .with(tracing_subscriber::fmt::layer())
            .try_init();
    }

    log::info!("mydia_player_p2p initialized");
}

pub struct P2pHost {
    inner: Host,
}

pub struct FlutterPairingRequest {
    pub claim_code: String,
    pub device_name: String,
    pub device_type: String,
    pub device_os: Option<String>,
}

pub struct FlutterPairingResponse {
    pub success: bool,
    pub media_token: Option<String>,
    pub access_token: Option<String>,
    pub device_token: Option<String>,
    pub error: Option<String>,
    pub direct_urls: Vec<String>,
}

/// Connection type for a peer (relay vs direct) for display in Flutter UI
#[frb(non_opaque)]
pub enum FlutterConnectionType {
    /// Direct peer-to-peer connection
    Direct,
    /// Connection via relay server
    Relay,
    /// Using both relay and direct paths
    Mixed,
    /// No active connection
    None,
}

impl From<PeerConnectionType> for FlutterConnectionType {
    fn from(ct: PeerConnectionType) -> Self {
        match ct {
            PeerConnectionType::Direct => FlutterConnectionType::Direct,
            PeerConnectionType::Relay => FlutterConnectionType::Relay,
            PeerConnectionType::Mixed => FlutterConnectionType::Mixed,
            PeerConnectionType::None => FlutterConnectionType::None,
        }
    }
}

/// Network statistics for display in the UI
pub struct FlutterNetworkStats {
    pub connected_peers: usize,
    pub relay_connected: bool,
    /// The relay URL currently in use (extracted from endpoint address)
    pub relay_url: Option<String>,
    /// Connection type for the connected peer (relay vs direct)
    pub peer_connection_type: FlutterConnectionType,
}

/// GraphQL request to send over P2P
pub struct FlutterGraphQLRequest {
    pub query: String,
    pub variables: Option<String>,
    pub operation_name: Option<String>,
    pub auth_token: Option<String>,
}

/// GraphQL response received over P2P
pub struct FlutterGraphQLResponse {
    pub data: Option<String>,
    pub errors: Option<String>,
}

/// HLS request to send over P2P
pub struct FlutterHlsRequest {
    pub session_id: String,
    pub path: String,
    pub range_start: Option<u64>,
    pub range_end: Option<u64>,
    pub auth_token: Option<String>,
}

/// HLS response header received over P2P
pub struct FlutterHlsResponseHeader {
    pub status: u16,
    pub content_type: String,
    pub content_length: u64,
    pub content_range: Option<String>,
    pub cache_control: Option<String>,
}

/// HLS stream event (header or chunk)
#[frb(non_opaque)]
pub enum FlutterHlsStreamEvent {
    Header(FlutterHlsResponseHeader),
    Chunk(Vec<u8>),
    End,
    Error(String),
}

/// HLS stream complete response (non-streaming version)
pub struct FlutterHlsResponse {
    pub header: FlutterHlsResponseHeader,
    pub data: Vec<u8>,
}

/// Request to download a file as a blob over P2P
pub struct FlutterBlobDownloadRequest {
    pub job_id: String,
    pub auth_token: Option<String>,
}

/// Response with blob ticket for downloading
pub struct FlutterBlobDownloadResponse {
    pub success: bool,
    /// The blob ticket as a JSON string containing hash, file_size, filename, file_path
    pub ticket: Option<String>,
    /// Original filename for the downloaded file
    pub filename: Option<String>,
    /// File size in bytes
    pub file_size: Option<u64>,
    /// Error message if failed
    pub error: Option<String>,
}

/// Progress event for blob downloads
#[frb(non_opaque)]
pub enum FlutterBlobDownloadProgress {
    /// Download started with total size
    Started { total_size: u64 },
    /// Progress update with bytes downloaded
    Progress { downloaded: u64, total: u64 },
    /// Download completed with file path
    Completed { file_path: String },
    /// Download failed with error
    Failed { error: String },
}

/// Parsed blob ticket data
pub struct BlobTicket {
    pub hash: String,
    pub file_size: u64,
    pub filename: String,
    pub file_path: String,
}

impl P2pHost {
    /// Initialize a new P2P host with optional custom relay URL.
    #[frb(sync)]
    pub fn init(relay_url: Option<String>) -> (Self, String) {
        log::info!("P2pHost::init() called with relay_url: {:?}", relay_url);
        let config = HostConfig {
            relay_url,
            bind_port: None,
            keypair_path: None,
        };
        let (host, node_id) = Host::new(config);
        log::info!("P2pHost created with node_id: {}", node_id);
        (P2pHost { inner: host }, node_id)
    }

    /// Get this node's EndpointAddr as JSON for sharing.
    #[frb(sync)]
    pub fn get_node_addr(&self) -> String {
        self.inner.get_node_addr()
    }

    /// Dial a peer using their EndpointAddr JSON.
    pub fn dial(&self, endpoint_addr_json: String) -> anyhow::Result<()> {
        log::info!("P2pHost::dial() called");
        match self.inner.dial(endpoint_addr_json) {
            Ok(_) => {
                log::info!("dial() succeeded");
                Ok(())
            }
            Err(e) => {
                log::error!("dial() failed: {}", e);
                Err(anyhow::anyhow!("dial failed: {}", e))
            }
        }
    }

    /// Start streaming events to Flutter.
    pub fn event_stream(&self, sink: StreamSink<String>) -> anyhow::Result<()> {
        log::info!("P2pHost::event_stream() called");
        let rx = self.inner.event_rx.clone();

        std::thread::spawn(move || {
            log::info!("event_stream thread started");
            let rt = match tokio::runtime::Runtime::new() {
                Ok(rt) => rt,
                Err(e) => {
                    log::error!("Failed to create Tokio runtime for event_stream: {}", e);
                    return;
                }
            };
            rt.block_on(async move {
                let mut rx = rx.lock().await;
                log::info!("event_stream listening for events");
                while let Some(event) = rx.recv().await {
                    let msg = match event {
                        Event::Connected(peer_id) => format!("connected:{}", peer_id),
                        Event::Disconnected(peer_id) => format!("disconnected:{}", peer_id),
                        Event::RelayConnected => "relay_connected".to_string(),
                        Event::Ready { node_addr } => format!("ready:{}", node_addr),
                        Event::RequestReceived { .. } => {
                            // Client doesn't handle incoming requests
                            continue;
                        }
                        Event::HlsStreamRequest { .. } => {
                            // Client doesn't handle incoming HLS requests
                            continue;
                        }
                        Event::Log { .. } => {
                            // Logs are handled separately via android_logger/tracing
                            continue;
                        }
                    };
                    log::debug!("event_stream received: {}", msg);
                    if sink.add(msg).is_err() {
                        log::warn!("event_stream sink closed, exiting");
                        break;
                    }
                }
                log::info!("event_stream loop ended");
            });
        });
        Ok(())
    }

    /// Send a pairing request to a specific peer.
    pub async fn send_pairing_request(&self, peer: String, req: FlutterPairingRequest) -> anyhow::Result<FlutterPairingResponse> {
        log::info!("P2pHost::send_pairing_request() called for peer: {}, claim_code: {}",
            peer, req.claim_code);
        let core_req = PairingRequest {
            claim_code: req.claim_code,
            device_name: req.device_name,
            device_type: req.device_type,
            device_os: req.device_os,
        };

        match self.inner.send_request(peer.clone(), MydiaRequest::Pairing(core_req)).await {
            Ok(MydiaResponse::Pairing(res)) => {
                log::info!("send_pairing_request() succeeded: success={}", res.success);
                Ok(FlutterPairingResponse {
                    success: res.success,
                    media_token: res.media_token,
                    access_token: res.access_token,
                    device_token: res.device_token,
                    error: res.error,
                    direct_urls: res.direct_urls,
                })
            }
            Ok(MydiaResponse::Error(e)) => {
                log::error!("send_pairing_request() server error: {}", e);
                Err(anyhow::anyhow!("Server error: {}", e))
            }
            Ok(other) => {
                log::error!("send_pairing_request() unexpected response type: {:?}", other);
                Err(anyhow::anyhow!("Unexpected response type"))
            }
            Err(e) => {
                log::error!("send_pairing_request() failed for peer {}: {}", peer, e);
                Err(anyhow::anyhow!("send_pairing_request failed: {}", e))
            }
        }
    }

    /// Send a GraphQL request to a specific peer.
    pub async fn send_graphql_request(&self, peer: String, req: FlutterGraphQLRequest) -> anyhow::Result<FlutterGraphQLResponse> {
        log::info!("P2pHost::send_graphql_request() called for peer: {}", peer);
        let core_req = GraphQLRequest {
            query: req.query,
            variables: req.variables,
            operation_name: req.operation_name,
            auth_token: req.auth_token,
        };

        match self.inner.send_request(peer.clone(), MydiaRequest::GraphQL(core_req)).await {
            Ok(MydiaResponse::GraphQL(res)) => {
                log::info!("send_graphql_request() succeeded");
                Ok(FlutterGraphQLResponse {
                    data: res.data,
                    errors: res.errors,
                })
            }
            Ok(MydiaResponse::Error(e)) => {
                log::error!("send_graphql_request() server error: {}", e);
                Err(anyhow::anyhow!("Server error: {}", e))
            }
            Ok(other) => {
                log::error!("send_graphql_request() unexpected response type: {:?}", other);
                Err(anyhow::anyhow!("Unexpected response type"))
            }
            Err(e) => {
                log::error!("send_graphql_request() failed for peer {}: {}", peer, e);
                Err(anyhow::anyhow!("send_graphql_request failed: {}", e))
            }
        }
    }

    /// Get network statistics.
    #[frb(sync)]
    pub fn get_network_stats(&self) -> FlutterNetworkStats {
        let stats = self.inner.get_network_stats();
        log::info!("Network stats: connected_peers={}, relay_connected={}, relay_url={:?}, peer_conn_type={:?}",
            stats.connected_peers, stats.relay_connected, stats.relay_url, stats.peer_connection_type);
        FlutterNetworkStats {
            connected_peers: stats.connected_peers,
            relay_connected: stats.relay_connected,
            relay_url: stats.relay_url,
            peer_connection_type: stats.peer_connection_type.into(),
        }
    }

    /// Send an HLS request to a specific peer and collect the complete response.
    ///
    /// This is a non-streaming version that collects all chunks into a single buffer.
    /// For large files, consider using the local proxy service instead.
    pub async fn send_hls_request(&self, peer: String, req: FlutterHlsRequest) -> anyhow::Result<FlutterHlsResponse> {
        log::info!("P2pHost::send_hls_request() called for peer: {}, session: {}, path: {}",
            peer, req.session_id, req.path);

        let core_req = HlsRequest {
            session_id: req.session_id,
            path: req.path,
            range_start: req.range_start,
            range_end: req.range_end,
            auth_token: req.auth_token,
        };

        // Call the Host's send_hls_request method
        match self.inner.send_hls_request(peer.clone(), core_req).await {
            Ok(stream_response) => {
                let flutter_header = FlutterHlsResponseHeader {
                    status: stream_response.header.status,
                    content_type: stream_response.header.content_type,
                    content_length: stream_response.header.content_length,
                    content_range: stream_response.header.content_range,
                    cache_control: stream_response.header.cache_control,
                };

                // Collect all chunks into a single buffer
                let mut data = Vec::with_capacity(stream_response.header.content_length as usize);
                let mut chunk_rx = stream_response.chunk_rx;
                while let Some(chunk) = chunk_rx.recv().await {
                    data.extend_from_slice(&chunk);
                }

                log::info!("HLS request completed for peer: {}, received {} bytes", peer, data.len());
                Ok(FlutterHlsResponse {
                    header: flutter_header,
                    data,
                })
            }
            Err(e) => {
                log::error!("send_hls_request failed for peer {}: {}", peer, e);
                Err(anyhow::anyhow!("HLS request failed: {}", e))
            }
        }
    }

    /// Request a blob download ticket from the server for a transcode job.
    ///
    /// This sends a BlobDownload request to the server which returns a ticket
    /// containing the file hash, size, and path. The ticket can then be used
    /// with download_blob() to download the actual file.
    pub async fn request_blob_download(&self, peer: String, req: FlutterBlobDownloadRequest) -> anyhow::Result<FlutterBlobDownloadResponse> {
        log::info!("P2pHost::request_blob_download() called for peer: {}, job_id: {}",
            peer, req.job_id);

        let core_req = BlobDownloadRequest {
            job_id: req.job_id,
            auth_token: req.auth_token,
        };

        match self.inner.send_request(peer.clone(), MydiaRequest::BlobDownload(core_req)).await {
            Ok(MydiaResponse::BlobDownload(res)) => {
                log::info!("request_blob_download() succeeded: success={}", res.success);
                Ok(FlutterBlobDownloadResponse {
                    success: res.success,
                    ticket: res.ticket,
                    filename: res.filename,
                    file_size: res.file_size,
                    error: res.error,
                })
            }
            Ok(MydiaResponse::Error(e)) => {
                log::error!("request_blob_download() server error: {}", e);
                Err(anyhow::anyhow!("Server error: {}", e))
            }
            Ok(other) => {
                log::error!("request_blob_download() unexpected response type: {:?}", other);
                Err(anyhow::anyhow!("Unexpected response type"))
            }
            Err(e) => {
                log::error!("request_blob_download() failed for peer {}: {}", peer, e);
                Err(anyhow::anyhow!("request_blob_download failed: {}", e))
            }
        }
    }

    /// Download a file using a blob ticket over P2P.
    ///
    /// This uses the HLS streaming infrastructure to download the file in chunks,
    /// providing progress updates to the sink as JSON strings. The file is saved
    /// to the specified output path.
    ///
    /// Progress messages are JSON: {"type": "started|progress|completed|failed", ...}
    /// - started: {"type": "started", "total_size": <bytes>}
    /// - progress: {"type": "progress", "downloaded": <bytes>, "total": <bytes>}
    /// - completed: {"type": "completed", "file_path": "<path>"}
    /// - failed: {"type": "failed", "error": "<message>"}
    ///
    /// The ticket JSON should contain: hash, file_size, filename, file_path
    pub async fn download_blob(
        &self,
        peer: String,
        ticket_json: String,
        output_path: String,
        auth_token: Option<String>,
        sink: StreamSink<String>,
    ) -> anyhow::Result<()> {
        log::info!("P2pHost::download_blob() called for peer: {}, output: {}",
            peer, output_path);

        // Parse the ticket
        let ticket: serde_json::Value = serde_json::from_str(&ticket_json)
            .map_err(|e| anyhow::anyhow!("Failed to parse ticket: {}", e))?;

        let file_size = ticket["file_size"].as_u64()
            .ok_or_else(|| anyhow::anyhow!("Ticket missing file_size"))?;
        let file_path = ticket["file_path"].as_str()
            .ok_or_else(|| anyhow::anyhow!("Ticket missing file_path"))?;

        log::info!("Downloading blob: size={}, server_path={}", file_size, file_path);

        // Send start progress
        let _ = sink.add(format!(r#"{{"type":"started","total_size":{}}}"#, file_size));

        // Create output file
        let mut output_file = match std::fs::File::create(&output_path) {
            Ok(f) => f,
            Err(e) => {
                let error = format!("Failed to create output file: {}", e);
                log::error!("{}", error);
                let _ = sink.add(format!(r#"{{"type":"failed","error":"{}"}}"#, error.replace('"', "\\\"")));
                return Err(anyhow::anyhow!(error));
            }
        };

        // Download using HLS streaming with range requests
        // We use the file_path as the "session_id" since the server will use it to locate the file
        const CHUNK_SIZE: u64 = 1024 * 1024; // 1MB chunks
        let mut downloaded: u64 = 0;

        while downloaded < file_size {
            let range_end = std::cmp::min(downloaded + CHUNK_SIZE - 1, file_size - 1);

            let core_req = HlsRequest {
                session_id: "blob-download".to_string(),
                path: file_path.to_string(),
                range_start: Some(downloaded),
                range_end: Some(range_end),
                auth_token: auth_token.clone(),
            };

            match self.inner.send_hls_request(peer.clone(), core_req).await {
                Ok(stream_response) => {
                    // Check status
                    if stream_response.header.status != 200 && stream_response.header.status != 206 {
                        let error = format!("Server returned status: {}", stream_response.header.status);
                        log::error!("{}", error);
                        let _ = sink.add(format!(r#"{{"type":"failed","error":"{}"}}"#, error.replace('"', "\\\"")));
                        return Err(anyhow::anyhow!(error));
                    }

                    // Write chunks to file
                    let mut chunk_rx = stream_response.chunk_rx;
                    while let Some(chunk) = chunk_rx.recv().await {
                        use std::io::Write;
                        if let Err(e) = output_file.write_all(&chunk) {
                            let error = format!("Failed to write to file: {}", e);
                            log::error!("{}", error);
                            let _ = sink.add(format!(r#"{{"type":"failed","error":"{}"}}"#, error.replace('"', "\\\"")));
                            return Err(anyhow::anyhow!(error));
                        }
                        downloaded += chunk.len() as u64;

                        // Send progress update
                        let _ = sink.add(format!(r#"{{"type":"progress","downloaded":{},"total":{}}}"#, downloaded, file_size));
                    }
                }
                Err(e) => {
                    let error = format!("Download chunk failed: {}", e);
                    log::error!("{}", error);
                    let _ = sink.add(format!(r#"{{"type":"failed","error":"{}"}}"#, error.replace('"', "\\\"")));
                    return Err(anyhow::anyhow!(error));
                }
            }
        }

        // Flush and close file
        use std::io::Write;
        if let Err(e) = output_file.flush() {
            let error = format!("Failed to flush file: {}", e);
            log::error!("{}", error);
            let _ = sink.add(format!(r#"{{"type":"failed","error":"{}"}}"#, error.replace('"', "\\\"")));
            return Err(anyhow::anyhow!(error));
        }

        log::info!("Blob download completed: {} bytes to {}", downloaded, output_path);
        let _ = sink.add(format!(r#"{{"type":"completed","file_path":"{}"}}"#, output_path.replace('"', "\\\"")));

        Ok(())
    }
}
