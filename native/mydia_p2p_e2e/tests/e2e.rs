use bollard::container::{Config, CreateContainerOptions, LogsOptions, StartContainerOptions, WaitContainerOptions};
use bollard::image::BuildImageOptions;
use bollard::network::{CreateNetworkOptions, ConnectNetworkOptions};
use bollard::Docker;
use futures_util::stream::StreamExt;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::io::AsyncWriteExt;

const IMAGE_NAME: &str = "mydia-p2e-e2e:latest";
const NETWORK_NAME: &str = "mydia-e2e-net";

#[tokio::test]
async fn test_pairing_e2e() -> Result<(), Box<dyn std::error::Error>> {
    println!("CWD: {:?}", std::env::current_dir());
    let docker = Docker::connect_with_local_defaults()?;

    // 1. Build Image
    println!("Building Docker image...");
    build_image(&docker).await?;

    // 2. Create Network
    println!("Creating network...");
    let _ = docker.create_network(CreateNetworkOptions {
        name: NETWORK_NAME,
        check_duplicate: true,
        ..Default::default()
    }).await; // Ignore error if exists

    let run_id = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    let relay_name = format!("relay-{}", run_id);
    let server_name = format!("server-{}", run_id);
    let player_name = format!("player-{}", run_id);
    let claim_code = "123456";

    // 3. Start Relay
    println!("Starting Relay...");
    start_container(&docker, &relay_name, vec![
        "--role", "relay",
        "--port", "4001"
    ]).await?;
    
    // Get Relay IP (or just use hostname in Docker network)
    // In user-defined networks, we can use container name as hostname.
    let relay_addr = format!("/dns4/{}/tcp/4001/p2p/PLACEHOLDER", relay_name); 
    // Wait, we need the PeerID of the relay to bootstrap properly.
    // The relay prints it to stdout. We need to grab it.
    
    let relay_logs = get_logs(&docker, &relay_name).await?;
    let relay_peer_id = wait_for_peer_id(&docker, &relay_name).await?;
    println!("Relay Peer ID: {}", relay_peer_id);

    let bootstrap_addr = format!("/dns4/{}/tcp/4001/p2p/{}", relay_name, relay_peer_id);

    // 4. Start Server
    println!("Starting Server...");
    start_container(&docker, &server_name, vec![
        "--role", "server",
        "--bootstrap", &bootstrap_addr,
        "--claim-code", claim_code,
        "--port", "4001"
    ]).await?;

    // 5. Start Player
    println!("Starting Player...");
    start_container(&docker, &player_name, vec![
        "--role", "player",
        "--bootstrap", &bootstrap_addr,
        "--claim-code", claim_code,
        "--port", "4001"
    ]).await?;

    // 6. Wait for Player result
    println!("Waiting for Player to finish...");
    let wait_res = match docker.wait_container(&player_name, Some(WaitContainerOptions {
        condition: "not-running",
    })).next().await {
        Some(Ok(res)) => res,
        Some(Err(e)) => {
            println!("Wait error: {}", e);
            print_logs(&docker, &player_name).await?;
            print_logs(&docker, &server_name).await?;
            print_logs(&docker, &relay_name).await?;
            return Err(e.into());
        }
        None => return Err("No wait result".into()),
    };

    // 7. Check logs and cleanup
    println!("Player Logs:");
    print_logs(&docker, &player_name).await?;
    
    println!("Server Logs:");
    print_logs(&docker, &server_name).await?;

    println!("Relay Logs:");
    print_logs(&docker, &relay_name).await?;

    // Cleanup
    let _ = docker.remove_container(&player_name, Some(bollard::container::RemoveContainerOptions { force: true, ..Default::default() })).await;
    let _ = docker.remove_container(&server_name, Some(bollard::container::RemoveContainerOptions { force: true, ..Default::default() })).await;
    let _ = docker.remove_container(&relay_name, Some(bollard::container::RemoveContainerOptions { force: true, ..Default::default() })).await;
    let _ = docker.remove_network(NETWORK_NAME).await;

    assert_eq!(wait_res.status_code, 0, "Player container failed");

    Ok(())
}

async fn build_image(docker: &Docker) -> Result<(), Box<dyn std::error::Error>> {
    // We assume the Dockerfile is at native/mydia_p2p_e2e/Dockerfile
    // and context is native/
    
    // Ideally we tar the context.
    // Since we are running on the host, we can use the `command` CLI if simpler, but let's try bollard build.
    // Bollard requires a tarball.
    
    // For simplicity in this environment, let's shell out to `docker build`.
    // It's "pure rust" invoking a command.
    
    let status = std::process::Command::new("docker")
        .arg("build")
        .arg("-t")
        .arg(IMAGE_NAME)
        .arg("-f")
        .arg("Dockerfile")
        .arg("..")
        .status()?;

    if !status.success() {
        return Err("Failed to build docker image".into());
    }
    Ok(())
}

async fn start_container(docker: &Docker, name: &str, args: Vec<&str>) -> Result<(), Box<dyn std::error::Error>> {
    let config = Config {
        image: Some(IMAGE_NAME),
        cmd: Some(args),
        host_config: Some(bollard::service::HostConfig {
            network_mode: Some(NETWORK_NAME.to_string()),
            ..Default::default()
        }),
        ..Default::default()
    };

    docker.create_container(Some(CreateContainerOptions { name, platform: None }), config).await?;
    docker.start_container(name, None::<StartContainerOptions<String>>).await?;
    Ok(())
}

async fn wait_for_peer_id(docker: &Docker, container_name: &str) -> Result<String, Box<dyn std::error::Error>> {
    // Poll logs until we see "Local Peer ID: "
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(1));
    for _ in 0..30 {
        interval.tick().await;
        let logs = get_logs(docker, container_name).await?;
        for line in logs.lines() {
            if let Some(id) = line.split("Local Peer ID: ").nth(1) {
                return Ok(id.trim().to_string());
            }
        }
    }
    Err("Timed out waiting for Peer ID".into())
}

async fn get_logs(docker: &Docker, container_name: &str) -> Result<String, Box<dyn std::error::Error>> {
    let mut stream = docker.logs(
        container_name,
        Some(LogsOptions::<String> {
            stdout: true,
            stderr: true,
            since: 0,
            ..Default::default()
        })
    );

    let mut output = String::new();
    while let Some(msg) = stream.next().await {
        let msg = msg?;
        output.push_str(&msg.to_string());
    }
    Ok(output)
}

async fn print_logs(docker: &Docker, container_name: &str) -> Result<(), Box<dyn std::error::Error>> {
    let logs = get_logs(docker, container_name).await?;
    println!("--- {} ---", container_name);
    println!("{}", logs);
    println!("----------------");
    Ok(())
}
