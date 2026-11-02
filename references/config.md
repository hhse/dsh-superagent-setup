# Configuration

Everything except `stateDir` is configured through the panel or the management API, not by editing files.

## Management API

```sh
api=http://127.0.0.1:3082/orchestrator/api
curl -s -H 'x-orchestrator-request: 1' $api/state
```

The header is required; the host must be `127.0.0.1:<port>` or `localhost:<port>`. Answers: 400 invalid value or fixed refusal, 404 unknown, 409 stale revision, 500 anything else.

A save takes the **whole block** plus its current revision:

```sh
rev=$(curl -s -H 'x-orchestrator-request: 1' $api/settings | jq '.blocks.eval.revision')
curl -s -X PUT -H 'x-orchestrator-request: 1' -H 'content-type: application/json' \
  $api/settings/eval -d "{\"value\": {...}, \"revision\": $rev}"
```

A response of `{"saved": true, "restarting": true}` means the process is restarting: wait until `scripts/dsh-superagent status` stops exiting 1 before the next request, then reread the revisions.

A small client that survives this is easier than shell quoting:

```python
import json, urllib.request

BASE = "http://127.0.0.1:3082/orchestrator/api"

def call(path, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + "/" + path, data=data, method=method)
    req.add_header("x-orchestrator-request", "1")
    if data:
        req.add_header("content-type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return {"__status": e.code, "__body": e.read().decode()[:800]}
```

Read the block, change one key, send it back — never hand-write the whole block:

```python
s = call("settings"); b = s["blocks"]["eval"]
b["value"]["model"] = {"provider": "deepseek-account", "model": "deepseek-flash"}
call("settings/eval", "PUT", {"value": b["value"], "revision": b["revision"]})
```

## The blocks

### `source:github`

```json
{"enabled": true,
 "config": {"repository": "owner/name",
            "cli": "/home/me/.local/bin/gh-agent",
            "pollSeconds": 60,
            "failuresBeforeError": 3,
            "observeIssues": false,
            "observePulls": false,
            "observeComments": false,
            "observeCi": false}}
```

The four `observe*` switches make the Source read every new issue, pull request, comment and default-branch CI result directly instead of only its notifications. Off by default; each one raises the polling cost.

Saving `repository` or `cli` reruns setup and restarts the plugin.

### `policy`

```json
{"rules": [{"id": "copy", "name": "Copy fixes", "enabled": true, "instruction": "..."}],
 "sources": {"github": {"allowed": [{"id": "operator-login"}], "bots": []}}}
```

`allowed` holds people, not the agent. `bots` holds accounts such as `dependabot[bot]` whose messages may become inferred candidates. Rules describe proactive work only; an explicit mention never consults them.

The Policy version hashes rules, accept mode and every Source's policy part. Changing it requeues running Evals and notifies affected live tickets; it does not revoke their mandates.

### `eval`

```json
{"mode": "observe", "timeoutSeconds": 120, "model": {"provider": "deepseek-account", "model": "deepseek-flash"}}
```

`null` means the profile's default model. `observe` records a positive proactive assessment as "would accept" and dispatches nothing; explicit requests are accepted in every mode.

The timeout starts when the candidate reaches the main Session. Two consecutive expiries requeue; the third records `unavailable`.

### `executor`

```json
{"model": {"provider": "deepseek-account", "model": "deepseek-v4-pro"},
 "maxWorkers": 3,
 "directory": "/home/me/src/superagent-work",
 "prepare": "...git worktree command...",
 "blockedCommands": []}
```

One Session and one directory per ticket, named from the ticket. `maxWorkers` limits concurrent tickets; a human message or a status request may use one extra slot so a person is never blocked by the agent's own work.

## The prepare command

It runs once per ticket, in the execution root, with `sh`, before the worker starts, and it receives the execution variables below. A worktree per ticket keeps tickets independent and lets a pull request bind to its branch by name:

```sh
git -C /home/me/src/OWNER-REPO fetch --no-tags \
    "https://github.com/$DSH_SUPERAGENT_GITHUB_REPOSITORY.git" \
    "${DSH_SUPERAGENT_GITHUB_PR_HEAD:-HEAD}:refs/dsh-superagent/$DSH_SUPERAGENT_TICKET" &&
git -C /home/me/src/OWNER-REPO worktree add -b "agent/$DSH_SUPERAGENT_NAME" \
    "$DSH_SUPERAGENT_DIR" "refs/dsh-superagent/$DSH_SUPERAGENT_TICKET"
```

The branch's last path segment must be `$DSH_SUPERAGENT_NAME`, or the Source cannot bind the pull request to the ticket.

A ticket whose prepare command fails records its output and can be retried from the panel.

## Execution variables

| Variable | Value |
| --- | --- |
| `DSH_SUPERAGENT_DIR`, `DSH_SUPERAGENT_NAME`, `DSH_SUPERAGENT_TICKET` | ticket directory, short name, id |
| `DSH_SUPERAGENT_GITHUB_REPOSITORY` | `owner/name` |
| `DSH_SUPERAGENT_GITHUB_ACCOUNT`, `..._COMMIT_EMAIL` | the agent account |
| `DSH_SUPERAGENT_GITHUB_NUMBER`, `..._PR_HEAD` | the issue or pull request that started the ticket |
| `DSH_SUPERAGENT_BLOCKED_COMMANDS` | commands the worker may not run |

No credential ever appears in these values.

## The model route

This is the most common install failure and it never names the real cause.

```sh
curl -s -H 'x-orchestrator-request: 1' http://127.0.0.1:3082/orchestrator/api/models | jq '{default, routableProviders}'
```

`default.provider` is what every turn uses until a Session selects something else. Two situations:

- `default.provider` names the API-key route (for DeepSeek, `deepseek-official`) and `DEEPSEEK_API_KEY` is set in the process environment: fine.
- The machine authenticates through the account route (a signed-in DeepSeek account) and `default.provider` is still the API-key route: every turn dies with

```
llm-deepseek: no API key for provider route "deepseek-official"; store DEEPSEEK_API_KEY
through the credentials service (the web Models page writes it), or export
DEEPSEEK_API_KEY in the launching environment        [MISSING_CREDENTIAL]
```

Fix it at the profile, so new Sessions inherit it:

```yaml
- id: agent-default-model
  config:
    provider: deepseek-account
    model: deepseek-flash
```

and set `eval.model` / `executor.model` explicitly.

**An existing Session ignores the new default.** It persists the route it last used, so the running main Session keeps failing after the profile change and even after a service restart, because Sessions are restored from persistence. Select the model once in that Session's composer; the selection is written as a `model/selection` event and applies to the next turn.

A symptom that looks unrelated: every candidate ends `unavailable` with reason `timeout` after two 120-second expiries. The assessment itself is fine; the turn it steers into cannot start.

## Startup order

1. `source:github` — the repository and the wrapper. Expect `restarting: true`.
2. `policy` — the allowed list. Expect `policy_changed: true`.
3. `executor` — directory, prepare command, worker model.
4. `eval` — mode, timeout, assessment model.

`POST setup/check` reruns the deployment checks, but it refuses with 400 `Setup is complete` when nothing is missing. After changing the agent account or signing a CLI in, use `restart` — the resolved account is captured at start.
