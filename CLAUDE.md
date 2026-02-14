# openClaude — Implementation Details

## Problem

Claude Code only supports 3 model alias slots (opus, sonnet, haiku). We wanted the haiku slot to use Qwen on Bedrock while the main session and sonnet subagents stay on Claude via Anthropic's API (OAuth).

## Solution

A dual LiteLLM proxy sits between Claude Code and the backends. Claude Code sends all requests in Anthropic Messages format. Instance 1 routes them based on model name — Anthropic API for Claude models, Instance 2 for Bedrock models:

```
Claude Code → LiteLLM Instance 1 (:4000)
                ├─ claude-opus-4-6   → Anthropic API (OAuth passthrough)
                ├─ claude-sonnet-4-5 → Anthropic API (OAuth passthrough)
                └─ qwen-3-coder      → LiteLLM Instance 2 (:4001, via openai/ prefix)
                                         └─ Bedrock Converse (AWS creds only)
```

Only the `openClaude` command uses this flow. The normal `claude` command is unaffected.

### Why Two LiteLLM Instances

LiteLLM's `/v1/messages` passthrough endpoint (used for Anthropic API compatibility) **always forwards the Authorization header** to all backends. There is no per-model header filtering. When Claude Code authenticates with OAuth (`sk-ant-oat01-*` token), that token gets forwarded to every backend — including Bedrock, which rejects it:

```
Invalid API Key format: Must start with pre-defined prefix
```

The dual-proxy solves this:
- **Instance 1** receives all requests from Claude Code. Opus/Sonnet route directly to Anthropic API where the OAuth token is valid.
- **Qwen routes to Instance 2** using the `openai/` prefix, which goes through LiteLLM's standard completion path (not the `/v1/messages` passthrough), stripping the OAuth header.
- **Instance 2** receives clean requests and routes to Bedrock using only AWS credentials.

### Patched LiteLLM (PR #19912)

OAuth token forwarding from Claude Code to Anthropic API via LiteLLM required a patch: [PR #19912](https://github.com/BerriAI/litellm/pull/19912) (`iamadamreed/litellm@fix/anthropic-oauth-token-forwarding`). It is unknown whether the dual-proxy architecture has made this patch unnecessary. Until verified, install the patched version:

```bash
uv tool install git+https://github.com/iamadamreed/litellm.git@fix/anthropic-oauth-token-forwarding
```

## How openClaude Works

1. **Starts dual LiteLLM proxies** — kills stale processes if either instance is unhealthy, then starts Instance 2 (Bedrock, port 4001) and Instance 1 (main, port 4000) with health check polling
2. **Builds `~/.openClaude/` config dir** — symlinks everything from `~/.claude/` (history, projects, plugins) except `settings.json`, then generates a derived `settings.json` using `jq` that:
   - Removes `CLAUDE_CODE_USE_BEDROCK` (switches to Anthropic Messages format)
   - Removes `ANTHROPIC_API_KEY` (so Claude Code uses native OAuth)
   - Removes `awsCredentialExport` and `awsAuthRefresh`
   - Uses firstParty model names (`claude-opus-4-6`, `claude-sonnet-4-5`)
   - Maps the haiku slot to `qwen-3-coder`
3. **Sets env vars** — `CLAUDE_CONFIG_DIR`, `ANTHROPIC_BASE_URL`
4. **Execs `claude`** with all arguments passed through

### Why CLAUDE_CONFIG_DIR

Claude Code applies `settings.json` `env` values *after* the shell environment, so shell exports can't override them. `CLAUDE_CONFIG_DIR` points Claude Code at a different settings.json entirely, avoiding the conflict.

### Why firstParty Model Names

Claude Code expects model names like `claude-opus-4-6` when not in Bedrock mode. LiteLLM matches these against `model_name` in its config and routes to the appropriate backend. Bedrock model IDs (like `us.anthropic.claude-opus-4-6-v1`) are only used inside LiteLLM's routing config, never exposed to Claude Code.

### Model ID Flow

Opus/Sonnet (Anthropic API):
```
Claude Code settings:  claude-opus-4-6
                          ↓
Sent to LiteLLM:       claude-opus-4-6
                          ↓ (matches model_name, routes via anthropic/ prefix)
Sent to Anthropic API: claude-opus-4-6
```

Qwen (Bedrock via Instance 2):
```
Claude Code settings:  qwen-3-coder
                          ↓
Sent to Instance 1:    qwen-3-coder
                          ↓ (matches model_name, routes via openai/ prefix to localhost:4001)
Sent to Instance 2:    qwen-3-coder
                          ↓ (matches model_name, routes via bedrock/converse/ prefix)
Sent to Bedrock:       qwen.qwen3-next-80b-a3b
```

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCLAUDE_AWS_PROFILE` | `openclaude` | AWS profile for Instance 2's Bedrock calls |
| `OPENCLAUDE_AWS_REGION` | `us-west-2` | AWS region for Bedrock model routing |
| `OPENCLAUDE_LITELLM_PORT` | `4000` | Port for Instance 1 (Instance 2 uses port + 1) |

### LiteLLM Prefixes

- `anthropic/` — Routes to Anthropic API (used for opus/sonnet in Instance 1)
- `openai/` — Routes through standard completion path, stripping passthrough headers (used for qwen in Instance 1 → Instance 2)
- `bedrock/converse/` — Forces Bedrock Converse API (used for non-Claude models like Qwen in Instance 2)

### LiteLLM Health Check Quirk

LiteLLM's `/health` endpoint reports Qwen as "unhealthy" on Instance 2 because it strips the `bedrock/` prefix during health checks, leaving `converse/qwen...` which it can't parse. Actual routing works fine.

### LiteLLM Lifecycle

Both instances auto-start with `openClaude` and do not auto-stop. Idle usage per instance: ~300 MB RAM, <0.1% CPU.

```bash
# View logs
tail -f /tmp/litellm.log          # Instance 1 (main)
tail -f /tmp/litellm-bedrock.log  # Instance 2 (Bedrock)

# Stop all
pkill -f litellm

# Stop individually
pkill -f "litellm.*4000"
pkill -f "litellm.*4001"
```

## IAM Permissions

Only Bedrock-routed models (Qwen) require AWS IAM permissions. Claude models go through Anthropic API with OAuth.

The AWS profile needs both permissions (Claude Code uses streaming):
- `bedrock:InvokeModel`
- `bedrock:InvokeModelWithResponseStream`

Example minimal IAM policy:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": "arn:aws:bedrock:us-west-2::foundation-model/qwen.qwen3-next-80b-a3b"
    }
  ]
}
```

To use additional Bedrock models, add their ARNs to the Resource list (or use `*` for all foundation models).

## Rollback

Normal `claude` is never modified. To fully remove:

```bash
rm ~/.local/bin/openClaude
rm -rf ~/.openClaude
rm ~/.litellm/config.yaml
rm ~/.litellm/config-bedrock.yaml
rmdir ~/.litellm 2>/dev/null
pkill -f litellm
uv tool uninstall litellm
```
