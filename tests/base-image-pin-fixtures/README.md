# base-image-pin fixtures

Exercised by `make validate-base-image-pin`.
A check whose failure path is never run quietly stops working, so both cases are asserted.

- `fx-stale-lab.json`: one OS volume backed by `ubuntu-24.04-base-f4d6c0a4a56d`, the tag the floating alias produces. Any dated pin must be refused against it.
- `fx-empty.json`: no OS volumes. A first deploy, which must never be obstructed.

They are named `.json`, not `.tfstate`, because `.gitignore` excludes `*.tfstate` so real state can never be committed.
A fixture that is silently untracked is a check that silently stops running.
