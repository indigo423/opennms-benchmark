# Proxmox preflight ladder

A throwaway Terraform root that answers one question before the lab stack is applied: **does the `bpg/proxmox` path work against this host?**

The lab stack has five independent prerequisites on a fresh Proxmox node.
Applying it first means all five sit on the critical path at once, so a failure cannot be attributed.
This stack climbs them one at a time.

It is not part of `make deploy`.
It creates almost nothing, keeps its own state, and is destroyable on its own.

## The rungs

| Rung | Proves | Creates |
|:--|:--|:--|
| 0 | Endpoint URL scheme, TLS trust, API token authentication | nothing |
| 1 | Node name, datastore names, datastore content types, free space | nothing |
| 2 | SSH agent → PAM account → SFTP → snippets datastore | one file |
| 3 | Template clone, cloud-init delivery, guest agent reporting back | one VM |

Reads are cumulative, creates are exclusive.
Rung 3 does not create rung 2's probe file, and no rung creates the resources of a later one.

**Rungs 0 through 2 passing is the affirmative answer.**
Everything beyond that is host preparation, not provider verification.

## Running it

Credentials come from the lab stack's `proxmox.tfvars`, so there is one place to keep them.

```bash
cd terraform/proxmox/preflight
terraform init

terraform apply -var-file=../proxmox.tfvars -var rung=0
terraform apply -var-file=../proxmox.tfvars -var rung=1
terraform apply -var-file=../proxmox.tfvars -var rung=2
terraform apply -var-file=../proxmox.tfvars -var rung=3

terraform destroy -var-file=../proxmox.tfvars -var rung=3
```

Rungs 0 and 1 create nothing, so there is nothing to destroy after them.

This is the one place in the repo where `terraform` is invoked directly rather than through `make`.
That is deliberate: `make deploy` is the front door for *deploying the lab*, and this stack deploys nothing.
Its lint gates do run through `make` — see below.

## Rung 1 is the cheap catch

Rung 1 reads the host instead of trusting `proxmox.tfvars`, and reports rather than aborts, so one run surfaces every problem it can see:

- `node_name_matches` — a `proxmox_node` that does not exist on the cluster, with the names that do.
- `snippets_datastore_ready` — whether the datastore can hold snippets **and the `pvesm` command to fix it if not**.
- `datastore_content_types` — the full picture, in case `storage_pool` is wrong too.
- `datastore_space_available_gib` — reconcile against the lab stack's total provisioned disk before applying it. A full LVM-thin pool corrupts guests rather than failing writes.

A default PVE installation does **not** enable the `snippets` content type on `local`, so expect rung 1 to report it missing on a fresh node.

## When a rung fails

| Symptom | Cause | Fix |
|:--|:--|:--|
| Rung 0: connection refused, or a 301 | Endpoint uses `http`. Port 8006 redirects, and the provider does not follow it. | Use `https://` |
| Rung 0: certificate signed by unknown authority | The node presents its own PVE Cluster Manager CA | `proxmox_insecure = true`, or add the node's `/etc/pve/pve-root-ca.pem` to the local trust store |
| Rung 0: 401 | Token wrong, expired, or lacking privileges. Note the available privilege list **changed in PVE 9.0**, so pre-9 recipes do not transfer. | Recreate the token |
| Rung 1: node not found | `proxmox_node` is the node's own name, not the API hostname | Use a name from the `node_names` output |
| Rung 2: SSH failure, not an API error | No key for the PAM account in the operator's SSH agent. An API token carries no password for the SSH session to inherit. | `ssh-add` a key authorized for `proxmox_ssh_username` on the node |
| Rung 2: datastore rejects the upload | Datastore does not permit `snippets`, or is LVM-thin | `pvesm set <datastore> --content <existing>,snippets`. LVM-thin cannot hold snippets at all; point at a file-based datastore. |
| Rung 3: clone fails on a missing VM ID | No template at `template_vm_id` | Create it. `qm importdisk` is deprecated on PVE 9; import during `qm set` instead. |
| Rung 3: **timeout waiting for the guest agent** | The clone has no egress, so cloud-init could not install `qemu-guest-agent` | Not a provider defect. Rung 3 uses the uplink bridge with DHCP precisely to avoid this; if it happens there, the template or the bridge is wrong. |

That last row is the one to internalise.
On the lab stack it is the expected failure when the hypervisor does not route the management subnet, and it presents as a provider timeout that says nothing about routing.

## Why rung 3 looks the way it does

One vCPU, 1 GiB, 8 GB, a single NIC on the hypervisor's own uplink bridge, DHCP.

It deliberately depends on neither the four isolated lab bridges nor management-subnet routing, so a failure is attributable to the template, the clone, or cloud-init.
It reuses the shared `modules/cloud-init` rather than a hand-rolled document, so it proves the template the lab stack actually renders.
It does not reuse `modules/compute`, which defines seven VMs and is the opposite of minimal.

`preflight_vm_id` defaults to `9999`, outside both the lab stack's `vm_ids` (196–202) and the template ID, and a variable validation enforces it.
The VM is tagged `proxmox-preflight` rather than `opennms-benchmark`, so leftovers are obvious in the Proxmox UI.

## Lint

Covered by `make lint` like every other Terraform root:

- `make fmt` — recursive over `terraform/`, reaches this directory
- `make tflint` — `tflint-proxmox` runs `tflint --recursive` from the provider root, reaches this directory and inherits its `.tflint.hcl`
- `make validate-extra-roots` — this root explicitly, because `validate-%` resolves one root via `-chdir`

No gate plans or applies this stack.
The verification target is RFC1918 and reachable only from the lab network, so CI never contacts a Proxmox endpoint.

## Keeping it

This stack outlives the first verification.
`bpg/proxmox` is pinned `~> 0.99`, so a minor bump lands without a code change, and the repo has already shipped a provider bump that was only ever `validate`d and never planned against a real endpoint.
Re-climbing rungs 0 through 2 after a bump takes a minute and creates one file.
