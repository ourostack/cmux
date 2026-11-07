<!-- ourostack:brand:start -->
<p align="center">
  <a href="https://github.com/ourostack"><img src="https://raw.githubusercontent.com/ourostack/.github/main/brand/headers/labs.webp" alt="Ouro curled in the meadow beside a little glass greenhouse workshop, where a small robot repots a glowing sprout among jars of seedlings while the glowing trail forks in two and loops back together" width="100%"></a>
</p>
<!-- ourostack:brand:end -->

# cmux, our labs mirror

**Labs, unsupported:** our mirror of [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux), the terminal for coding agents. Nothing is built or released from it. Want cmux itself? Go to [cmux.com](https://cmux.com).

**Why we fork it:** [Shepherd](https://ouroboros.bot/#shepherd), the part of [Ouroboros](https://github.com/ourostack/ouroboros) that keeps terminal coding agents moving, works through cmux. This mirror is where we would carry patches while they wait for upstream; today there are none.

**About the "commits behind" banner:** GitHub compares this page's branch, `ouro`, which holds only this README and the sync. The mirror itself is [`main`](https://github.com/ourostack/cmux/tree/main), synced from upstream every few hours.

- [`main`](https://github.com/ourostack/cmux/tree/main) mirrors upstream `main` and its `v*` tags.
- [`ouro-patches`](https://github.com/ourostack/cmux/tree/ouro-patches) is where our patches go, on top of it. It is empty for now. Other branches are working branches, not the patch stack.

<details>
<summary>How the sync works</summary>

GitHub Actions is disabled on this repository so that none of upstream's workflows ever run here. Never commit to `main`.

The [Upstream sync](.github/workflows/upstream-sync.yml) workflow fast-forwards `main`, mirrors tags and rebases `ouro-patches` onto upstream `main`; if the patch stack stops rebasing cleanly, it opens or updates one issue and closes it once a later sync succeeds. It needs a `FORK_SYNC_TOKEN` secret, because `GITHUB_TOKEN` may not move refs across upstream changes to `.github/workflows`, and it must run from another repository, because pushes made with any other token trigger upstream's push workflows here. The file's header explains both.

Until that token exists, `scripts/sync-from-mac.sh` runs every 6 hours on a maintainer's machine. It syncs `main`, mirrors `v*` tags and keeps the empty `ouro-patches` equal to `main`.

</details>
