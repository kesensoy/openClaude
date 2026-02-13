# openClaude

Wrapper around Claude Code that routes traffic through a local LiteLLM proxy, letting you swap the haiku model slot for a non-Claude model (default: Qwen 3) while keeping Opus and Sonnet on Claude. Your normal `claude` command is completely unaffected.

## Quick Start

```bash
./install.sh    # copies files, sets up AWS profile
openclaude      # launches Claude Code through LiteLLM
```

## Manual Setup

If you prefer not to use the install script:

1. Install prerequisites: `uv tool install 'litellm[proxy]'` and `brew install jq`
2. Copy `openClaude` to `~/.local/bin/openClaude` and `chmod +x` it
3. Copy `litellm-config.yaml` to `~/.litellm/config.yaml`
4. Set up an AWS profile with Bedrock access (see install script for the format)
5. Run `aws sso login --profile openclaude`, then `openclaude`

## OAuth Authentication (Anthropic Plan)

**IMPORTANT:** openClaude now supports mixed authentication:
- **Opus/Sonnet:** Uses your Claude plan subscription (OAuth via web browser)
- **Haiku:** Uses AWS Bedrock (requires AWS credentials)

This configuration requires a **patched version of LiteLLM** until [PR #19912](https://github.com/BerriAI/litellm/pull/19912) is merged.

### Installation with OAuth Support

```bash
# Install patched LiteLLM (temporary - until PR merges)
uv tool uninstall litellm
uv tool install git+https://github.com/iamadamreed/litellm.git@fix/anthropic-oauth-token-forwarding

# Copy configs
cp openClaude ~/.local/bin/openClaude && chmod +x ~/.local/bin/openClaude
cp litellm-config.yaml ~/.litellm/config.yaml

# Run (will authenticate via browser for Claude plan)
openclaude
```

### When PR #19912 Merges

Once the OAuth fix is merged into official LiteLLM:

```bash
# Switch back to official release
uv tool uninstall litellm
uv tool install 'litellm[proxy]'
```

Update this README to remove the caveat about using the PR branch.

## Model Tiers

| Tier | Claude Code slot | Routed to | Used by |
|------|-----------------|-----------|---------|
| 1 | opus | Claude Opus 4.6 (Anthropic OAuth) | Main session |
| 2 | sonnet | Claude Sonnet 4.5 (Anthropic OAuth) | `Task` tool with `model: "sonnet"` |
| 3 | haiku | Qwen 3 Next 80B (Bedrock Converse) | `Task` tool with `model: "haiku"` |

## Swapping the Haiku Model

Edit `~/.litellm/config.yaml` (or `litellm-config.yaml` in this repo), change the Tier 3 entry:

```yaml
  - model_name: qwen-3-coder
    litellm_params:
      model: bedrock/converse/meta.llama4-scout-17b-16e-instruct-v1:0  # or any Bedrock model
      aws_region_name: us-west-2
```

Then restart LiteLLM: `pkill -f litellm` (next `openclaude` launch auto-starts it).

## Managing LiteLLM

LiteLLM **auto-starts** when you run `openclaude` and **does not auto-stop**. At idle it uses ~300 MB RAM and <0.1% CPU.

```bash
# Check status
curl -s http://localhost:4000/health | python3 -m json.tool

# View logs
tail -f /tmp/litellm.log

# Stop
pkill -f litellm
```

## Configuration

Override defaults via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCLAUDE_AWS_PROFILE` | `openclaude` | AWS profile for LiteLLM's Bedrock calls |
| `OPENCLAUDE_AWS_REGION` | `us-west-2` | AWS region for Bedrock model routing |
| `OPENCLAUDE_LITELLM_PORT` | `4000` | Port for the LiteLLM proxy |

## Prerequisites

- Claude Code (`claude` command)
- `jq`
- `uv` (`brew install uv`)
- LiteLLM (`uv tool install 'litellm[proxy]'`)
- AWS CLI with a profile that has `bedrock:InvokeModel` permission for the configured models

## Uninstall

```bash
rm ~/.local/bin/openClaude
rm -rf ~/.openClaude
rm ~/.litellm/config.yaml
rmdir ~/.litellm 2>/dev/null
pkill -f litellm
```
