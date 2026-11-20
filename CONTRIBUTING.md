# Contributing to resonance.nvim

Bug reports, fixes and small features are welcome. This page covers how to
report a problem and how to send a change.

## Reporting a bug

Open an issue on [GitHub](https://github.com/Imngzx/resonance.nvim/issues)
with:

- the output of `nvim --version` (Resonance needs Neovim 0.13 nightly);
- the spec that misbehaves, as small as you can make it;
- what you expected and what happened, with the error message if there is
  one.

A report that names the spec and the steps is usually fixed quickly. "It
does not work" is not enough to act on.

## Sending a change

1. Fork the repository on GitHub and create a branch.
2. Make the change and add a test for it (see below).
3. Run the suite: `./test/run_all.sh`. It must pass.
4. Open a pull request against `main`. CI runs the same suite on Neovim
   nightly.

Pull requests go to GitHub. The Codeberg repository is a mirror.

### Where to read first

| File | What it gives you |
|---|---|
| [`CODE_TOUR.md`](CODE_TOUR.md) | A guided walk through the code: glossary, file map, each flow as a story. |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | How the modules fit together and why. |
| [`AGENTS.md`](AGENTS.md) | The hard rules for editing the code, the code style and the development loop. Written for AI agents, and just as binding for people. |

### The development environment

The tests run in an isolated environment under `.dev/`, so nothing touches
your own Neovim config or plugins.

```bash
./test/run_all.sh                        # bootstrap if needed, then run everything
test/dev_env.sh test test/gc_spec.lua    # run one spec file
test/dev_env.sh nvim                     # an isolated Neovim for trying things by hand
rm -rf .dev                              # start over
```

You need `git`, `sh` and a Neovim nightly on your `PATH`.

### Tests

- A bug fix comes with a regression test that fails without the fix. Check
  that it does: `AGENTS.md` describes how under "Mutation-check new
  regression tests".
- A feature comes with tests for its normal use and its invalid input.
- Say *why* in a comment next to the fix, not only in the commit message.
  The comments are how the next reader learns what the code guards
  against.

### Rules that cause bugs when broken

`AGENTS.md` lists them in full under "Red lines". The two most often hit:

- never touch `vim.pack` directly, use `utils.get_pack()`;
- notify through `utils.notify`, never `vim.notify`.

### Documentation

If the change alters behaviour a user can see, update `README.md` and
`doc/resonance.txt`. After adding or renaming a `*tag*` in the help file,
regenerate the tags and commit them:

```bash
nvim --headless -c 'helptags doc' -c q
```

If the change alters a flow, update `CODE_TOUR.md` as well.

### Commit messages

Use the form `type(scope): summary`, for example
`fix(triggers): pass several words to a one-argument command as one argument`.
The types in use are `fix`, `feat`, `docs`, `test`, `ci`, `perf` and
`refactor`.

## AI-assisted changes

This plugin was built with AI assistance, and AI-assisted pull requests are
welcome on the same terms as any other: you have read the change, you can
explain it, and it comes with a test that passes. Point your agent at
`AGENTS.md` before it edits anything.

## License

By contributing you agree that your contribution is licensed under the
[MIT License](LICENSE).
