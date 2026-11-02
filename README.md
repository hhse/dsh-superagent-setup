# dsh-superagent-setup

A Codex / DeepSeek Harness skill for installing and operating **dsh-superagent** — a proactive agent that watches one GitHub repository, turns an `@mention` into a ticket, and a ticket into a reviewed pull request.

This is not a copy of the upstream documentation. It is the setup that was actually executed end to end, including the three traps that cost a full debugging session each and are not obvious from the docs.

## What's inside

```
SKILL.md                  the runbook: probe → install → profile → accounts → configure → first ticket → operate
references/accounts.md    why the agent needs its own GitHub account, and how to wire it
references/config.md      the management API, every settings block, the prepare command, the model route
references/pitfalls.md    symptom → cause → fix, with the failing call sites
references/operations.md  status codes, health entries, pause, hourly check, backup, upgrade, migration
scripts/preflight.sh      read-only prerequisite and identity check
```

## The three facts that decide the whole setup

1. **The agent must have its own GitHub account.** Anything authored by the agent's own login is dropped before it enters the domain (`sameName(comment.user.login, login)` in the GitHub Source), and GitHub never notifies an account of its own activity. One shared account receives exactly zero triggers, whatever the policy says.
2. **The model route must work from a plain shell.** The shipped profile default is the API-key route; a machine signed in through a DeepSeek account uses the account route instead, and every turn then fails with `MISSING_CREDENTIAL` while the panel only shows assessments timing out. An existing Session also caches the route it last used, so fixing the default is not enough.
3. **It watches one repository on github.com.** No GitHub Enterprise, no multi-repository. Start with a scratch repository and `observe` mode.

## Quick start

Ask your coding agent:

> Read SKILL.md and set up dsh-superagent with me.

Or run the checks by hand:

```sh
./scripts/preflight.sh
```

It reports prerequisites, both GitHub identities, whether the `superagent` profile already exists, and whether the network is behind a proxy that will cause intermittent `EOF` failures.

## Verified against

- DeepSeek Harness `0.2.1-rc.3`, `dsh-superagent` reference prototype (commit `6337fc8`, `engines.dsh: ^0.2.1-alpha.2`)
- macOS 15 (Apple Silicon), Node 22.23, pnpm 10.28, tmux 3.8, gh 2.80
- Full loop: issue comment → ticket → worker Session → `git worktree` → pull request → human merge → ticket `merged` → panel back to zero

## Notes

The upstream project is a research prototype, not production software. Executor Sessions run as the operator's OS user with full access; `blockedCommands` is name-based and an absolute path bypasses it. Read `references/operations.md` before pointing it at a repository that matters.

Upstream: <https://github.com/deepseek-ai/dsh-superagent-prototype> (MIT).
