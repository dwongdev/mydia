mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
use mydia_p2p_core::{Host, Event, MydiaRequest, MydiaResponse, PairingRequest, GraphQLRequest, HostConfig};
use flutter_rust_bridge::frb;
use crate::frb_generated::StreamSink;

#[frb(init)]
pub fn init_app() {
    // Default utilities - e.g. logging
    flutter_rust_bridge::setup_default_user_utils();
    
    // Initialize Android logging
    #[cfg(target_os = "android")]
    android_logger::init_once(
        android_logger::Config::default()
            .with_max_level(log::LevelFilter::Debug)
            .with_filter(android_logger::FilterBuilder::new()
                .parse("debug,yamux=warn,libp2p_yamux=warn,multistream_select=warn,netlink_proto=warn")
                .build())
            .with_tag("mydia_p2p"),
    );
    
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
}

/// Network statistics for display in the UI
pub struct FlutterNetworkStats {
    pub connected_peers: usize,
    pub relay_connected: bool,
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
        log::debug!("P2pHost::get_network_stats() called");
        let stats = self.inner.get_network_stats();
        FlutterNetworkStats {
            connected_peers: stats.connected_peers,
            relay_connected: stats.relay_connected,
        }
    }
}
