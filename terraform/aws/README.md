# AWS provider

Provisions the lab on EC2 from `deployments/<slug>/topology.yml`.

> [!WARNING]
> **Check whose account you are in.** These labs are cheap, but nothing stops
> them being provisioned beside production. Scope any cleanup to Terraform
> state or the deployment's resource group — never a console-wide tag sweep.
>
> This provider bills by the hour. `mimir-ha-min` is 19 instances. Run
> `make destroy PROVIDER=aws CONFIRM=yes` when you are done, and verify in the
> console rather than trusting Terraform state alone.

## Status

Statically verified only. `make validate-aws`, `make tflint-aws` and `make fmt`
pass, and every supported spec renders through `terraform console` without
contacting AWS. **No `terraform apply` has been run**, so this is proven in
shape, not in behaviour. See #174.

## Setup

```bash
cp aws.tfvars.example aws.tfvars   # edit region, project, ssh_key_path
aws login                          # or aws configure sso / aws configure
aws sts get-caller-identity        # confirm you are signed in
make deploy PROVIDER=aws DEPLOYMENT=baseline
```

**`aws login` alone is not enough for Terraform.** It writes a token cache the
AWS CLI understands and the Terraform provider does not, so the CLI works while
Terraform reports `No valid credential sources found` after a two-minute IMDS
probe. `deploy.sh` handles this: it exports whatever the CLI has resolved via
`aws configure export-credentials` and disables the IMDS fallback so a genuine
absence of credentials fails immediately with a usable message. Running
Terraform by hand needs the same step:

```bash
eval "$(aws configure export-credentials --format env)"
```

`deploy.sh` detects your public address and passes it as `operator_cidr`, which
scopes SSH ingress to the jump host. If detection fails the provider fails
closed — `0.0.0.0/32`, reachable by nobody — rather than opening the lab.

## What differs from the hypervisor providers

**Spec-driven, with no per-host address variables.** Like `kvm` and unlike
`azure`/`proxmox`/`vmware`, this root reads the deployment spec and derives every
address from it. It declares no `ip_database`/`ip_core` variables, so it cannot
drift from the other providers the way tracked in #161.

**One availability zone.** An ENI cannot span zones and lab nodes are multi-homed
across `mgmt`/`db`/`kafka`/`sim`, so every subnet lives in one AZ. That is also
what you want for a benchmark: cross-AZ latency is not the thing being measured.

**Static addressing comes from the platform.** The address is pinned on the ENI
and DHCP hands the guest exactly that, so `network_config_supported = false` and
the netplan document is unused. Static routes ride in user-data as a systemd
unit, the same path Azure uses.

**Burstable instances are confined to the smoke profile.** A `t`-class instance
depletes its CPU credits partway through a sustained run, so the second half of a
measurement is not comparable to the first. Azure's `Standard_B2ms`/`B4ms` has
this problem across the board; here it is contained to the tier where nothing is
being measured. `cost_profile = "benchmark"` uses `m6i` throughout.

**Storage is a sizing decision.** `gp3`'s 3000 IOPS baseline bottlenecks the
`database` and `clickhouse` roles well before CPU does. Raise `root_volume_iops`
for disk-bound work rather than accepting the default silently.

## Which account this builds in

Give the lab its own AWS account. Everything else here is a workaround for not
having done that: a dedicated account gives separate IAM, separate quotas, a
separate billing line, and no path to anything that matters — none of which a
tag convention can promise.

If your organization already exists, adding a member account is free:

```bash
aws organizations create-account \
  --email <alias>@example.com \
  --account-name "opennms-benchmark-lab" \
  --role-name OrganizationAccountAccessRole
```

Then add a profile that assumes into it, and point the lab at that profile:

```ini
# ~/.aws/config
[profile benchmark-lab]
role_arn       = arn:aws:iam::<NEW_ACCOUNT_ID>:role/OrganizationAccountAccessRole
source_profile = default
region         = us-east-1
```

```bash
AWS_PROFILE=benchmark-lab make deploy PROVIDER=aws DEPLOYMENT=baseline
```

`deploy.sh` prints the resolved identity before provisioning, so the account is
visible at the point it still matters.

Finally, pin it in `aws.tfvars` so a stray profile cannot undo the separation:

```hcl
allowed_account_ids = ["<NEW_ACCOUNT_ID>"]
```

Terraform then refuses to run anywhere else rather than quietly building a lab
beside production. Left empty, the check is disabled.

## Running under a restricted role

