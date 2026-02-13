# openClaude — Implementation Details

## Problem

Claude Code only supports 3 model alias slots (opus, sonnet, haiku) and routes all requests through Bedrock Invoke API. We wanted the haiku slot to use Qwen on Bedrock while the main session and sonnet subagents stay on Claude.

## Solution

LiteLLM proxy sits between Claude Code and Bedrock. Claude Code sends all requests in Anthropic Messages format. LiteLLM routes them based on model name:

```
Claude Code  -->  LiteLLM (localhost:4000)  -->  Bedrock
                    |
                    +-- claude-opus-4-6    --> Bedrock Invoke  --> Claude Opus 4.6
                    +-- claude-sonnet-4-5  --> Bedrock Invoke  --> Claude Sonnet 4.5
                    +-- qwen-3-coder       --> Bedrock Converse --> Qwen 3 Next 80B
```

Only the `openClaude` command uses this flow. The normal `claude` command is unaffected.

## How openClaude Works

1. **Cleans up stale LiteLLM** — kills orphaned litellm processes, starts fresh if needed
2. **Builds `~/.openClaude/` config dir** — symlinks everything from `~/.claude/` (history, projects, plugins) except `settings.json`, then generates a derived `settings.json` using `jq` that:
   - Removes `CLAUDE_CODE_USE_BEDROCK` (switches to Anthropic Messages format)
   - Uses firstParty model names with `[1m]` suffix for 1M context window
   - Maps the haiku slot to `qwen-3-coder`
   - Replaces `awsCredentialExport` with `awsAuthRefresh` for SSO
3. **Sets env vars** — `CLAUDE_CONFIG_DIR`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`
4. **Execs `claude`** with all arguments passed through

### Why CLAUDE_CONFIG_DIR

Claude Code applies `settings.json` `env` values *after* the shell environment, so shell exports can't override them. `CLAUDE_CONFIG_DIR` points Claude Code at a different settings.json entirely, avoiding the conflict.

### Why firstParty Model Names

Claude Code's `[1m]` context window detection checks for patterns like `claude-opus-4-6[1m]`. Bedrock model IDs like `us.anthropic.claude-opus-4-6-v1[1m]` don't match because `-v1` sits between the model name and `[1m]`. Using firstParty names (`claude-opus-4-6[1m]`) makes the detection work in non-Bedrock mode.

### Model ID Flow

```
Claude Code settings:  claude-opus-4-6[1m]
                          ↓ (strips [1m], keeps for context config)
Sent to LiteLLM:      claude-opus-4-6
                          ↓ (matches model_name in config)
Sent to Bedrock:       us.anthropic.claude-opus-4-6-v1
```

The `[1m]` never reaches Bedrock — it's a Claude Code client-side flag. The actual Bedrock model natively supports 1M tokens.

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCLAUDE_AWS_PROFILE` | `openclaude` | AWS profile for LiteLLM's Bedrock calls |
| `OPENCLAUDE_AWS_REGION` | `us-west-2` | AWS region for Bedrock model routing |
| `OPENCLAUDE_LITELLM_PORT` | `4000` | Port for the LiteLLM proxy |

### LiteLLM Prefixes

- `bedrock/` — Routes through Bedrock Invoke API (for Claude models)
- `bedrock/converse/` — Forces Bedrock Converse API (required for non-Claude models like Qwen)

### LiteLLM Health Check Quirk

LiteLLM's `/health` endpoint reports Qwen as "unhealthy" because it strips the `bedrock/` prefix during health checks, leaving `converse/qwen...` which it can't parse. Actual routing works fine.

### LiteLLM Lifecycle

Auto-starts with `openClaude`, never auto-stops. Idle usage on Apple Silicon: ~300 MB RAM, <0.1% CPU. Kill with `pkill -f litellm` when done.

## IAM Permissions

The AWS role needs `bedrock:InvokeModel` for all models in the LiteLLM config. Claude models are typically already permitted; non-Claude models (Qwen, Llama, etc.) may need to be added.

## Rollback

Normal `claude` is never modified. To fully remove:

```bash
rm ~/.local/bin/openClaude
rm -rf ~/.openClaude
rm ~/.litellm/config.yaml
rmdir ~/.litellm 2>/dev/null
pkill -f litellm
uv tool uninstall litellm
```
