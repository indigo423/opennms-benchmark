# opennms_pyroscope_agent

Attaches the Grafana Pyroscope Java agent to an OpenNMS service so its JVM pushes continuous CPU profiles to the lab's Pyroscope server (#291).

Applied from `opennms-playbook.yml` to Core and Minion, after the collection's own role, because the systemd unit has to exist before a drop-in can extend it or a handler can restart it.

## What it does

- Downloads `pyroscope.jar` v2.9.1 to `/opt/pyroscope`, root-owned and read-only, verified against a pinned sha256.
- Drops `/etc/systemd/system/<unit>.d/pyroscope-agent.conf`, which sets `JAVA_TOOL_OPTIONS=-javaagent:...` plus the `PYROSCOPE_*` settings.
- Restarts the service when either changes, then re-checks Core readiness.
- Removes the drop-in and restarts once when profiling is off. The jar stays; only the drop-in decides whether a JVM loads it.

Never the jar OpenNMS bundles under `agent/`, and `PYROSCOPE_AGENT_ENABLED` is left unset, so `bin/opennms`'s own hook never loads a second agent.

## Why a systemd drop-in

`ADDITIONAL_MANAGER_OPTIONS` looks like the natural knob, but the collection renders `opennms.conf` whole from `opennms_jvm_conf`, and `deployments/kfk-exclusive` and `deployments/mimir-ha-min` replace that dict in full.
A flag added at the root file would be silently dropped on exactly the deployments that run today.

The drop-in touches no file the collection renders, and no deployment overlay can remove it. `JAVA_TOOL_OPTIONS` is read by every JVM the unit starts, so no start script needs to know the agent exists.

**This role owns `JAVA_TOOL_OPTIONS` for those units.** systemd `Environment=` assigns rather than appends and performs no expansion, so a second drop-in setting the same key replaces this one with nothing failing.

## Variables

See `defaults/main.yml`. Two are required and have no defaults, because a wrong guess would attach the agent to a unit that does not exist or file two hosts' profiles under one name:

| Variable | Core | Minion |
|---|---|---|
| `pyroscope_agent_unit` | `opennms.service` | `minion.service` |
| `pyroscope_agent_app_name` | `opennms-core` | `opennms-minion` |
| `pyroscope_agent_skip_startup` | `{{ skip_startup }}` | `{{ skip_minion_startup }}` |

`tasks/main.yml` asserts the first two are set, and that the server address is non-empty whenever profiling is on.

## The profiling switch

`lab_profiling_enabled` lives in **`group_vars/all/vars.yml`**, next to `lab_pyroscope_url` and `lab_pyroscope_port`.
It defaults to true whenever the topology has a monitoring host that publishes an in-lab address.

Turn it off for campaigns that report absolute numbers: the agent samples CPU at 100 Hz, costs a few percent, and a benchmark that profiles its system under test is measuring the profiler too.

```bash
# one run
ansible-playbook ... opennms-playbook.yml -e lab_profiling_enabled=false
```

**Toggling it restarts Core and Minion on the next deploy**, in either direction. That is the point of the switch, and it is not free: schedule the flip between trials, not inside one.

## Why azure and vmware are excluded

The server address comes from the first `mon_servers` host's `lab_mgmt_ip`, with no `ansible_host` fallback on purpose.
`azure` and `vmware` use `terraform/modules/inventory`, which emits no `lab_mgmt_ip`; on those providers `ansible_host` is the monitoring host's *public* address, and only 22 and 443 are open.
A fallback would silently address profiles out over the public interface and time out, so `lab_pyroscope_url` stays empty there and `lab_profiling_enabled` evaluates false.

## Verifying after deploy

The agent is not on the JVM command line: `JAVA_TOOL_OPTIONS` is read from the environment, so `ps` shows nothing. On each host:

```bash
systemctl show -p Environment opennms.service   # or minion.service
```

Expect `JAVA_TOOL_OPTIONS=-javaagent:/opt/pyroscope/pyroscope.jar` and `PYROSCOPE_SERVER_ADDRESS=http://<mon>:4040`.

Then read the service list from the Pyroscope datasource, or browse Grafana > Drilldown > Profiles: `opennms-core` and `opennms-minion` appear within about a minute of the restart, each labelled with its `hostname`.
**Only a rendered flame graph distinguishes "agent attached" from "agent attached and uploading".**