A dedicated account is the real answer. Until there is one, a scoped IAM role
removes the credentials' ability to damage anything else — which is what stops a
Terraform bug or a mistyped command, the failure that actually happens.

`docs/aws-iam/` holds the two policy documents. The role allows the EC2, SSM and
resource-group calls the lab makes, and explicitly denies:

- anything at all inside the production VPC (`ec2:Vpc` condition)
- destroying any resource not tagged `project = benchmark`
- `iam:*`, `organizations:*` and `account:*`, so it cannot grant itself more

```bash
aws iam create-role --role-name benchmark-lab \
  --assume-role-policy-document file://docs/aws-iam/trust-policy.json
aws iam put-role-policy --role-name benchmark-lab \
  --policy-name benchmark-lab-permissions \
  --policy-document file://docs/aws-iam/benchmark-lab-policy.json
```

```ini
# ~/.aws/config
[profile benchmark-lab]
role_arn       = arn:aws:iam::<ACCOUNT_ID>:role/benchmark-lab
source_profile = default
region         = us-east-1
```

```bash
AWS_PROFILE=benchmark-lab make deploy PROVIDER=aws DEPLOYMENT=baseline
```

### Re-authenticating

`benchmark-lab` names a role, not a credential source. It holds no credentials of
its own and assumes into the role using `source_profile`, so sign in against
**that** profile, not this one:

```bash
AWS_PROFILE=default aws login          # or: unset AWS_PROFILE && aws login
export AWS_PROFILE=benchmark-lab
```

Running `aws login` with `AWS_PROFILE=benchmark-lab` selected fails with:

```
Profile 'benchmark-lab' is already configured with Assume Role credentials.
```

which does not hint that `default` is the one to log into.

Sessions are short — a few hours — so this comes up whenever one lapses
mid-work. Confirm the whole chain afterwards, since it proves both the login and
the role assumption:

```bash
aws sts get-caller-identity --query Arn --output text
# arn:aws:sts::<ACCOUNT_ID>:assumed-role/benchmark-lab/benchmark-lab
```

If that returns a `user/...` ARN, `AWS_PROFILE` was not re-set and `deploy.sh`
will refuse to deploy.

`AWS_PROFILE` is **required** to deploy. Without it Terraform would use whichever
credentials happen to be default, which on a shared account is usually the most
privileged identity available — the one thing that should not be building a
disposable lab. `deploy.sh` refuses and lists the profiles it can see.

Destroying only warns. A lab nobody can tear down keeps billing, so being unable
to remove one is worse than removing it with more authority than needed.

Setting the variable is not by itself proof of anything: `AWS_PROFILE=default`
satisfies it while still being the unrestricted user. `deploy.sh` also reports
the resolved identity and says so when it is an IAM user rather than an assumed
role.

`AWS_ALLOW_DEFAULT_CREDENTIALS=1` bypasses the requirement, for CI or static keys
supplied by the environment rather than a profile.

Verify it before trusting it — a policy that denies nothing looks identical to
one that works until the day it matters:

```bash
AWS_PROFILE=benchmark-lab aws ec2 terminate-instances --dry-run --instance-ids <a-production-instance>
# UnauthorizedOperation ... with an explicit deny in an identity-based policy
```

**This stops accidents, not you.** Anyone holding `iam:*` can revoke the
restriction, so it is a seatbelt rather than a wall. Only a separate account, or
an SCP someone else controls, makes it a boundary.

## Checking what is deployed

```bash
make show PROVIDER=aws                        # everything tagged project=benchmark
make show PROVIDER=aws DEPLOYMENT=baseline    # narrowed to one deployment
```

Reports Terraform's view and AWS's view separately, then reconciles them. The
second view is the point: a leftover is by definition something state no longer
tracks, so `terraform state list` cannot find one. Anything live at AWS with an
empty state is an interrupted apply, a failed destroy, or something made by
hand — and instances, NAT gateways and Elastic IPs bill either way.

It queries each EC2 service directly rather than the Resource Groups Tagging
API, which keeps returning deleted resources for about a day and would report a
clean teardown as a pile of leftovers.

## Seeing just this lab in the console

Every resource carries `project`, `environment` and `deployment` tags via the
provider's `default_tags`, and Terraform creates a resource group querying them:

```bash
terraform -chdir=terraform/aws output -raw console_url
```

That opens a console view containing this deployment and nothing else. One group
per deployment, so two labs running at once stay distinct. Resource groups cost
nothing.

Without applying anything, Tag Editor does the same ad hoc — filter on
`deployment = <slug>` under **Resource Groups & Tag Editor → Tag Editor**.

