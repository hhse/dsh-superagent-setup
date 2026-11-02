---
name: dsh-superagent-setup
description: Install, configure, verify and operate the dsh-superagent bundle for DeepSeek Harness — a proactive agent for one GitHub repository that turns mentions into tickets, tickets into pull requests, and keeps a web panel of what needs a person. Use when someone asks to set up dsh-superagent, deploy an autonomous GitHub agent on DSH, debug a dsh-superagent install (setup exit codes 1/2/3, GitHub source errors, no ticket appearing), or migrate an existing instance to a new account, repository or machine.
---

# dsh-superagent setup

Deploy the `dsh-superagent` bundle from zero to a first merged pull request, then operate it.
This is the setup that was actually verified end to end: one mention in an issue produced a ticket, a worker session, a branch, a pull request, and a reply in the thread.

Repository: <https://github.com/deepseek-ai/dsh-superagent-prototype> (MIT, research prototype — not production software).

## Three facts that decide the whole setup

Read these before touching anything. Each one has cost a full debugging session.

1. **The agent needs its own GitHub account.** Never the operator's. Every comment, issue body and pull request the agent's login authors is dropped at intake (`sameName(comment.user.login, login)` in `src/sources/github.ts`, same test in `readNotified` and `author()`), and GitHub does not notify an account of its own activity. One shared account receives zero triggers, no matter what the policy says. → [references/accounts.md](references/accounts.md)
2. **The model route must work from a plain shell, not just from the desktop app.** The shipped profile default is `deepseek-official`, which needs `DEEPSEEK_API_KEY`. A machine signed in through the DeepSeek *account* route uses `deepseek-account` instead. If the route is wrong, every turn fails with `MISSING_CREDENTIAL` and the eval only ends `unavailable` after two 120-second timeouts. → [references/pitfalls.md](references/pitfalls.md)
3. **One deployment watches one repository on github.com.** No GitHub Enterprise, no multi-repo, no cross-repo work. Choose a scratch repository first.

## Runbook

Each step ends in a checkpoint. Stop and fix before continuing; later steps assume earlier ones.

### 0. Probe

```sh
node -v; pnpm -v; git --version; tmux -V; python3 --version; gh --version | head -1; dsh --version
gh api user --jq .login
ls ~/.dsh/profiles
```

Requires Node 22.19+ or 24+, pnpm, git 2.32+, Python 3.8+, tmux, gh 2.48+, and a `dsh` whose version satisfies the prototype's `engines.dsh` (`^0.2.1-alpha.2`; `0.2.1-rc.3` is known good).
A missing prerequisite is a plan item, not a question. `~/.dsh/profiles/superagent` already present means an existing install: read Upgrade in `docs/006-deployment.md` instead of recreating it.

**Checkpoint:** every command answers.

### 1. Install tooling

```sh
brew install tmux                     # or the platform equivalent
npm install -g @deepseek-ai/dsh@0.2.1-rc.3
```

Retry on `ECONNRESET` / `EOF`; a proxied or fake-IP network fails these installs intermittently. See [references/pitfalls.md](references/pitfalls.md).

**Checkpoint:** `tmux -V` and `dsh --version` print versions.

### 2. Checkout and build

```sh
git clone https://github.com/deepseek-ai/dsh-superagent-prototype.git ~/src/dsh-superagent
cd ~/src/dsh-superagent && pnpm install && pnpm check
```

`pnpm check` is typecheck + ~1200 tests + build and takes about a minute. It must pass before you debug anything else.

**Checkpoint:** `pnpm check` exits 0 and `lib/index.js` exists.

### 3. Create the profile

```sh
cd ~/src/dsh-superagent
dsh superagent --from-default-profile web --dump-config > /dev/null
dsh plugin --profile superagent add "link:$PWD"
```

Run the profile-creation command only for a new install: it replaces `~/.dsh/profiles/superagent` and deletes its `cordis.patch.yml`.

**Checkpoint:** `dsh superagent --dump-config | grep -c dsh-superagent` is above zero.

### 4. Machine configuration

Write `~/.dsh/profiles/superagent/cordis.patch.yml`:

```yaml
- id: webserver
  config:
    host: 127.0.0.1
    port: 3082
- id: dsh-superagent
  config:
    stateDir: /absolute/path/to/.dsh/state/superagent
# Only when the machine uses the DeepSeek account route instead of DEEPSEEK_API_KEY:
- id: agent-default-model
  config:
    provider: deepseek-account
    model: deepseek-flash
```

`stateDir` must be absolute and must not be changed later. It holds the SQLite database, the lock, the worker shims, the agent's git configuration and the ticket directories. Back it up before upgrades.

**Checkpoint:** `dsh superagent --dump-config | grep -A3 agent-default-model` shows the values you wrote.

### 5. Agent GitHub account

Create a dedicated account, give it **Write** access to the repository, accept the invitation, then sign in a CLI that uses only its own credentials:

