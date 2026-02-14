# openClaude

Wrapper around Claude Code that routes traffic through a dual LiteLLM proxy, letting you use your Claude plan (OAuth) for Opus and Sonnet while routing the haiku slot to a non-Claude model on Bedrock (default: Qwen 3). Your normal `claude` command is completely unaffected.

## Quick Start

```bash
./install.sh    # copies files, sets up AWS profile
openclaude      # launches Claude Code through LiteLLM
```

## Manual Setup

If you prefer not to use the install script:

1. Install LiteLLM (see [Patched LiteLLM](#patched-litellm-pr-19912) note below):
   ```bash
   uv tool install git+https://github.com/iamadamreed/litellm.git@fix/anthropic-oauth-token-forwarding
   ```
2. Install `jq` (`brew install jq` on macOS, `apt install jq` on Linux)
3. Copy files:
   ```bash
   cp openClaude ~/.local/bin/openClaude && chmod +x ~/.local/bin/openClaude
   mkdir -p ~/.litellm
   cp litellm-config.yaml ~/.litellm/config.yaml
   cp litellm-config-bedrock.yaml ~/.litellm/config-bedrock.yaml
   ```
4. Set up an AWS profile (`openclaude`) with Bedrock access and IAM credentials (see [IAM Setup](#iam-setup))
5. Run `openclaude`

## Authentication

openClaude uses mixed authentication:
- **Opus/Sonnet:** Your Claude plan subscription (OAuth via web browser, through Anthropic API)
- **Haiku (Qwen):** AWS Bedrock (requires IAM credentials in an AWS profile)

A dual LiteLLM proxy isolates the two auth methods — see [CLAUDE.md](CLAUDE.md) for the architectural details.

### Patched LiteLLM (PR #19912)

OAuth token forwarding from Claude Code to Anthropic API via LiteLLM may require a patched version: [PR #19912](https://github.com/BerriAI/litellm/pull/19912). It is unknown whether the dual-proxy architecture has made this patch unnecessary. Until verified, install the patched version:

```bash
uv tool install git+https://github.com/iamadamreed/litellm.git@fix/anthropic-oauth-token-forwarding
```

Once the PR is merged into official LiteLLM, switch back:
```bash
uv tool uninstall litellm
uv tool install 'litellm[proxy]'
```

### IAM Setup

The Bedrock proxy (Instance 2) needs an AWS profile with credentials. The simplest approach is a dedicated IAM user with static access keys:

1. Create an IAM user (programmatic access only, no console)
2. Attach a policy with `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` for your Bedrock models
3. Create access keys and configure the profile:
   ```bash
   aws configure --profile openclaude
   # AWS Access Key ID: <your key>
   # AWS Secret Access Key: <your secret>
   # Default region: us-west-2
   # Default output format: json
   ```
4. Enable model access in the AWS Console (Bedrock → Model access) if needed

See [CLAUDE.md](CLAUDE.md) for a full IAM policy example.

## Model Tiers

| Tier | Claude Code slot | Routed to | Used by |
|------|-----------------|-----------|---------|
| 1 | opus | Claude Opus 4.6 (Anthropic OAuth) | Main session |
| 2 | sonnet | Claude Sonnet 4.5 (Anthropic OAuth) | `Task` tool with `model: "sonnet"` |
| 3 | haiku | Qwen 3 Next 80B (Bedrock Converse) | `Task` tool with `model: "haiku"` |

## Swapping the Haiku Model

Edit `~/.litellm/config-bedrock.yaml` (or `litellm-config-bedrock.yaml` in this repo), change the model entry:

```yaml
  - model_name: qwen-3-coder
    litellm_params:
      model: bedrock/converse/meta.llama4-scout-17b-16e-instruct-v1:0  # or any Bedrock model
      aws_region_name: us-west-2
      aws_profile_name: openclaude
```

Then restart LiteLLM: `pkill -f litellm` (next `openclaude` launch auto-starts both instances).

Ensure the IAM policy covers the new model's ARN.

## Managing LiteLLM

openClaude runs **two LiteLLM instances** that auto-start and do not auto-stop. At idle each uses ~300 MB RAM and <0.1% CPU.

```bash
# Check status
curl -s http://localhost:4000/health | python3 -m json.tool  # Instance 1 (main)
curl -s http://localhost:4001/health | python3 -m json.tool  # Instance 2 (Bedrock)

# View logs
tail -f /tmp/litellm.log          # Instance 1
tail -f /tmp/litellm-bedrock.log  # Instance 2

# Stop all
pkill -f litellm
```

## Configuration

Override defaults via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCLAUDE_AWS_PROFILE` | `openclaude` | AWS profile for Bedrock calls (Instance 2) |
| `OPENCLAUDE_AWS_REGION` | `us-west-2` | AWS region for Bedrock model routing |
| `OPENCLAUDE_LITELLM_PORT` | `4000` | Port for Instance 1 (Instance 2 uses port + 1) |

## Prerequisites

- Claude Code (`claude` command)
- `jq`
- `uv` (`brew install uv` on macOS)
- LiteLLM (see [Patched LiteLLM](#patched-litellm-pr-19912))
- AWS CLI with a profile that has `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` permissions

## Uninstall

```bash
rm ~/.local/bin/openClaude
rm -rf ~/.openClaude
rm ~/.litellm/config.yaml
rm ~/.litellm/config-bedrock.yaml
rmdir ~/.litellm 2>/dev/null
pkill -f litellm
uv tool uninstall litellm
```