For spend rather than inventory, activate `project` and `deployment` as cost
allocation tags in Billing → Cost Allocation Tags; Cost Explorer can then break
the bill down per deployment. AWS takes up to 24 hours to start populating them.

## Cost profiles

`cost_profile` picks between measurement-grade infrastructure and the cheapest
shape that still brings the stack up.

| | `benchmark` | `smoke` (default) |
|---|---|---|
| instances | `m6i` fixed-performance | `t3a` burstable |
| root volumes | per-role, up to 100 GiB | capped at `smoke_max_disk_gb` (20) |
| spot | refused | allowed via `spot = true` |
| `baseline` (7 nodes), us-east-1 | ~$1.15/hr | ~$0.28/hr, or ~$0.13/hr on spot |

Rough figures, from list prices that drift — check the calculator before
budgeting. Instances dominate; the NAT gateway (~$0.045/hr) and EBS are minor
by comparison, which is why the tier changes instance types rather than
architecture.

**`smoke` is the default.** Cost is opted into, not out of: the expensive
mistake is provisioning measurement-grade instances without meaning to, and the
cheap mistake is a run that has to be repeated.

```bash
make deploy PROVIDER=aws DEPLOYMENT=baseline                                  # smoke
make deploy PROVIDER=aws DEPLOYMENT=baseline TF_ARGS="-var cost_profile=benchmark"
```

**A smoke lab cannot produce valid numbers.** Burstable instances deplete their
CPU credits partway through a sustained run, so the second half of a
measurement is not comparable to the first — the failure is silent, and the
numbers look entirely plausible. Since it is also the default, five things make it hard to miss:

- `deploy.sh` announces the profile *before* provisioning, so it can be acted
  on rather than regretted, and prints a banner again when the deploy finishes
- every instance is tagged `cost-profile`
- every host carries `lab_cost_profile` in the Ansible inventory, so a report or
  experiment ledger can record which kind of infrastructure it ran on
- `terraform output cost_profile` states it
- `spot = true` under `cost_profile = "benchmark"` fails the plan outright: an
  interruption mid-run yields a partial result that still looks like a result

Use it to prove wiring — that cloud-init lands, the jump host works, the
simulated network routes, Ansible reaches every node. Then switch to
`benchmark` before measuring anything.

## The simulated network

`netsim` answers for every address in `10.42.0.0/16`. On a hypervisor that is
free — it is a private L2 segment nobody validates. A VPC validates the source
and destination of every packet, so three things have to line up:

1. `ip route add local 10.42.0.0/16 dev lo` on the simulator, so the kernel
   accepts the whole range without an address per device. An ENI cannot carry
   ~1000 secondary addresses. This is emitted by `modules/cloud-init`'s
   `local_routes`, and this provider is its first consumer anywhere in the repo.
2. A VPC route-table entry sending `10.42.0.0/16` at the simulator's `sim` ENI.
3. `source_dest_check = false` on that ENI, needed in **both** directions: polls
   arrive for addresses that are not the instance's own, and traps, syslog and
   flows leave with a source that is not its own either.

A route-table entry targets exactly one ENI, so **the simulator is capped at one
node**. The plan fails if a spec declares more. That matches every existing spec
and the reasoning in `deployments/README.md`: nl6 starts every generator at the
same `nl6_auto_start_ip`, so a second one duplicates the first rather than
extending it.

## Unsupported specs

`clickhouse-riptide` uses the `lab` subnet — a physical bridge on the KVM host
with site-pinned addresses and a route via a named machine on that LAN. There is
no VPC equivalent, so the plan fails with a message pointing at `PROVIDER=kvm`
rather than approximating something that does not match the spec.

The other 13 specs are supported.

## Known gaps

- ~~`192.0.2.0/24` as a VPC CIDR is unverified.~~ **Confirmed working**
  (2026-07-30): AWS accepts the shared supernet, so this provider stays on the
  same addressing as `kvm` rather than opening a third scheme in #161. The public
  subnet uses `198.51.100.0/28` (TEST-NET-2) as a secondary VPC CIDR, since the
  lab supernet fills its whole /24.
- **`modules/diagram` is skipped.** It takes ~15 hand-maintained `ip_*` inputs a
  spec-driven root does not have. Making it topology-driven is separate work.
- **Cost is estimated for `baseline` only.** The other twelve supported specs
  have no figure yet; `mimir-ha-min` at 19 nodes is the one worth knowing before
  someone starts it. Tracked in #174.