```sh
cat > ~/.local/bin/gh-agent <<'EOF'
#!/bin/sh
GH_CONFIG_DIR="$HOME/.config/gh-agent" exec gh "$@"
EOF
chmod +x ~/.local/bin/gh-agent
~/.local/bin/gh-agent auth login
~/.local/bin/gh-agent api user --jq .login
~/.local/bin/gh-agent api repos/OWNER/REPO --jq .permissions.push
```

`~/.config/gh-agent` must exist afterwards and `push` must be `true`.

If the browser device flow fails with `Post "https://api.github.com/graphql": EOF`, use a personal access token instead — `repo`, `workflow`, `read:org` scopes, then `~/.local/bin/gh-agent auth login --with-token <<< 'ghp_...'`. The token path is retryable without a new authorization round trip.

**Checkpoint:** the wrapper prints the agent login, which differs from `gh api user --jq .login`.

### 6. Start and read the setup problem

```sh
cd ~/src/dsh-superagent
./scripts/dsh-superagent --profile superagent start
```

A fresh install exits **3** with a `setup` object naming the first missing thing (usually `repositoryUnset`). That is the expected first result, not a failure. The panel is already served.

**Checkpoint:** the output has a `url` and a `setup.place`.

### 7. Configure through the management API

```sh
api=http://127.0.0.1:3082/orchestrator/api
curl -s -H 'x-orchestrator-request: 1' $api/state | jq .setup
curl -s -H 'x-orchestrator-request: 1' $api/models | jq '.default, .routableProviders'
```

Save three blocks in this order — source, policy, executor. Each `PUT` needs the current `revision`, and a save that changes a field setup reads returns `restarting: true`. Exact payloads, the model-route check and a small Python client: [references/config.md](references/config.md).

- `source:github` — `repository` as `owner/name`, `cli` as the absolute wrapper path.
- `policy` — `sources.github.allowed` lists the humans who may ask; the agent account does **not** belong there. `bots` stays empty unless a bot should produce candidates. Accept mode starts at `observe`.
- `executor` — `directory` and a `prepare` command that creates one checkout per ticket, plus the worker model.

**Checkpoint:** `GET state` shows `setup: null`, and every health entry is `ready` or `starting`.

### 8. First ticket

From an allowed account, comment on an issue:

```
@agent-login Change "trying" to "testing" in the README sentence. Only that word.
```

An **explicit** mention is admitted in every accept mode and goes straight to a ticket, so the first run does not need `auto`. Within one poll (60s by default) the panel shows the ticket, the agent acknowledges in the thread, a worktree is created, and a pull request appears.

Review the diff, then merge it as a person. The pull request closing ends the ticket as `merged`.

**Checkpoint:** the ticket leaves the overview and `GET state` reports `load.running: 0`.

### 9. Operate

```sh
./scripts/dsh-superagent --profile superagent status    # 0 ok · 1 down/duplicated · 2 a part failed · 3 waits for setup
./scripts/dsh-superagent --profile superagent stop
./scripts/dsh-superagent --profile superagent restart
```

An hourly check from the operator's own profile (not the `superagent` profile) restarts a process that died but leaves an intentional stop alone: the prompt is in `docs/006-deployment.md`. Details, health semantics, upgrade and backup: [references/operations.md](references/operations.md).

## The traps, in symptom order

| Symptom | Cause | Fix |
| --- | --- | --- |
| `received 0` forever, no ticket | agent login equals the requester's | separate agent account |
| `no API key for provider route "deepseek-official"` (`MISSING_CREDENTIAL`) | profile default is the API-key route | set `agent-default-model` to the account route — [pitfalls.md](references/pitfalls.md) |
| model changed in settings but turns still fail | an existing Session persists the last used route | select the model once in that Session |
| `status` exits 2 with `github: N consecutive failed polls` | proxy dropping connections | wait for one successful poll; it self-heals |
| `POST setup/check` returns 400 `Setup is complete` | nothing is missing, but the resolved account is stale | `restart` instead |
| `@agent cannot push to ...` | collaborator invite not accepted, or read-only | accept, grant Write |
| `The prepare command failed` | wrong clone path in the worktree command | fix the command, retry the ticket |

Full diagnosis, evidence and the exact failing call sites: [references/pitfalls.md](references/pitfalls.md).

## What good looks like

- `status` exits 0 with no `errors` and no `setup`.
- The panel's overview reads `待处理工单 0` between tickets and lists only work that needs a person.
- A ticket that ends `merged` or `closed` disappears from the overview; its thread stays subscribed, so a later human comment resumes it under the same mandate without a new assessment.
- `observe` mode records proactive decisions as "would accept" and dispatches nothing. Stay there for weeks before switching to `auto`.

## Safety

Executor Sessions run as the operator's OS user with `danger-full-access`. The `blockedCommands` list is name-based and an absolute path bypasses it. The shipped design recommends a dedicated OS account holding only the agent's credentials; decide this before pointing the agent at anything that matters.
