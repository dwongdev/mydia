use mydia_p2p_core::{Host, Event};
use flutter_rust_bridge::frb;
use flutter_rust_bridge::StreamSink;

#[frb(init)]
pub fn init_app() {
    // Default utilities - e.g. logging
    flutter_rust_bridge::setup_default_user_utils();
}

pub struct P2pHost {
    inner: Host,
}

impl P2pHost {
    #[frb(sync)]
    pub fn new() -> (Self, String) {
        let (host, peer_id) = Host::new();
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
}
