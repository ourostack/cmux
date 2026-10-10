# ourostack/cmux

This fork of [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) is a mirror kept current for Ouro. Nothing is built or released from it.

- `main` is a pure mirror of upstream `main`. Never commit to it.
- `v*` release tags are mirrored from upstream.
- `ouro-patches` holds our patch stack on top of upstream `main`. It is empty for now.
- `ouro` (this default branch) holds only the sync workflow and this README.

The [Upstream sync](.github/workflows/upstream-sync.yml) workflow runs every 6 hours and on demand. It fast-forwards `main`, mirrors tags and rebases `ouro-patches` onto upstream `main`. If the patch stack stops rebasing cleanly, it opens or updates one issue and closes it once a later sync succeeds.

Upstream's own workflows never run here: scheduled workflows run only from the default branch, which carries none of them, and the sync bot's ref updates use `GITHUB_TOKEN`, which does not trigger workflows.
