# Operations

## Where things live

| Path | Holds |
| --- | --- |
| `~/src/dsh-superagent` | the checkout; `scripts/dsh-superagent` is the service script |
| `~/.dsh/profiles/superagent/cordis.patch.yml` | machine configuration: `stateDir`, port, model route |
| `<stateDir>/orchestrator.sqlite` | the whole domain: triggers, threads, decisions, tickets, effects, outbox |
| `<stateDir>/worker-bin` | command shims (`gh`, `lark-cli`, blocked commands) that setup rewrites |
| `<stateDir>/worker-gitconfig` | the git configuration workers get instead of yours |
| `<stateDir>/work` | ticket directories, unless the executor sets another root |
| `<stateDir>/..` | the lock file guarding one process per state directory |
| `~/src/dsh-superagent/.artifacts/` | start logs and control files, newest 20 kept |
| `~/.dsh/sessions/<scope>/` | DSH Sessions, including the main Session |

A file in `worker-bin` or `worker-gitconfig` that the deployment did not write stops setup. Do not put anything else there.

## Commands

```sh
cd ~/src/dsh-superagent
./scripts/dsh-superagent --profile superagent start
./scripts/dsh-superagent --profile superagent status
./scripts/dsh-superagent --profile superagent stop
./scripts/dsh-superagent --profile superagent restart
```

`start` waits up to a minute for the runtime to become ready and prints the setup problem on a first run. `stop` and `restart` wait up to five minutes for executors and never force-kill. `--profile` and `--url` (or `DSH_SUPERAGENT_PROFILE`, `DSH_SUPERAGENT_URL`) point the script at another instance.

`--respect-stop` on `start` or `restart` keeps an intentional stop.

## Health entries

`status` and `GET state` report one entry per part. `ready` is the normal state; `starting` counts as normal for a Source; `paused` is normal while setup is pending or processing is paused.

| Entry | Reports |
| --- | --- |
| `runtime` | the application itself |
| `models` | Sessions waiting on a model-budget retry |
| `evals` | unavailable Evaluations from the last hour with no later judgement |
| `assessment`, `launch`, `delivery`, `relay`, `notice`, `reply` | stored work per kind |
| `worker` | Executor Session event handling, after its first failure |
| `github`, `feishu`, `history` | Source polling, events, history recovery |
| `sync:<source id>` | allowed-list synchronisation |

A part clears its own entry on its next success. Only three consecutive failures raise an error for a queue kind, so one bad poll is invisible by design.

## Pause processing

```sh
curl -s -X POST -H 'x-orchestrator-request: 1' -H 'content-type: application/json' \
  http://127.0.0.1:3082/orchestrator/api/executor/pause -d '{"paused": true}'
```

Stops dispatch, new Evaluations, timeouts, input delivery and replies. Sources keep recording, a running turn finishes, and a person's message to an ended ticket waits for the resume. Useful before a migration or an upgrade.

## The hourly check

Create it in the profile the operator uses every day, not in `superagent`, so it survives the service being down. Prompt for that profile's scheduling tool, with the checkout path filled in:

```text
Check dsh-superagent: run `scripts/dsh-superagent --profile superagent status` in <checkout>.
Exit 0: do nothing and say nothing.
Exit 2: do not restart; tell me each part under `errors` with its detail, unless you already told me about the same ones.
Exit 3: do not restart; tell me what `setup` says setup needs, unless you already told me.
If it reports manually_stopped: true, leave it stopped.
Otherwise (exit 1) run `scripts/dsh-superagent --profile superagent --respect-stop restart`, which exits the same way:
0 means it recovered, so say nothing; 2 and 3 are reported as above; if it exits 1 or fails otherwise, read the newest
.artifacts/dsh-superagent-superagent-*.log and the Troubleshooting section of docs/006-deployment.md, fix what you can,
and tell me what was wrong and what you did.
```

## Backup and upgrade

1. Wait until no executor is mid-turn (`load.running: 0`).
2. Back up `<stateDir>/orchestrator.sqlite` — it is the whole domain.
3. `git pull && pnpm install && pnpm build`.
4. `./scripts/dsh-superagent --profile superagent restart`, then `status`.

A restart ends running assignments and starts replacements with a recovery note telling the worker to check its directory, git history and GitHub before repeating an outside action.

`SCHEMA_VERSION` only increases: a database opened by a newer build cannot be opened by an older one, so rollback needs the backup. Team prompt text survives an upgrade; parts without overrides follow the new defaults, and the panel marks changed defaults.

The worker and router presets (`dsh-superagent-worker`, `dsh-superagent-router`) must stay in `cordis.patch.yml`. A Session cannot load without its preset and resume fails with `agent-preset/not-found`.

## Changing machines

The checkout path, `stateDir` and the two CLI wrappers are the only machine-specific facts.

1. Copy the checkout and `<stateDir>`.
2. Recreate the wrapper paths and sign both CLIs in on the new machine.
3. Update `stateDir` in `cordis.patch.yml` if the absolute path changed — this is the one setting that cannot be changed from the panel.
4. Start, then verify `status` exits 0 and the panel lists the same open tickets.

## Reading the panel

`http://127.0.0.1:<port>/?token=...` — the token is printed in the start log and in the `dsh web:` line. The **Superagent** entry in the sidebar opens the panel; **打开主 Session** opens the Session that evaluates candidates, which is where to look when a candidate seems to stall.

Tabs map to the domain: 概览 (what needs a person), 来源 (Sources and their intake), 触发 (Threads by state), 评估 (Decisions and their reasons), 执行 (tickets, stages, worker load), 设置 (everything configurable).

Every "no" the agent said has a recorded reason under 评估. That is the fastest way to tune the rules: read what it declined for a week before switching `observe` to `auto`.
