# OpenClaw on NAS

<p align="center">
  <img src="https://img.shields.io/badge/NAS-Docker_capable-2ea44f" alt="Docker-capable NAS"/>
  <img src="https://img.shields.io/badge/Synology-Tested-orange?logo=synology" alt="Tested on Synology"/>
  <img src="https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white" alt="Docker Compose"/>
  <img src="https://img.shields.io/badge/Nginx-TLS_proxy-009639?logo=nginx&logoColor=white" alt="Nginx TLS proxy"/>
  <img src="https://img.shields.io/badge/HTTPS-Local_CA-blue" alt="Local HTTPS with generated CA"/>
  <img src="https://img.shields.io/badge/Access-LAN_only-critical" alt="LAN-only access"/>
</p>

<p align="center">
  <img src="assets/openclaw-nas.png" alt="OpenClaw NAS Docker deployment" width="720"/>
</p>

Docker deployment for OpenClaw on a NAS with local HTTPS.
Access is **LAN-only** — do not port-forward OpenClaw from your router.

```text
LAN browser -> https://<nas-ip>:8443 -> Nginx TLS proxy -> OpenClaw gateway
```

The NAS deployment uses the pre-built image published by this repository:

```text
ghcr.io/luprintech/openclaw-nas-docker:latest
```

The NAS does **not** build the image locally. GitHub Actions builds the image from
`Dockerfile` and publishes it to GHCR; `docker-compose.yml` only pulls and runs it.

Tested on Synology. Should work on any NAS that runs Docker
(QNAP, Ugreen, TerraMaster, Asustor, etc.).

---

## First install, step by step

This guide assumes you are installing OpenClaw on a NAS inside your LAN.
The examples use `192.168.1.50` as the NAS IP. Replace it with your real NAS IP.

> **Security rule:** keep OpenClaw LAN-only. Do **not** port-forward `18789` or `8443` from your router.
>
> **No clone needed.** The installer is self-contained — it generates all required files (`docker-compose.yml`, `nginx.conf`, `openclaw` wrapper) automatically.

### 0. Give your NAS a stable LAN IP

OpenClaw stores your NAS IP in `.env` and uses it for dashboard URLs, allowed browser origins, and local HTTPS certificates.
If your NAS IP changes later, the dashboard URL, certificate, and `OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS` can stop matching.

Use one of these approaches:

| Option | Recommended? | Tradeoff |
| ------ | ------------ | -------- |
| DHCP reservation in your router | **Best option** | The router always gives the same IP to the NAS. Low risk, easy rollback. |
| Static IP in the NAS control panel | Good option | Works without router changes, but a wrong gateway/DNS/subnet can disconnect the NAS. |
| Static IP by SSH | Not recommended for Synology | Possible only with low-level Linux/network commands and may not survive DSM network management or reboot. Easy way to lock yourself out. |

#### Recommended: reserve the IP in your router

In your router/admin panel:

1. Find the NAS in the DHCP / LAN clients list.
2. Copy its MAC address.
3. Create a DHCP reservation, also called static lease or address reservation.
4. Assign an IP outside or safely within your DHCP plan, for example:

```text
192.168.1.50
```

5. Reboot the NAS or renew its network lease.
6. Confirm the NAS still answers on that IP.

This is the cleanest architecture: the router owns addressing, the NAS just receives the same address every time.

#### Synology DSM: set a manual IP from the UI

If you prefer setting the IP directly in Synology DSM:

1. Open DSM in your browser.
2. Go to **Control Panel**.
3. Open **Network**.
4. Go to **Network Interface**.
5. Select your active LAN interface, usually **LAN 1**.
6. Click **Edit**.
7. In IPv4 settings, choose manual configuration instead of DHCP.
8. Set:
   - **IP address**: for example `192.168.1.50`
   - **Subnet mask**: commonly `255.255.255.0`
   - **Gateway**: your router IP, for example `192.168.1.1`
   - **DNS server**: your router IP or a DNS server you trust
9. Apply the changes.
10. Reconnect to DSM using the new IP.

Be careful here. If you put the wrong gateway, subnet, or IP range, you can lose access to DSM until you fix networking locally.

