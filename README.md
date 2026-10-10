# ourostack/cmux

This fork of [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) is a mirror kept current for Ouro. Nothing is built or released from it.

- `main` is a pure mirror of upstream `main`. Never commit to it.
- `v*` release tags are mirrored from upstream.
- `ouro-patches` holds our patch stack on top of upstream `main`. It is empty for now.
- `ouro` (this default branch) holds only the sync workflow and this README.

GitHub Actions is disabled on this repository so that none of upstream's workflows ever run here.

The [Upstream sync](.github/workflows/upstream-sync.yml) workflow fast-forwards `main`, mirrors tags and rebases `ouro-patches` onto upstream `main`; if the patch stack stops rebasing cleanly, it opens or updates one issue and closes it once a later sync succeeds. It needs a `FORK_SYNC_TOKEN` secret, because `GITHUB_TOKEN` may not move refs across upstream changes to `.github/workflows`, and it must run from another repository, because pushes made with any other token trigger upstream's push workflows here. The file's header explains both.
