# Accounts

One deployment needs exactly two GitHub identities, and they must differ.

| Identity | Does | Signs in as |
| --- | --- | --- |
| Operator | asks for work, reviews, merges | the human's own `gh` |
| Agent | comments, pushes branches, opens pull requests, reads its own notifications | `gh-agent`, its own config directory |

## Why the operator's account cannot double as the agent

Three independent places drop content authored by the agent's login, and GitHub never notifies an account of its own activity:

```ts
// src/sources/github.ts, intakeComments — the decisive one
if (sameName(comment.user.login, login)) continue

// src/sources/github.ts, readNotified
const opened = Date.parse(issue.created_at) >= Date.parse(since) && !sameName(issue.user.login, login)

// src/sources/github-trigger.ts, author()
human: isHumanLogin(user) && !sameName(user.login, agent)
```

The first runs before the gate. A message the agent authored never becomes a trigger at all, so no policy, bot list or `observe`-versus-`auto` setting can rescue a single-account install. A smoke test with one account produces `received 0` indefinitely.

A GitHub App cannot replace the agent account either: the agent reads the account's notification stream, which an App installation does not have.

## Create the agent account

1. Register a separate account — a plus-addressed mailbox works, for example `you+agent@example.com`.
2. Grant it **Write** access: repository → Settings → Collaborators → Add people.
3. Accept the invitation while signed in as the agent. An unaccepted invitation authenticates fine but fails the deployment check with `@agent cannot push to owner/name`.
4. Verify:

```sh
~/.local/bin/gh-agent api repos/OWNER/REPO --jq .permissions.push   # true
```

## The wrapper

```sh
cat > ~/.local/bin/gh-agent <<'EOF'
#!/bin/sh
GH_CONFIG_DIR="$HOME/.config/gh-agent" exec gh "$@"
EOF
chmod +x ~/.local/bin/gh-agent
```

`GH_CONFIG_DIR` keeps the agent's token in `~/.config/gh-agent`, away from `~/.config/gh`, and is the same mechanism the deployment uses when it writes its own shims into `<stateDir>/worker-bin`.

Sign in, choosing the agent account in the browser:

```sh
~/.local/bin/gh-agent auth login
~/.local/bin/gh-agent api user --jq .login
```

### When the device flow fails

```
failed to authenticate via web browser: Post "https://api.github.com/graphql": EOF
```

That is a dropped connection at the final exchange, not a wrong password. Either rerun `auth login`, or skip the browser round trip with a token:

1. Signed in as the agent, open <https://github.com/settings/tokens/new>.
2. Scopes `repo`, `workflow`, `read:org`, any expiry.
3. `~/.local/bin/gh-agent auth login --with-token <<< 'ghp_...'`

A token survives a retry; a device code does not.

## Where the agent account is configured

Only the GitHub Source knows it, through `config.cli` — the absolute path to the wrapper. The deployment probes `api user --jq .login` to learn the login and checks push access at the same time. Changing `cli` or `repository` runs setup again and restarts the plugin.

The agent login must **not** appear in `policy.sources.github.allowed`; that list is for people who may ask for work. Listing the agent there is harmless but meaningless.

## Feishu, when used

A Feishu bot is its own identity, so a Feishu-only deployment needs no second GitHub account. The bot CLI is configured the same way — a wrapper over `lark-cli` with its own `LARKSUITE_CLI_CONFIG_DIR` in strict bot mode. See the upstream `docs/006-deployment.md`, Feishu bot section.