#### Can I assign the static IP by SSH?

For this project, do **not** document SSH as the normal way to set a permanent Synology IP.
DSM owns network configuration and can overwrite low-level changes. Commands like `ip addr` are useful for diagnostics or temporary changes, not as a reliable persistent setup path.

Use SSH only to check the current address:

```bash
hostname -I
ip addr
```

Now continue with that stable IP in the rest of the guide.

### 1. Know your NAS LAN IP

Find the LAN IP of your NAS from your router, NAS control panel, or SSH:

```bash
hostname -I
```

Example used below:

```text
192.168.1.50
```

### 2. SSH to your NAS and run the installer

Choose a directory on your NAS:

| NAS      | Suggested path                            |
| -------- | ----------------------------------------- |
| Synology | `/volume1/docker/openclaw`                |
| QNAP     | `/share/Container/openclaw`               |
| Others   | `/opt/openclaw` or any writable directory |

Connect by SSH, create the directory, and run the installer:

```bash
ssh admin@192.168.1.50
mkdir -p /volume1/docker/openclaw
cd /volume1/docker/openclaw
curl -fsSL https://raw.githubusercontent.com/luprintech/openclaw-nas-docker/main/install.sh -o install.sh
chmod +x install.sh
./install.sh 192.168.1.50
```

Or if your NAS supports piping:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/luprintech/openclaw-nas-docker/main/install.sh) 192.168.1.50
```

The installer handles everything automatically:

- Generates `docker-compose.yml`, `nginx/nginx.conf`, and the `openclaw` CLI wrapper.
- Creates `.env` with a secure, randomly generated `OPENCLAW_GATEWAY_TOKEN`.
- Configures HTTPS-only LAN access.
- Generates local TLS certificates under `certs/`.
- Validates the environment.
- Pulls and starts the Docker Compose stack using the pre-built GHCR image.
- Applies the allowed Control UI origins.

After install, add your AI provider key(s) to `.env`:

```bash
nano .env
```

Fill in at least one provider:

```env
ANTHROPIC_API_KEY=your-key-here
# or OPENAI_API_KEY, GEMINI_API_KEY, OPENROUTER_API_KEY, etc.
```

One key is enough to start. If you leave them empty, onboarding can still configure providers later.

#### About `http://<nas-ip>:18789`

Do **not** use `http://192.168.1.50:18789` as the normal browser URL.
That port is the raw OpenClaw gateway port — it is bound to `127.0.0.1` (private), and Nginx is the only LAN-facing entry point.

Correct browser URL:

```text
https://192.168.1.50:8443
```

### 3. Install the local root certificate on each client device

Copy the generated root certificate from the NAS to every device that will open OpenClaw:

```text
certs/rootCA.pem
```

Windows users can use:

```text
certs/rootCA.cer
```

