mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
use mydia_p2p_core::{Host, Event, MydiaRequest, MydiaResponse, PairingRequest, PairingResponse, HostConfig};
use flutter_rust_bridge::frb;
use crate::frb_generated::StreamSink;

#[frb(init)]
pub fn init_app() {
    // Default utilities - e.g. logging
    flutter_rust_bridge::setup_default_user_utils();
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

impl P2pHost {
    #[frb(sync)]
    pub fn init() -> (Self, String) {
        let config = HostConfig { enable_relay_server: false };
        let (host, peer_id) = Host::new(config);
        (P2pHost { inner: host }, peer_id)
    }

    pub fn listen(&self, addr: String) -> anyhow::Result<()> {
        self.inner.listen(addr).map_err(|e| anyhow::anyhow!(e))
    }

    pub fn dial(&self, addr: String) -> anyhow::Result<()> {
        self.inner.dial(addr).map_err(|e| anyhow::anyhow!(e))
    }

    pub fn event_stream(&self, sink: StreamSink<String>) -> anyhow::Result<()> {
        let rx = self.inner.event_rx.clone();
        tokio::spawn(async move {
            let mut rx = rx.lock().await;
            while let Some(event) = rx.recv().await {
                let msg = match event {
                    Event::PeerDiscovered(id) => format!("peer_discovered:{}", id),
                    Event::PeerExpired(id) => format!("peer_expired:{}", id),
                    _ => "unknown".to_string(),
                };
                if sink.add(msg).is_err() {
                    break;
                }
            }
        });
        Ok(())
    }

    pub async fn send_pairing_request(&self, peer: String, req: FlutterPairingRequest) -> anyhow::Result<FlutterPairingResponse> {
        let core_req = PairingRequest {
            claim_code: req.claim_code,
            device_name: req.device_name,
            device_type: req.device_type,
            device_os: req.device_os,
        };

        match self.inner.send_request(peer, MydiaRequest::Pairing(core_req)).await {
            Ok(MydiaResponse::Pairing(res)) => Ok(FlutterPairingResponse {
                success: res.success,
                media_token: res.media_token,
                access_token: res.access_token,
                device_token: res.device_token,
                error: res.error,
            }),
            Ok(MydiaResponse::Error(e)) => Err(anyhow::anyhow!("Server error: {}", e)),
            Ok(_) => Err(anyhow::anyhow!("Unexpected response type")),
            Err(e) => Err(anyhow::anyhow!(e)),
        }
    }
}
