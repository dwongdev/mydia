use clap::{Parser, ValueEnum};
use log::{info, error, debug};
use mydia_p2p_core::{Host, HostConfig, MydiaRequest, MydiaResponse, PairingRequest, PairingResponse, Event};
use std::time::Duration;
use tokio::time::sleep;
use std::sync::Arc;

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    #[arg(short, long, value_enum)]
    role: Role,

    #[arg(short, long)]
    bootstrap: Option<String>,

    #[arg(short, long)]
    claim_code: Option<String>,

    #[arg(short, long, default_value = "4001")]
    port: u16,
}

#[derive(Copy, Clone, PartialEq, Eq, PartialOrd, Ord, ValueEnum, Debug)]
enum Role {
    Relay,
    Server,
    Player,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    env_logger::init();
    let args = Args::parse();

    info!("Starting Mydia P2P E2E Agent");
    info!("Role: {:?}", args.role);

    // Configure Host
    let mut config = HostConfig::default();
    config.enable_ipfs_bootstrap = false; // Disable IPFS for E2E tests
    config.enable_mdns = false; // Disable mDNS for isolated test environment
    if let Some(bootstrap) = args.bootstrap {
        info!("Adding bootstrap peer: {}", bootstrap);
        config.bootstrap_peers.push(bootstrap);
    }

    // Initialize Host
    let (host, peer_id) = Host::new(config);
    // host is Host, peer_id is String
    // Wrap host in Arc
    let host = Arc::new(host);
    
    info!("Local Peer ID: {}", peer_id);

    // Start listening
    let listen_addr = format!("/ip4/0.0.0.0/tcp/{}", args.port);
    let host_clone = host.clone();
    let addr_clone = listen_addr.clone();
    tokio::task::spawn_blocking(move || {
        host_clone.listen(addr_clone)
    }).await?
    .map_err(|e| anyhow::anyhow!("Failed to listen: {}", e))?;
    info!("Listening on {}", listen_addr);

    // Role-specific logic
    match args.role {
        Role::Relay => run_relay().await?,
        Role::Server => run_server(host, args.claim_code).await?,
        Role::Player => run_player(host, args.claim_code).await?,
    }

    Ok(())
}

async fn run_relay() -> anyhow::Result<()> {
    info!("Running as Relay/Bootstrap node...");
    // Just keep running
    loop {
        sleep(Duration::from_secs(10)).await;
        info!("Relay is alive...");
    }
}

async fn wait_for_bootstrap(host: Arc<Host>) -> anyhow::Result<()> {
    info!("Waiting for Kademlia bootstrap...");
    let rx_arc = host.event_rx.clone();
    let start = std::time::Instant::now();
    
    loop {
        if start.elapsed() > Duration::from_secs(30) {
            return Err(anyhow::anyhow!("Bootstrap timeout"));
        }

        let event = {
            let mut rx = rx_arc.lock().await;
            match tokio::time::timeout(Duration::from_secs(1), rx.recv()).await {
                Ok(Some(evt)) => evt,
                Ok(None) => return Err(anyhow::anyhow!("Event channel closed")),
                Err(_) => continue,
            }
        };

        if let Event::BootstrapCompleted = event {
            info!("Bootstrap completed!");
            return Ok(());
        }
    }
}