Then trust that certificate on the device. See [Installing rootCA.pem](#installing-rootcapem) below.

If you skip this step, the browser will warn that the HTTPS certificate is not trusted. That is expected: you created a private local CA for your LAN, not a public internet certificate.

### 4. Open the OpenClaw dashboard

Use the HTTPS URL:

```text
https://192.168.1.50:8443
```

Do not open the dashboard through plain HTTP.

When the dashboard asks for the gateway token, paste the exact value from `.env`:

```env
OPENCLAW_GATEWAY_TOKEN=your-token-here
```

Do not paste the key name. Paste only the token value.

### 5. Run onboarding

From the NAS project directory:

```bash
./openclaw onboard
```

This runs OpenClaw onboarding inside the Docker container without installing a host daemon.

### 6. Pair your browser

Pairing is the step that authorizes your browser as a known device.

Print the dashboard and pairing information:

```bash
./openclaw dashboard
```

Then:

1. Open the printed dashboard / pairing URL in your browser.
2. Enter `OPENCLAW_GATEWAY_TOKEN` if the UI asks for it.
3. Start the pairing flow from the browser.
4. Go back to SSH and list pending devices:

```bash
./openclaw devices
```

5. Copy the pending `request_id`.
6. Approve it:

```bash
./openclaw approve <request_id>
```

Example:

```bash
./openclaw approve abc123
```

7. Refresh the browser dashboard.

Your browser should now be paired and allowed to use the OpenClaw Control UI.

### 7. Verify the stack is running

```bash
./openclaw status
./openclaw doctor
```

If something fails, check logs:

```bash
./openclaw logs
./openclaw logs openclaw-gateway
./openclaw logs nginx
```

---

## Subsequent installs and updates

After the first install, the NAS IP and HTTPS mode are saved in `.env`.
You only need to run:

```bash
./install.sh
```

No arguments needed.

---

## Installing rootCA.pem

### Windows

1. Copy `certs/rootCA.cer` to the PC.
2. Double-click it → Install Certificate.
3. Choose **Local Machine**.
4. Place it in **Trusted Root Certification Authorities**.

### macOS

1. Open `rootCA.pem` → Keychain Access adds it to System keychain.
2. Open the certificate → set SSL trust to **Always Trust**.

### iPhone / iPad

1. Open `rootCA.pem` on the device → Install Profile.
2. Go to **Settings → General → About → Certificate Trust Settings**.
3. Enable full trust for the CA.

### Android

```text
Settings → Security → Encryption & credentials → Install a CA certificate
```

Exact names vary by manufacturer.

---

## Operational commands

```bash
./openclaw onboard               # First-time setup
./openclaw dashboard             # Print dashboard / pairing URL
./openclaw devices               # List devices
./openclaw approve <request_id>  # Approve a device
./openclaw doctor                # Run diagnostics
./openclaw claude                # Open Claude Code interactive TUI
./openclaw message send --target <channel> --message "hi"  # Send a message
./openclaw agent --message "hi"  # Talk to the assistant
./openclaw update                # Pull repo changes, pull image, restart
./openclaw status                # Container status
./openclaw logs                  # Follow all logs
./openclaw logs openclaw-gateway # Gateway logs only
./openclaw logs nginx            # Nginx logs only
./openclaw restart               # Restart the stack
./openclaw stop                  # Stop the stack
```

Raw CLI pass-through:

```bash
./openclaw config get gateway.bind
```

---

## Updating OpenClaw

Recommended update path on the NAS:

```bash
./openclaw update
```

`./openclaw update` pulls repository changes, pulls the configured image, and
restarts the stack. By default, `docker-compose.yml` uses the published `latest`
image. `.last-openclaw-version` is only the CI build tracker, not a NAS runtime
setting.

Manual version pin update, usually only needed by maintainers:

```bash
./openclaw update-version
```

---

## Troubleshooting

### EACCES: permission denied

OpenClaw runs as UID/GID `1000` inside the container. Most NAS systems create
bind-mount directories owned by the SSH user, which causes EACCES errors like:

```text
EACCES: permission denied, open '/home/node/.openclaw/openclaw.json...tmp'
```

Fix:

```bash
cd /path/to/openclaw
sudo chown -R 1000:1000 config workspace
sudo chmod -R u+rwX config workspace
./openclaw restart
```

If certificate generation fails with permission denied under `certs/`:

```bash
sudo chown -R "$(id -u):$(id -g)" certs
chmod -R u+rwX certs
```

If your NAS user cannot use `sudo`, fix ownership from your NAS admin panel
(DSM File Station on Synology, File Manager on QNAP, etc.).

### Container name conflicts

If you see:

```text
Conflict. The container name "/openclaw-gateway" is already in use
```

you have leftovers from an older install with fixed container names.

```bash
docker ps -a --filter name=openclaw
docker stop openclaw-gateway openclaw-cli openclaw-nginx 2>/dev/null || true
docker rm   openclaw-gateway openclaw-cli openclaw-nginx 2>/dev/null || true
./install.sh
```

### Missing bind mount directories

If Docker reports a missing bind mount, create the directories and rerun:

```bash
mkdir -p config workspace certs
./install.sh
```

Current versions of `install.sh` create these directories automatically.

---

## Security rules

- Do not port-forward `18789` or `8443` from the router.
- Keep `certs/` private — it is ignored by Git.
- Never commit `.env` — it contains `OPENCLAW_GATEWAY_TOKEN`.
- Install only OpenClaw skills/plugins you trust.
