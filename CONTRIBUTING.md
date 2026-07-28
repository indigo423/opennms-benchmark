# Contributing

Thanks for helping improve the OpenNMS benchmark lab.

This is an infrastructure-as-code lab for running reproducible OpenNMS Horizon
benchmarks. It is not a product and not intended for production deployments —
see [SECURITY.md](SECURITY.md).

## Before you start

Work starts from an issue. Open one describing the problem or the experiment you
want to add, so the discussion happens before the code. Drive-by pull requests
are harder to review and easy to duplicate.

## Making a change

`main` is protected. Every change goes through a pull request — no exceptions,
regardless of size.

```bash
git switch -c <type>/<short-description>
# ... make your change ...
make lint          # everything CI runs
git commit -s
```

Reference the issue in the pull request body with a closing keyword
(`Closes #123`) so it resolves automatically on merge.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/): `<type>[scope]: <description>`,
where type is one of `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
`chore`, `ci`, `build`, `revert`. Breaking changes append `!` or add a
`BREAKING CHANGE:` footer.

### Sign-off is required

Every commit needs a `Signed-off-by` trailer, added by `git commit -s`. This
certifies the [Developer Certificate of Origin](https://developercertificate.org/) —
that you wrote the contribution or otherwise have the right to submit it under
this repository's licence. A bot enforces it, and the `DCO` check blocks merges
without it.

The sign-off must be a human identity. Never sign off as an AI agent.

### AI-assisted contributions

AI assistance is welcome, and it should be visible. Commits produced with help
from an AI agent carry an `Assisted-by:` trailer naming the agent and model,
before the sign-off:

```
fix(traefik): resolve remote back ends from the inventory

Assisted-by: ClaudeCode:claude-opus-5
Signed-off-by: Your Name <you@example.com>
```

The human who signs off remains responsible for the change: for reviewing it,
for its correctness, and for its licence compliance. "The AI wrote it" is not a
defence for code you did not read.

## Checks

CI runs the same `make` targets you run locally — that is the point of the
Makefile, so please do not invoke `terraform`, `ansible-playbook` or the linters
directly in a workflow.

```bash
make lint            # fmt, validate, tflint, ansible, shell, python, yaml, actions, deployment specs
make lint-shell      # or run one at a time
make help            # every target
```

Pull requests must be green before merge. The required checks cover Terraform
formatting and validation across all four providers, TFLint, ansible-lint,
shellcheck, ruff, yamllint, actionlint + zizmor, the deployment specs, and DCO.

## Conventions worth knowing

- **GitHub Actions** are pinned to a full commit SHA with the exact version in a
  trailing comment (`uses: actions/checkout@11bd719…  # v4.2.2`). Never a bare
  tag. `zizmor` and `actionlint` enforce the surrounding rules.
- **`indigo423.opennms`** is pinned by git SHA in `requirements.yml` for
  benchmark reproducibility. Bumps are deliberate, reviewed pull requests, never
  automatic.
- **Deployment specs** live in `deployments/<slug>/topology.yml`; the directory
  slug and the `name:` field must match. `make validate-deployments` checks it.
- **New source files** need an SPDX licence header.

`CLAUDE.md` documents the architecture and the gotchas an automated agent — or a
new contributor — would otherwise get wrong. It is worth reading first.

## Licence

By contributing you agree that your contribution is licensed under the
[Apache License 2.0](LICENSE), as the rest of the project is.
