# Troubleshooting

All issues encountered during development and testing of this Docker-based ELK lab setup on Kali ARM64. The install script handles all of these automatically - this document exists for reference and manual recovery.

---

## Kibana stuck on "Starting saved objects migrations"

Cause: Elasticsearch cluster status is red with unassigned shards. This blocks Kibana migrations from completing.

Fix:

```bash
docker-compose down -v
sudo sysctl -w vm.max_map_count=262144
docker-compose up -d es01 kibana

# After ES starts, set replica count to 0
sleep 25 && curl -s -X PUT http://localhost:9200/_template/default \
  -H 'Content-Type: application/json' \
  -d '{"index_patterns":["*"],"settings":{"number_of_replicas":"0"}}' \
  | python3 -m json.tool
```

Ensure `cluster.routing.allocation.disk.threshold_enabled=false` is set in the ES environment.

---

## fleet-server: "no handler found" on token endpoint

Cause: `xpack.security.enabled=false` disables the entire `_security` API. Fleet token generation requires security enabled.

Fix: Ensure docker-compose.yml has both:
- `xpack.security.enabled=true`
- `xpack.security.http.ssl.enabled=false`

---

## Kibana Fleet UI: "Invalid URL (must be an https URL)"

Cause: Kibana 9.x enforces HTTPS for Fleet Server URLs in the UI.

Fix: Register the Fleet Server host via API instead:

```bash
curl -s -u elastic:CHANGEME! \
  -X POST http://localhost:5601/api/fleet/fleet_server_hosts \
  -H 'Content-Type: application/json' \
  -H 'kbn-xsrf: true' \
  -d '{"name":"fleet-server","host_urls":["http://fleet-server:8220"],"is_default":true}' \
  | python3 -m json.tool
```

Note: use `fleet-server` (Docker service name) not `localhost` - localhost resolves to the container itself.

---

## elastic-agent: "dial tcp localhost:9200 connection refused"

Cause: Fleet default output is configured with `localhost:9200`. Inside a Docker container, localhost resolves to the container itself, not the ES container.

Fix:

```bash
curl -s -u elastic:CHANGEME! \
  -X PUT http://localhost:5601/api/fleet/outputs/fleet-default-output \
  -H 'Content-Type: application/json' \
  -H 'kbn-xsrf: true' \
  -d '{"name":"default","type":"elasticsearch","hosts":["http://es01:9200"],"is_default":true,"is_default_monitoring":true}' \
  | python3 -m json.tool

docker-compose restart elastic-agent
sleep 20 && curl -s -u elastic:CHANGEME! \
  'http://localhost:9200/logs-*/_count' | python3 -m json.tool
```

---

## enrollment_api_keys returns empty list

Cause: No agent policies exist yet. Enrollment keys are auto-created per policy.

Fix: Create the Fleet Server policy first:

```bash
curl -s -u elastic:CHANGEME! \
  -X POST http://localhost:5601/api/fleet/agent_policies \
  -H 'Content-Type: application/json' \
  -H 'kbn-xsrf: true' \
  -d '{"name":"Fleet Server Policy","namespace":"default","has_fleet_server":true}' \
  | python3 -m json.tool
```

Kibana auto-assigns `id: "fleet-server-policy"` when `has_fleet_server:true`. Re-query enrollment keys after this.

---

## fleet-server: "Waiting on default policy with Fleet Server integration"

Cause: Fleet Server requires a policy with `has_fleet_server:true`. In 9.x this is not auto-created.

Fix: Create the Fleet Server policy (see above). Fleet Server picks it up within seconds and transitions to HEALTHY.

---

## fleet-server exits immediately (code 0)

Cause: docker-compose v1 HTTP timeout killed the `up` command before the container finished starting.

Fix:

```bash
docker rm fleet-server
COMPOSE_HTTP_TIMEOUT=200 docker-compose up -d fleet-server
```

---

## ERROR: No such service

Cause: Wrong or missing docker-compose.yml on disk.

Fix:

```bash
cat ~/elk-lab/docker-compose.yml | grep -E "^  [a-z].*:"
# Should show: es01, kibana, fleet-server, elastic-agent
```

If missing, re-run `./elk-install.sh` which regenerates the file.

---

## ERROR: manifest not found for elastic-agent

Cause: Wrong image path. Changed in 9.x.