async fn run_server(host: Arc<Host>, claim_code: Option<String>) -> anyhow::Result<()> {
    let claim_code = claim_code.ok_or_else(|| anyhow::anyhow!("Claim code required for Server"))?;
    info!("Running as Server. Claim Code: {}", claim_code);

    // Wait for bootstrap
    wait_for_bootstrap(host.clone()).await.ok(); // Ignore error (might have already completed or timeout)

    // Provide claim code - use longer timeout for DHT propagation
    info!("Providing claim code to DHT...");
    let host_clone = host.clone();
    let claim_code_clone = claim_code.clone();

    // Allow up to 30 seconds for DHT provide to complete
    let res = tokio::time::timeout(Duration::from_secs(30), tokio::task::spawn_blocking(move || {
        host_clone.provide_claim_code(claim_code_clone)
    })).await;

    match res {
        Ok(Ok(Ok(_))) => info!("Claim code provided successfully."),
        Ok(Ok(Err(e))) => {
            // QuorumFailed is common in small networks but the record is still stored locally
            // Continue anyway - the player can still find us via DHT traversal
            error!("DHT replication warning (continuing anyway): {}", e);
        }
        Ok(Err(e)) => {
            error!("Join error (continuing anyway): {}", e);
        }
        Err(_) => {
            // Timeout is OK - the record was likely stored
            error!("Timeout providing claim code (continuing anyway)");
        }
    }
    info!("Claim code registration complete (may have warnings above)");

    // Wait for Pairing Request
    info!("Waiting for events...");
    let rx_arc = host.event_rx.clone();
    
    // We need to loop and lock the mutex to get events
    loop {
        // Scope the lock
        let event = {
            let mut rx = rx_arc.lock().await;
            // timeout to prevent deadlocks or hang
            match tokio::time::timeout(Duration::from_secs(60), rx.recv()).await {
                Ok(Some(evt)) => evt,
                Ok(None) => return Err(anyhow::anyhow!("Event channel closed")),
                Err(_) => {
                    info!("Waiting for pairing request...");
                    continue;
                }
            }
        };

        debug!("Received event: {:?}", event);

        if let Event::RequestReceived { peer, request, request_id } = event {
            info!("Received request from {}: {:?}", peer, request);
            if let MydiaRequest::Pairing(payload) = request {
                info!("Received Pairing Request: {:?}", payload);
                
                // Send success response
                let response = MydiaResponse::Pairing(PairingResponse {
                    success: true,
                    media_token: Some("test-media-token".to_string()),
                    access_token: Some("test-access-token".to_string()),
                    device_token: Some("test-device-token".to_string()),
                    error: None,
                });

                info!("Sending Pairing Response...");
                host.send_response_async(request_id, response).await
                    .map_err(|e| anyhow::anyhow!("Failed to send response: {}", e))?;

                // Wait for response to be transmitted before exiting
                // The send_response command is async - we need to give time for the swarm to process it
                info!("Response queued, waiting for transmission...");
                sleep(Duration::from_secs(2)).await;

                info!("Pairing successful. Server test passed.");
                return Ok(());
            }
        }
    }
}

async fn run_player(host: Arc<Host>, claim_code: Option<String>) -> anyhow::Result<()> {
    let claim_code = claim_code.ok_or_else(|| anyhow::anyhow!("Claim code required for Player"))?;
    info!("Running as Player. Target Claim Code: {}", claim_code);

    // Wait for bootstrap
    wait_for_bootstrap(host.clone()).await.ok();

    // Wait a bit for the server to bootstrap and provide the claim code
    // In a real scenario this wouldn't be needed, but in E2E tests all nodes start ~simultaneously
    info!("Waiting 10s for server to be ready...");
    sleep(Duration::from_secs(10)).await;

    // Lookup Claim Code with more retries and longer intervals
    info!("Looking up claim code '{}' on DHT...", claim_code);

    // Retry loop for lookup - up to 30 attempts over ~60 seconds
    let mut lookup_result = None;
    for i in 0..30 {
        match host.lookup_claim_code(claim_code.clone()).await {
            Ok(res) => {
                info!("Found provider: PeerID={}, Addrs={:?}", res.peer_id, res.addresses);
                lookup_result = Some(res);
                break;
            }
            Err(e) => {
                debug!("Lookup attempt {} failed: {}. Retrying...", i+1, e);
                if (i + 1) % 5 == 0 {
                    info!("Lookup attempt {} failed: {}. Still trying...", i+1, e);
                }
                sleep(Duration::from_secs(2)).await;
            }
        }
    }

    let result = lookup_result.ok_or_else(|| anyhow::anyhow!("Failed to find provider for claim code after 30 attempts"))?;

    // Connect to the provider - skip localhost addresses (won't work in Docker)
    let dialable_addr = result.addresses.iter()
        .find(|addr| !addr.contains("127.0.0.1") && !addr.contains("::1"))
        .or(result.addresses.first());

    if let Some(addr) = dialable_addr {
        info!("Dialing provider address: {}", addr);
        let host_clone = host.clone();
        let addr_clone = addr.clone();
        tokio::task::spawn_blocking(move || {
            host_clone.dial(addr_clone)
        }).await?
        .map_err(|e| anyhow::anyhow!("Failed to dial: {}", e))?;
    } else {
        info!("No dialable addresses found, relying on DHT routing");
    }

    // Wait for connection to be established
    sleep(Duration::from_secs(5)).await;

    // Send Pairing Request
    let request = MydiaRequest::Pairing(PairingRequest {
        claim_code: claim_code,
        device_name: "Test Player".to_string(),
        device_type: "Test".to_string(),
        device_os: Some("Linux".to_string()),
    });

    info!("Sending Pairing Request to {}", result.peer_id);
    let response = host.send_request(result.peer_id, request).await
        .map_err(|e| anyhow::anyhow!("Request failed: {}", e))?;

    info!("Received Response: {:?}", response);

    if let MydiaResponse::Pairing(payload) = response {
        if payload.success {
            info!("Pairing successful! Player test passed.");
            return Ok(());
        } else {
            return Err(anyhow::anyhow!("Pairing failed: {:?}", payload.error));
        }
    } else {
        return Err(anyhow::anyhow!("Unexpected response type"));
    }
}
