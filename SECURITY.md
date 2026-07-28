# Security Policy

## What this repository is

An infrastructure-as-code lab for running reproducible OpenNMS Horizon
benchmarks. It provisions disposable VMs, loads them with synthetic SNMP, flow
and syslog traffic, and throws them away.

**It is deliberately not hardened, and it must never be deployed into a
production network or exposed to the internet.** By design the lab ships:

- default credentials (`admin` / `admin` for the OpenNMS UI, Grafana and
  pgAdmin) documented openly in the README
- unauthenticated Prometheus, Jaeger, Kafka UI and nl6 endpoints
- a self-signed TLS certificate generated at provisioning time
- an open management network between all lab VMs, with host key checking
  disabled for Ansible

None of the above are vulnerabilities. They are the point: the lab trades
security for reproducibility and fast teardown. Reporting them will get a
pointer back to this section.

## What to report

Report anything that undermines the *tooling* in ways an operator would not
expect, for example:

- provisioning code that exposes a lab beyond its intended network boundary
- a credential, key or token committed to the repository, or written somewhere
  it outlives the lab
- a supply-chain problem in the pinned dependencies — a forged action pin, a
  compromised Ansible collection SHA, a malicious container image reference
- a workflow that could be made to execute untrusted input with elevated
  permissions

## How to report

Use GitHub's **private vulnerability reporting** — the *Report a vulnerability*
button under this repository's **Security** tab. That opens a private advisory
visible only to maintainers.

Please do not open a public issue for something you believe is genuinely
sensitive. For everything else, a normal issue is the right place.

Expect an acknowledgement within about a week. This is a personal project
maintained in spare time, so please calibrate expectations accordingly — there
is no commercial support commitment behind it.

## Vulnerabilities in OpenNMS itself

This repository *deploys* OpenNMS Horizon; it is not the OpenNMS project. A
vulnerability in Horizon, Minion, Sentinel or the OpenNMS codebase belongs to
the OpenNMS project's own security process, not here — report it there so it
reaches the people who can actually fix it.

Report it here only if the problem is in how *this lab* configures or provisions
those components.

## Supported versions

There are no releases. `main` is the only supported ref; fixes land there and
nowhere else.
