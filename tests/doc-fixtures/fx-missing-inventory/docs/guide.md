---
title: Fixture
---

# Fixture for validate-doc-inventories.py

Every block below must be classified correctly, or the check is not doing its
job. Cases A, B and C must fail. Cases D, E and F must pass.

## Case A: the bug #262 found

The name `inventory` refers to nothing. Ansible warns, matches no hosts, runs
nothing, and exits reporting success.

```bash
cd bootstrap
ansible-playbook -i inventory site.yml
```

## Case B: a stale name, no directory change

```bash
ansible-playbook -i opennms-lab-inventory.yml experiment.yml
```

## Case C: the directory change is what breaks it

The path is correct from the repository root and wrong from where the reader
has been sent. A check that resolved every path against the root would pass
this, which is why `cd` is tracked.

```bash
cd docs
ansible-playbook -i real-inventory.yml site.yml
```

## Case D: a real file

```bash
ansible-playbook -i real-inventory.yml site.yml
```

## Case E: generated, so absent by design

Gitignored, so it exists in a deployed checkout and never in continuous
integration. Requiring it to exist would fail every run on the machine that
most needs the check.

```bash
ansible-playbook -i ansible-inventory.<provider>.yml bootstrap/site.yml
```

## Case F: an inline host list, not a file

```bash
ansible-playbook -i localhost, site.yml
```

## Case G: prose, not a command

A yaml block is not a shell session, so this is not read as an invocation.

```yaml
example: ansible-playbook -i inventory site.yml
```
