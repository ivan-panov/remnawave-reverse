<p align="center"><a href="https://github.com/ivan-panov/remnawave-reverse">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./media/logo.png" />
    <source media="(prefers-color-scheme: light)" srcset="./media/logo-black.png" />
    <img alt="Remnawave Reverse" src="./media/logo.png" />
  </picture>
</a></p>

<p align="center">
  <img src="./media/ru.png" alt="Русский" /> <a href="./README-RU.md">Русский</a> |
  <img src="./media/us.png" alt="English" /> <strong>English</strong>
</p>

---

> [!CAUTION]
> **This repository is an educational example for learning NGINX/Caddy, reverse proxies, Xray and network security basics. It is not an official Remnawave installer. Review the code, make backups and test on a non-production VPS before use.**

## Overview

`remnawave-reverse` automates installation and management of:

- Remnawave Panel and Remnawave Node;
- NGINX or Caddy reverse proxy;
- Subscription Page and SelfSteal for VLESS REALITY;
- SSL certificates, UFW, IPv6 and WARP-related helpers;
- server-side VLESS cascade between Remnawave nodes;
- AmneziaWG 3.0 ingress redirected into Remnawave/Xray;
- manual and optional scheduled container updates.

Xray can listen directly on port 443 and pass web traffic to the reverse proxy through a Unix socket, reducing unnecessary TCP proxying.

## Current modified-build features

### Docker preflight

Before installing Remnawave, the script checks:

- Docker Engine;
- Docker daemon status;
- Docker Compose v2;
- ability to run a test container.

On supported Ubuntu systems, missing or broken Docker components can be installed from Docker's official APT repository before Remnawave setup continues.

### Current container branches

New installations use maintained application branches:

```yaml
remnawave/backend:3
remnawave/subscription-page:latest
remnawave/node:latest
nginx:stable        # NGINX mode
caddy:2             # Caddy mode
valkey/valkey:9-alpine
```

PostgreSQL remains pinned in the generated Compose file. Database major-version upgrades must not be performed as an unattended container update.

### VLESS server-side cascade

Menu item **12** creates and manages this route through the Remnawave API:

```text
Client → public VLESS inbound on entry node
       → VLESS + REALITY outbound
       → bridge VLESS inbound on exit node
       → direct Internet access from exit node
```

The automation clones both Config Profiles, creates a service Internal Squad and user, assigns the profiles, restarts nodes and saves rollback data. It supports:

- all selected inbound traffic through the exit node;
- Russian destinations directly through the entry node and other traffic through the exit node;
- status checks;
- disable/enable;
- full removal with restoration of original profiles.

See [CASCADE-VLESS-RU.md](./CASCADE-VLESS-RU.md).

### AmneziaWG 3.0 ingress

Menu item **13** integrates AmneziaWG traffic with a selected Remnawave outbound:

```text
AmneziaWG client → awg0 on the local VPS
                 → transparent TCP/UDP interception
                 → Remnawave Node / Xray
                 → selected outbound, including VLESS cascade
```

The bundled integration uses the `bivlked/amneziawg-installer` v5.24.0 source pinned by the custom build. Guaranteed AWG 3.0 installation requires a compatible x86_64 host and Linux kernel 6.7 or newer; the module blocks a silent fallback to AWG 2.0.

See [AMNEZIAWG3-REMNAWAVE-RU.md](./AMNEZIAWG3-REMNAWAVE-RU.md).

### Container updates

The management module can:

- show configured images and container health;
- create a pre-update backup;
- migrate an existing Panel 2 Compose configuration to Panel 3 after confirmation;
- run `docker compose pull` and recreate services;
- enable or disable a weekly systemd update timer;
- log update results.

See [CONTAINER-UPDATES-RU.md](./CONTAINER-UPDATES-RU.md).

## Supported deployment modes

### 1. Panel and node on one VPS

Suitable for testing or small installations. The script displays a warning because separate Panel and Node hosts are preferred for production-like deployments.

### 2. Distributed deployment

- **Panel VPS:** Remnawave Panel, database, cache, Subscription Page and reverse proxy.
- **Entry Node VPS:** client-facing Remnawave Node.
- **Exit Node VPS:** optional exit node for the VLESS cascade.

The cascade module must be run on the Panel VPS after both nodes are connected and have active Config Profiles.

## Requirements

- root access;
- a clean Debian or Ubuntu VPS; Ubuntu 24.04 is the primary tested target for the custom automation;
- KVM or another virtualization type that supports the required kernel/network features;
- Docker Engine and Docker Compose v2, or permission for the script to install them on Ubuntu;
- your own domains with DNS records already pointing to the required VPS addresses;
- enough CPU, RAM and disk for the selected Panel/Node layout;
- a snapshot or external backup before major updates and routing changes.

For AmneziaWG 3.0 integration, also check:

```bash
uname -m
uname -r
```

The strict AWG 3.0 path expects `x86_64` and Linux kernel `6.7+`.

## Domain requirements

Prepare up to three domains or subdomains:

1. **Panel domain** — management UI.
2. **Subscription domain** — client subscription page.
3. **SelfSteal domain** — camouflage site for the node.