- WRONG: `docker.elastic.co/beats/elastic-agent:9.x`
- CORRECT: `docker.elastic.co/elastic-agent/elastic-agent:9.x`

---

## "unknown shorthand flag: d in -d"

Cause: docker-compose v1 installed (Kali default package). v2 plugin uses `docker compose` (space), v1 uses `docker-compose` (hyphen).

Fix:

```bash
# Install v2 plugin
sudo apt install docker-compose-plugin
# Then use: docker compose (space)
```

Or just use `docker-compose` (hyphen) consistently with v1.

---

## Docker group not active after install

Cause: User added to docker group but session has not picked up the change.

Fix - Option A: Log out and back in, then re-run the script.

Fix - Option B (this session only):

```bash
newgrp docker
./elk-install.sh
```

---

## fleet-server keeps restarting on first boot

Expected behavior. Fleet Server polls Kibana for its policy and restarts until Fleet setup completes. Stabilizes within 2-3 minutes of Kibana being available.

---

## VPN logs not appearing / filestream index missing

Step-by-step diagnosis:

```bash
# 1. Check fleet-server can see the file
docker exec fleet-server ls -lh /var/log/vpnlog
# If NOT FOUND: fleet-server needs /var/log mount in docker-compose.yml

# 2. Check pipeline exists
curl -s -u elastic:CHANGEME! \
  http://localhost:9200/_ingest/pipeline/vpn.logs.pipeline \
  | python3 -m json.tool

# 3. Check pipeline was called (count > 0 after data flows)
curl -s -u elastic:CHANGEME! \
  'http://localhost:9200/_nodes/stats/ingest' \
  | python3 -m json.tool | grep -A3 "vpn.logs.pipeline"

# 4. Find the actual index
curl -s -u elastic:CHANGEME! \
  'http://localhost:9200/_cat/indices?v&h=index,docs.count&expand_wildcards=all' \
  | grep filestream
# Look for: .ds-logs-filestream.generic-default-* with ~500 docs
```

---

## Duplicate VPN log entries (720, 1000, 2000 instead of 500)

Cause: Both fleet-server and elastic-agent had `/var/log` mounted and both were enrolled in the same policy with the filestream integration. Both agents indexed the same file independently.

Fix: Remove `/var/log` mount from elastic-agent in docker-compose.yml - only fleet-server needs it. The install script handles this correctly.

Manual fix if needed:

```bash
# Delete the data stream
curl -s -u elastic:CHANGEME! \
  -X DELETE 'http://localhost:9200/_data_stream/logs-filestream.generic-default' \
  | python3 -m json.tool

# Wipe fleet-data volume to reset filestream offset registry
cd ~/elk-lab
docker-compose stop fleet-server
docker rm fleet-server
docker volume rm elk-lab_fleet-data
COMPOSE_HTTP_TIMEOUT=200 docker-compose up -d fleet-server

sleep 90 && curl -s -u elastic:CHANGEME! \
  'http://localhost:9200/logs-filestream.generic-default-*/_count' \
  | python3 -m json.tool
```

---

## Filestream re-index returns 0 after deleting data stream

Cause: Filestream records file offsets in a state registry inside the fleet-data volume. After deleting the data stream, fleet-server thinks it already processed the file.

Fix: Wipe the fleet-data volume to clear the registry (see above). Restarting the container alone is not enough.

---

## Disk space accumulation across multiple wipe cycles

Cause: `docker-compose down -v` removes named volumes but leaves orphaned volumes from previous runs. Docker images (4GB) also persist until explicitly removed.

Cleanup sequence:

```bash
cd ~/elk-lab && docker-compose down -v
docker volume prune -f
docker image prune -a -f
docker system prune -a --volumes -f
df -h /
```

---

## Why THM Room Instructions Break in Docker

The THM room assumes bare-metal enrollment. In Docker, every container has its own network namespace:

| THM instruction | Docker problem | Fix applied by script |
|---|---|---|
| Fleet Server URL: `https://MACHINE_IP:8220` | UI rejects HTTP, localhost wrong in container | Register via API with `fleet-server:8220` |
| ES output: `localhost:9200` | Resolves to the container itself | Update output to `es01:9200` via API |
| Agent reads `/var/log` directly | Container does not mount host `/var/log` | Add volume mount to fleet-server compose config |
| `event.module: "filestream"` in Discover | Works correctly with real THM vpnlog.py script | Use real script with `random.seed(42)` |
