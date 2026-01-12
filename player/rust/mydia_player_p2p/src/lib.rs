use mydia_p2p_core::Host;
use flutter_rust_bridge::frb;

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
}
