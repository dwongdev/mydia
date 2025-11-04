# Mydia

A Phoenix-based media management application.

## Getting Started

### Docker Development (Recommended)

The easiest way to get started is using the `./dev` wrapper script with Docker Compose:

```bash
# Start the development environment
./dev up -d

# Run database migrations
./dev mix ecto.migrate

# Open an interactive shell
./dev shell

# Run tests
./dev test

# View logs
./dev logs -f

# Stop the environment
./dev down
```

Run `./dev` without arguments to see all available commands.

#### Customizing Your Development Environment

You can customize your local Docker Compose setup without modifying the tracked `compose.yml` file by using a `compose.override.yml` file. This is useful for:

- Adding development services (torrent clients, indexers, databases)
- Changing ports to avoid conflicts
- Adding custom volume mounts
- Overriding environment variables
- Adding debugging tools

**Quick Start:**

```bash
# Copy the example override file
cp compose.override.yml.example compose.override.yml

# Edit the file and uncomment the services you want
# (The file includes Transmission, Prowlarr, and other useful services)

# Start your customized environment
./dev up -d
```

The `compose.override.yml` file is gitignored, so your personal configuration stays local and won't conflict with other developers.

**Example: Add a Torrent Client**

The example file includes pre-configured Transmission and qBittorrent services. Simply uncomment the service you want in your `compose.override.yml`:

```yaml
services:
  transmission:
    image: lscr.io/linuxserver/transmission:latest
    ports:
      - "9091:9091"
    # ... (full config in example file)
```

**Example: Override the Main App**

You can also override settings for the main `app` service:

```yaml
services:
  app:
    environment:
      PORT: 5000  # Change the port
    ports:
      - "5000:5000"
    volumes:
      - /path/to/your/media:/media:ro  # Add a media library mount
```

**Automatic Service Integration**

When you enable Transmission and Prowlarr services in your `compose.override.yml`, you can automatically configure Mydia to use them by setting environment variables for the app service. The override example file includes pre-configured environment variables that:

- Connect Mydia to your local Transmission instance for automatic torrent downloads
- Integrate Prowlarr for searching torrents across multiple indexers

Simply uncomment the service configurations and the corresponding app environment variables to enable seamless integration. See `compose.override.yml.example` for complete examples and detailed documentation.

### Local Development

To run Phoenix locally without Docker:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

### Authentication

For local development and testing, a default admin user is automatically created with the following credentials:

* **Username:** `admin`
* **Password:** `admin`

**Note:** This default user is only created in development and test environments for convenience. It will not be created in production.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
