mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
use mydia_p2p_core::{Host, Event, MydiaRequest, MydiaResponse, PairingRequest, HostConfig};
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

/// Result of a rendezvous discovery
pub struct FlutterDiscoverResult {
    pub peers: Vec<FlutterDiscoveredPeer>,
}

pub struct FlutterDiscoveredPeer {
    pub peer_id: String,
    pub addresses: Vec<String>,
}

/// Network statistics for display in the UI
pub struct FlutterNetworkStats {
    pub routing_table_size: usize,
    pub active_registrations: usize,
    pub rendezvous_connected: bool,
}

impl P2pHost {
    #[frb(sync)]
    pub fn init() -> (Self, String) {
        log::info!("P2pHost::init() called");
        let config = HostConfig {
            enable_relay_server: false,
            // Disable Kademlia for mobile to save battery and data
            enable_kademlia: false,
            enable_ipfs_bootstrap: false,
            // Enable Rendezvous Client for discovery
            enable_rendezvous_client: true,
            enable_rendezvous_server: false,
            bootstrap_peers: vec![],
            keypair_path: None,
            ..Default::default()
        };
        let (host, peer_id) = Host::new(config);
        log::info!("P2pHost created with peer_id: {}", peer_id);
        (P2pHost { inner: host }, peer_id)
    }

    pub fn listen(&self, addr: String) -> anyhow::Result<()> {
        log::info!("P2pHost::listen() called with addr: {}", addr);
        match self.inner.listen(addr.clone()) {
            Ok(_) => {
                log::info!("listen() succeeded for addr: {}", addr);
                Ok(())
            }
            Err(e) => {
                log::error!("listen() failed for addr {}: {}", addr, e);
                Err(anyhow::anyhow!("listen failed: {}", e))
            }
        }
    }

    pub fn dial(&self, addr: String) -> anyhow::Result<()> {
        log::info!("P2pHost::dial() called with addr: {}", addr);
        match self.inner.dial(addr.clone()) {
            Ok(_) => {
                log::info!("dial() succeeded for addr: {}", addr);
                Ok(())
            }
            Err(e) => {
                log::error!("dial() failed for addr {}: {}", addr, e);
                Err(anyhow::anyhow!("dial failed: {}", e))
            }
        }
    }

    pub fn event_stream(&self, sink: StreamSink<String>) -> anyhow::Result<()> {
        log::info!("P2pHost::event_stream() called");
        let rx = self.inner.event_rx.clone();
        // Spawn a dedicated thread with its own Tokio runtime for event streaming
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
                        Event::PeerDiscovered(id) => format!("peer_discovered:{}", id),
                        Event::PeerExpired(id) => format!("peer_expired:{}", id),
                        Event::BootstrapCompleted => "bootstrap_completed".to_string(),
                        Event::NewListenAddr(addr) => format!("new_listen_addr:{}", addr),
                        Event::RelayReservationReady { relay_peer_id, relayed_addr } => {
                            format!("relay_ready:{}:{}", relay_peer_id, relayed_addr)
                        }
                        Event::RelayReservationFailed { relay_peer_id, error } => {
                            format!("relay_failed:{}:{}", relay_peer_id, error)
                        }
                        _ => "unknown".to_string(),
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

    /// Add a bootstrap peer and initiate DHT bootstrap.
    /// The address should include the peer ID, e.g., "/ip4/1.2.3.4/tcp/4001/p2p/12D3..."
    pub fn bootstrap(&self, addr: String) -> anyhow::Result<()> {
        log::info!("P2pHost::bootstrap() called with addr: {}", addr);
        match self.inner.bootstrap(addr.clone()) {
            Ok(_) => {
                log::info!("bootstrap() succeeded for addr: {}", addr);
                Ok(())
            }
            Err(e) => {
                log::error!("bootstrap() failed for addr {}: {}", addr, e);
                Err(anyhow::anyhow!("bootstrap failed: {}", e))
            }
        }
    }

    /// Connect to a relay server and request a reservation.
    /// This allows other peers to connect to us through the relay.
    /// The address should include the relay's peer ID, e.g., "/ip4/1.2.3.4/tcp/4001/p2p/12D3..."
    pub fn connect_relay(&self, relay_addr: String) -> anyhow::Result<()> {
        log::info!("P2pHost::connect_relay() called with addr: {}", relay_addr);
        match self.inner.connect_relay(relay_addr.clone()) {
            Ok(_) => {
                log::info!("connect_relay() succeeded for addr: {}", relay_addr);
                Ok(())
            }
            Err(e) => {
                log::error!("connect_relay() failed for addr {}: {}", relay_addr, e);
                Err(anyhow::anyhow!("connect_relay failed: {}", e))
            }
        }
    }

    /// Discover peers in a rendezvous namespace.
    /// Returns the list of discovered peers and their addresses.
    pub async fn discover_namespace(&self, namespace: String) -> anyhow::Result<FlutterDiscoverResult> {
        log::info!("P2pHost::discover_namespace() called with namespace: {}", namespace);
        match self.inner.discover_namespace(namespace.clone()).await {
            Ok(peers) => {
                log::info!("discover_namespace() succeeded: found {} peers", peers.len());
                let flutter_peers = peers.into_iter().map(|p| FlutterDiscoveredPeer {
                    peer_id: p.peer_id,
                    addresses: p.addresses,
                }).collect();
                
                Ok(FlutterDiscoverResult {
                    peers: flutter_peers,
                })
            }
            Err(e) => {
                log::error!("discover_namespace() failed for {}: {}", namespace, e);
                Err(anyhow::anyhow!("discover_namespace failed: {}", e))
            }
        }
    }

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

    /// Get network statistics (routing table size, active registrations, etc.).
    #[frb(sync)]
    pub fn get_network_stats(&self) -> FlutterNetworkStats {
        log::debug!("P2pHost::get_network_stats() called");
        let stats = self.inner.get_network_stats();
        FlutterNetworkStats {
            routing_table_size: stats.routing_table_size,
            active_registrations: stats.active_registrations,
            rendezvous_connected: stats.rendezvous_connected,
        }
    }
}
