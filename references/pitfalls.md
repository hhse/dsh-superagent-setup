# Pitfalls

Every entry is a failure observed during a real install, with the evidence that identifies it.

## 1. A proxied or fake-IP network breaks every GitHub step

Symptom cluster, all transient, all with the same shape:

```
npm error errno ECONNRESET
failed to authenticate via web browser: Post "https://api.github.com/graphql": EOF
@agent cannot read owner/name.  Get "https://api.github.com/repos/...": EOF
could not find pull request diff: Get ".../pulls/2": unexpected EOF
github: 5 consecutive failed polls; last: Error: ... EOF
```

Diagnosis:

```sh
nslookup github.com      # an answer inside 198.18.0.0/15 or 10.0.0.0/8 means a local proxy owns the name
gh api user --jq .login  # if this works, the network is fine right now
```

A benchmark-range address such as `198.18.1.33` is a proxy's fake IP. The connection is fine most of the time and drops without warning, which is why the same command succeeds on retry.

Handling:

- Retry installs and `gh` calls; retry the device flow, or switch to a personal access token, which does not need a new authorization round trip.
- A failed deployment check right after saving the repository usually clears on `POST setup/check` or `restart`.
- Accept that a long-running Source will occasionally log `error` and clear itself on the next successful poll. `status` exits 2 meanwhile; that is the designed behaviour for a failing part, not a broken install.
- For an instance meant to stay up, give `api.github.com` a direct route or use a stable proxy node.

## 2. The model route is inherited from the profile, not from the desktop app

See [config.md](config.md#the-model-route). Short version: the shipped default is the API-key route; a machine signed in through the account route fails every turn with `MISSING_CREDENTIAL`, and the only visible symptom in the panel is candidates that end `unavailable` with reason `timeout`.

Two follow-on traps:

- **A restart does not fix an existing Session.** It persists its last used route. Select the model once in that Session's composer.
- **Deleting `master-id` does not create a fresh Session either.** The Session is restored from `~/.dsh/sessions/<profile-scope>/<session-id>`, and `Sessions.ensure` finds it again. Changing the route means changing the selection, not the identity.

## 3. One GitHub account cannot be both operator and agent

See [accounts.md](accounts.md). The observable symptom is `received 0` with `filtered 0` for as long as you are willing to wait; the cause is a `continue` before the gate.

Checklist when nothing arrives:

```sh
~/.local/bin/gh-agent api user --jq .login    # differs from the operator's login?
./scripts/dsh-superagent --profile superagent status | jq .errors
curl -s -H 'x-orchestrator-request: 1' http://127.0.0.1:3082/orchestrator/api/sources | jq '.[].stats'
```

Then, in order: is the Source `ready`; is `received` above zero; is the requester on `policy.sources.github.allowed`; did the message actually address the agent (a mention must be in a **comment** — editing an issue body does not produce a notification, and the mention must match the agent login exactly).

## 4. `setup/check` refuses when nothing is missing

```
{"error":"Setup is complete","code":"setupComplete"}   # HTTP 400
```

That is correct behaviour: there is no setup problem to fix. After signing a CLI in or changing the agent account, the resolved deployment is stale, so use `restart`.

## 5. A missing `tmux` only fails at start

Everything installs fine, `scripts/dsh-superagent start` then fails or leaves no service. `tmux -V` must answer; the service script runs `dsh --profile <name>` inside the session `dsh-superagent` (or `dsh-<profile>`).

## 6. The bundle needs a dsh inside its `engines` range

`engines.dsh` is `^0.2.1-alpha.2`. `0.2.1-rc.3` is verified; newer 0.2.x releases satisfy the range but the client panel is built against the alpha-era client packages, so verify the panel renders after changing versions. A mismatch shows up as the DeepSeek Harness log naming an incompatible plugin, or a panel that says it failed to load plugins.

## 7. `status` exit codes are the fastest diagnosis

| Exit | Meaning | Restart helps? |
| --- | --- | --- |
| 0 | normal | — |
| 1 | not running, running twice, not answering, or the runtime itself errored | usually |
| 2 | a part such as a Source or a Policy sync reports an error | no, fix the part |
| 3 | runs but waits for setup; `setup` says what is missing | no |

An intentional `stop` pauses automatic recovery; `start` clears it, `restart` does not write the marker, so an hourly check can recover a restart that timed out.

## 8. Nothing deletes old records

The `trigger`, `disposition`, `decision` and `outbox` tables and ended tickets grow without bound, as do saved settings revisions and prompt versions in `kv`. Nothing breaks in a prototype-sized deployment; watch the database size in a long-running one.
