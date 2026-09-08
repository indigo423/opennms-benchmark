# base-image-pin fixtures

Exercised by `make validate-base-image-pin`.
A check whose failure path is never run quietly stops working, so both cases are asserted.

- `fx-stale-lab.json`: one OS volume backed by `ubuntu-24.04-base-f4d6c0a4a56d`, the tag the floating alias produces. Any dated pin must be refused against it.
- `fx-empty.json`: no OS volumes. A first deploy, which must never be obstructed.
- `fx-local-image.img` with `fx-local-lab.json`: a lab built from a local image file. The recorded tag is `sha256` of the file's **bytes**, so rewriting the file changes the tag. This is the branch that replaced hashing the URL string (#304), and the test rewrites the fixture in a temporary copy to prove it follows content rather than path.
- A floating alias is not a fixture case for this guard. The module's precondition rejects it before Terraform plans anything, so the guard derives no tag and stays silent rather than second-guessing a better error message.

They are named `.json`, not `.tfstate`, because `.gitignore` excludes `*.tfstate` so real state can never be committed.
A fixture that is silently untracked is a check that silently stops running.