### Single-server DNS example

| Type  | Name              | Value          | Proxy |
|-------|-------------------|----------------|-------|
| A     | example.com       | server IP      | DNS only |
| CNAME | panel.example.com | example.com    | DNS only |
| CNAME | sub.example.com   | example.com    | DNS only |
| CNAME | node.example.com  | example.com    | DNS only |

### Distributed DNS example

| Type  | Name              | Value          | Proxy |
|-------|-------------------|----------------|-------|
| A     | example.com       | Panel VPS IP   | DNS only |
| CNAME | panel.example.com | example.com    | DNS only |
| CNAME | sub.example.com   | example.com    | DNS only |
| A     | node.example.com  | Node VPS IP    | DNS only |

## Quick start

Run the current installer from this repository:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ivan-panov/remnawave-reverse/refs/heads/main/install_remnawave.sh)
```

For a locally downloaded archive:

```bash
cd /root
unzip -o remnawave-reverse*.zip -d /root/
cd /root/remnawave-reverse*
chmod +x install_remnawave.sh
./install_remnawave.sh
```

> [!IMPORTANT]
> Do not use a wildcard `cd` command when more than one matching directory exists. In that case, enter the exact extracted directory name.

## Installation flow

### Panel-only deployment

1. Run the installer on the Panel VPS.
2. Select **Install Remnawave Components**.
3. Select **Install only the panel**.
4. Choose NGINX or Caddy.
5. Enter the Panel and Subscription domains and certificate details.
6. Save the generated panel access URL and credentials.

### Node-only deployment

1. Create the node in Remnawave Panel.
2. Copy its secret key/certificate from **Nodes → Management**.
3. Run the installer on the Node VPS.
4. Select **Install Remnawave Components**.
5. Select **Install only the node**.
6. Enter the Panel address, node secret and SelfSteal domain when prompted.
7. Verify that the node is connected in the Panel.

### Single-server deployment

1. Run the installer.
2. Select **Install Remnawave Components**.
3. Select **Install panel and node on one server**.
4. Confirm the warning.
5. Choose NGINX or Caddy and complete the prompts.

## Creating the VLESS cascade

Before starting:

- both entry and exit nodes must be online;
- each node must have an active Config Profile;
- the exit-node bridge TCP port must be allowed by its firewall;
- run the menu on the Panel VPS.

Open the menu:

```bash
rr
```

Then select:

```text
12. Server routing — VLESS IN → VLESS OUT cascade
1. Create cascade automatically
```

Choose the entry node, exit node, entry inbound(s), REALITY parameters and routing mode. After creation, use the same submenu to check status or perform rollback.

## Creating AmneziaWG 3.0 ingress

Run this on the VPS that hosts the local `awg0` interface and the selected Remnawave Node:

```bash
rr
```

Then select:

```text
13. AmneziaWG 3.0 — traffic ingress to Remnawave
1. Create integration automatically
```

The module can install AWG, continue after required reboots, create the transparent Xray inbound, add policy-routing rules and select an existing Remnawave outbound.

Do not mix an old AWG 2.0 integration with the AWG 3.0 module. Remove the legacy integration using its original build first.

## Container management and updates

Open:

```bash
rr
```

Select **Manage panel/node**. Available actions include start, stop, update, logs, CLI, panel access, container versions and scheduled updates.

Useful manual checks:

```bash
docker ps
docker compose version
cd /opt/remnawave && docker compose config -q
cd /opt/remnawave && docker compose images
```

For a node-only host:

```bash
cd /opt/remnanode && docker compose config -q
```

## Panel access protection

In NGINX mode, the generated configuration can protect the Panel behind a secret URL parameter/cookie. Save the exact access URL shown after installation. Without the correct parameter or cookie, the Panel may return a blank response or 404.

## Documentation

- [Russian installation notes for this repository](./INSTALL-IVAN-RU.md)
- [Docker and API automation](./DOCKER-API-AUTOMATION-RU.md)
- [Ubuntu 24.04 audit](./UBUNTU-24.04-AUDIT.md)
- [VLESS cascade](./CASCADE-VLESS-RU.md)
- [AmneziaWG 3.0 integration](./AMNEZIAWG3-REMNAWAVE-RU.md)
- [Container updates](./CONTAINER-UPDATES-RU.md)

## Security notes

- Keep Panel and node secrets out of logs, screenshots and issue reports.
- Do not expose PostgreSQL, Valkey or internal Panel API ports publicly.
- Restrict the cascade bridge port to the entry VPS IP whenever possible.
- Review UFW rules after installing additional protocols.
- Keep backups outside the VPS.
- Treat unattended application updates and database major upgrades differently.

---

> [!CAUTION]
> Use this project only where permitted by applicable law and your network/provider terms. The maintainers are not responsible for data loss, downtime, misconfiguration or legal consequences.

## Community

Telegram chat: [https://t.me/remnawave_reverse](https://t.me/remnawave_reverse)

## Donations

- **TON USDT:** `UQAxyZDwKUPQ5Bp09JOFcaDVakjYQT46rf3iP3lnl_qc9xVS`
