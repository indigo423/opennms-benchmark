---
title: Fixture
---

# Fixture for validate-doc-inventories.py

Every block below must be classified correctly, or the check is not doing its
job. Cases A to E must fail, and the path each resolves to is listed in
`EXPECTED` beside this document. Cases F to J must pass.

Several cases guard a specific regression: they pass when the check is wrong
and fail when it is right, or the reverse. Those are marked.

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

The path is correct from the fixture root and wrong from where the reader has
been sent. A check resolving every path against the root would pass this,
which is why `cd` is tracked.

```bash
cd docs
ansible-playbook -i other-inventory.yml site.yml
```

## Case D: a clone, then a descent into it

**Guards the clone regression.** The `cd` enters the clone and then a
subdirectory of it. A check that consumed the first `cd` after a clone
unconditionally would land at the fixture root, where `real-inventory.yml`
exists, and pass. The reader is in `docs/`, where it does not.

```bash
git clone https://example.invalid/fx-missing-inventory.git
cd fx-missing-inventory/docs
ansible-playbook -i real-inventory.yml site.yml
```

## Case E: a separator inside quotes

**Guards the quoting regression.** Splitting on `;` inside the quoted value
leaves both halves unbalanced, the parse fails, and the invocation is dropped
with no finding at all. The missing inventory must still be reported.

```bash
ansible-playbook -i quoted-missing.yml site.yml -e 'note=a;b'
```

## Case F: a real file

```bash
ansible-playbook -i real-inventory.yml site.yml
```

## Case G: generated, so absent by design

Gitignored, so it exists in a deployed checkout and never in continuous
integration. Requiring it to exist would fail every run on the machine that
most needs the check.

```bash
ansible-playbook -i ansible-inventory.<provider>.yml bootstrap/site.yml
```

## Case H: a placeholder containing spaces

**Guards the placeholder regression.** A naive split turns this into `<the`,
which matches no ignore rule and reports a false failure with an unreadable
message.

```bash
ansible-playbook -i ansible-inventory.<the provider>.yml bootstrap/site.yml
```

## Case I: an inline host list, not a file

```bash
ansible-playbook -i localhost, site.yml
```

## Case J: prose, not a command

A yaml block is not a shell session, so this is not read as an invocation.

```yaml
example: ansible-playbook -i inventory site.yml
```
