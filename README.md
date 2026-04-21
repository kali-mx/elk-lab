# elk-lab

Local ELK Stack SOC Lab for TryHackMe - "Elastic: Setting up a SOC Lab"

Automated Docker-based setup that replicates the THM room environment locally. Single install script handles everything end to end including Fleet Server configuration, agent enrollment, ingest pipeline creation, and VPN log generation.

---

## Platform

Tested on:

- **Host:** Apple M2 Mac Studio
- **VM:** Kali Linux aarch64 (VMware Fusion)
- **Kali version:** 2024.x rolling (ARM64)
- **Docker:** docker.io 28.x (Kali packaged)
- **docker-compose:** v2.x (Kali packaged)
- **Elastic Stack version:** 9.2.4

> This setup has not been tested on x86_64 or other distributions. The Elastic image paths and ARM64 compatibility notes are specific to this environment. If you are on x86_64 Kali, the script **should** work but is untested.

---

## Prerequisites

- Kali Linux VM (aarch64 recommended, x86_64 untested)
- At least 6GB free disk space before running (images are ~4GB)
- Internet access (image pull from docker.elastic.co)
- Run as a normal user - NOT root (script uses sudo internally)

---

## Quick Start

```bash
# Clone the repo
git clone https://github.com/kali-mx/elk-lab.git
cd elk-lab

# Make the script executable
chmod +x elk-install.sh

# Run
./elk-install.sh
```

Total time on first run: ~5 minutes (mostly image pull).
Subsequent restarts: ~90 seconds.

---

## What the Script Does

The install script runs fully automated through 11 phases:

1. Pre-flight checks (user, sudo, Docker group, disk space)
2. Creates `~/elk-lab/` with docker-compose.yml and .env
3. Starts Elasticsearch and Kibana, waits for healthy
4. Generates Fleet service token via ES API
5. Configures Fleet Server host and output URLs (9.x API workarounds)
6. Starts Fleet Server, waits for ready
7. Fetches agent enrollment token automatically
8. Starts Elastic Agent
9. Creates VPN ingest pipeline (Grok + Date processors)
10. Generates 500 VPN log entries at `/var/log/vpnlog`
11. Prints final status and next steps

---

## Endpoints

| Service | URL | Credentials |
|---|---|---|
| Kibana | http://localhost:5601 | elastic / Change_me! |
| Elasticsearch | http://localhost:9200 | elastic / Change_me! |
| Fleet Server | http://localhost:8220 | - |

---

## After Install - Manual Step

One step requires the Kibana UI - add the Filestream integration:

1. Management -> Integrations -> Custom Logs (Filestream)
2. Click Add Custom Logs (Filestream)
3. Click Change defaults
4. Path: `/var/log/vpnlog`
5. Ingest Pipeline: `vpn.logs.pipeline`
6. Leave "Use the logs data stream" OFF
7. Existing hosts -> Fleet Server Policy
8. Save and continue -> Save and deploy

Wait ~60 seconds then verify in Discover:

```
Query: event.module: "filestream"
Time range: Last 24 hours
Expected: 500 documents
```

---

## Lifecycle

```bash
# Shutdown (keeps all data and tokens)
cd ~/elk-lab && docker-compose down

# Restart after shutdown (~90 sec)
./elk-install.sh --restart

# Full wipe and reinstall from scratch
./elk-install.sh --wipe

# Help
./elk-install.sh --help
```

---

## Disk Management

Docker images consume ~4GB. Volumes consume ~1GB when running. 

To free space when not using the lab:

```bash
# Stop and remove containers + volumes
cd ~/elk-lab && docker-compose down -v

# Remove cached images (~4GB)
docker image prune -a -f

# Full Docker cleanup
docker system prune -a --volumes -f
```

Re-running `./elk-install.sh` after a full prune re-downloads images (~5 min).

---

## VPN Log Data

The `vpnlog.py` script generates data using `random.seed(42)`. Every run produces identical user distributions and auth patterns - lab question answers are consistent across installs.

Key data properties:
- 500 log entries across 20 users
- `s.summer` has 5x activity weight (most active user)
- `p.mallow` receives 25 of 40 auth_fail events
- Locations: `us-east-1`, `us-west-1`, `uk-london` (uk-london 3x weight)
- Timestamps start from `now - 16 hours` - always within Last 24 hours

To regenerate logs (e.g. after a restart):

```bash
sudo python3 ~/elk-lab/vpnlog.py
```

Then wipe and re-index:

```bash
# Must wipe fleet-data volume to clear filestream offset registry
cd ~/elk-lab
curl -s -u elastic:Change_ME! -X DELETE \
  'http://localhost:9200/_data_stream/logs-filestream.generic-default' > /dev/null

docker-compose stop fleet-server
docker rm fleet-server
docker volume rm elk-lab_fleet-data
COMPOSE_HTTP_TIMEOUT=200 docker-compose up -d fleet-server

sleep 90 && curl -s -u elastic:Change_ME! \
  'http://localhost:9200/logs-filestream.generic-default-*/_count' \
  | python3 -m json.tool
```

---

## Files

| File | Purpose |
|---|---|
| `elk-install.sh` | Main install script - run this |
| `vpnlog.py` | VPN log generator (exact THM script) |
| `.env.example` | Environment variable template |
| `docs/troubleshooting.md` | Known issues and fixes |

---

## Notes on THM Room Differences

The THM room runs everything natively on a bare-metal VM. This Docker setup introduces networking differences that required several workarounds - all handled automatically by the install script:

- Fleet Server URL must use Docker service name (`fleet-server:8220`) not `localhost`
- Elasticsearch output must use Docker service name (`es01:9200`) not `localhost`
- Kibana 9.x rejects HTTP Fleet Server URLs in the UI - registered via API instead
- Fleet Server policy must be created manually via API (not auto-created in 9.x)
- `/var/log` mounted on fleet-server container only (not elastic-agent) to prevent duplicate indexing

See `docs/troubleshooting.md` for the full list of issues encountered and their fixes.

---

## Tested With

THM room: [Elastic: Setting up a SOC Lab](https://tryhackme.com/room/elasticlab)
