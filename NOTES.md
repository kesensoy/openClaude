## Session: 2026-02-13 — Initial OAuth/Bedrock mixed routing setup

### Context
- User's work machine uses Bedrock API for everything via `claude` command
- User wanted `openclaude` to use Claude plan (Max) OAuth for opus/sonnet and Bedrock for haiku
- Personal machine (Linux) vs work machine (macOS)

### Manual setup of openClaude (skipping install.sh)
- Copied `openClaude` to `~/.local/bin/openClaude` and made executable
- Copied `litellm-config.yaml` to `~/.litellm/config.yaml`
- Installed LiteLLM: `uv tool install 'litellm[proxy]'`
- Skipped AWS profile setup (user already authed as IAM user `foundryvtt`)

### Fixed: macOS sed syntax on Linux
- `sed -i ''` (macOS) fails on Linux — needs `sed -i` (no empty string arg)
- Added OS detection using `$OSTYPE` to handle both platforms

### Fixed: Removed AWS profile requirement for personal machine
- Removed `AWS_PROFILE="$OPENCLAUDE_AWS_PROFILE"` from LiteLLM startup (line 43)
- Removed `awsAuthRefresh` from jq command (no SSO login needed)
- LiteLLM now inherits shell's AWS credentials directly

### Brainstormed OAuth/Bedrock mixed routing design
- Researched whether Claude Code supports per-model endpoint routing (it doesn't — single ANTHROPIC_BASE_URL)
- Researched LiteLLM OAuth token forwarding (broken in official release)
- Found PR #19912 (iamadamreed/litellm@fix/anthropic-oauth-token-forwarding) that fixes OAuth forwarding
- Designed approach: all models through LiteLLM, opus/sonnet → Anthropic API (OAuth), haiku → Bedrock (AWS creds)

### Implemented OAuth/Bedrock mixed routing
- **Installed patched LiteLLM** from PR #19912 branch (version 1.81.4)
- **Updated litellm-config.yaml**: opus/sonnet use `anthropic/` prefix (OAuth), haiku uses `bedrock/converse/` (AWS creds), added `forward_client_headers_to_llm_api: true`
- **Updated openClaude script**: removed dummy `ANTHROPIC_API_KEY="sk-1234"` export, added `del(.ANTHROPIC_API_KEY)` to jq command so Claude Code uses native OAuth
- **Updated README.md**: added OAuth Authentication section with PR #19912 caveat and migration instructions, updated Model Tiers table

### Diagnosed "Request too large (max 20MB)" error (initial)
- Error occurred with both production and patched LiteLLM
- Investigated: NOT caused by projects directory being sent to API
- Root cause: Claude Code's Messages API is stateless — sends full conversation history on every request
- The current session had grown too large (976 messages, 1.9 MB JSONL)
- Solution: start fresh session

### Documents created
- `docs/plans/2026-02-13-oauth-bedrock-mixed-routing-design.md` — design document
- `docs/plans/2026-02-13-oauth-bedrock-mixed-routing.md` — implementation plan

---

## Session: 2026-02-14 — Port collision fix, [1m] removal, Opus model ID fix

### Diagnosed "Request too large (max 20MB)" error
- The error occurred on ALL models when starting openClaude, even with a fresh session and single "test" prompt in a brand new directory
- Root cause: **Port 4000 was occupied by a NestJS/Express campaign-manager app** (PID 2131086), not LiteLLM
- openClaude's health check (`curl localhost:4000/health`) got 200 OK from Express and assumed LiteLLM was running
- Claude Code was sending API requests to the Express app, which rejected them

### Fixed: Killed the Express app on port 4000
- `kill 2131086` freed the port for LiteLLM

### Fixed: Removed all `[1m]` suffixes
- Removed `[1m]` from `.model` in the openClaude script (line 102)
- Simplified the comment about firstParty model names (lines 98-100)
- Copied updated script to `~/.local/bin/openClaude`
- Cleaned `[1m]` from `~/.openClaude/settings.json` (3 occurrences: model, ANTHROPIC_DEFAULT_OPUS_MODEL, ANTHROPIC_DEFAULT_SONNET_MODEL)

### Fixed: Corrected Opus model ID in LiteLLM config
- `anthropic/claude-opus-4-6-20250514` → `anthropic/claude-opus-4-6` (no date suffix for Opus 4.6)
- Updated both `/home/jakekausler/.litellm/config.yaml` and `/storage/programs/openClaude/litellm-config.yaml`
- Restarted LiteLLM with corrected config

### Validated LiteLLM routing
- Confirmed all 3 model names align between settings.json and LiteLLM config
- Sonnet (`claude-sonnet-4-5`) confirmed working through LiteLLM → Anthropic API with OAuth token
- Opus (`claude-opus-4-6`) was failing due to wrong model ID (now fixed)
- Qwen (`qwen-3-coder`) routes to Bedrock but AWS SSO session needs refresh

### Still TODO
- Make openClaude health check more robust (verify it's LiteLLM, not just any HTTP server with `/health`)
- Update CLAUDE.md documentation to remove `[1m]` references
- Refresh AWS SSO session for Qwen/Bedrock route

---

# Session Notes: 2026-02-14

## Objective

Switch the `openclaude` AWS profile from SSO authentication to standard shell auth (IAM access keys) for Bedrock Qwen model access.

## Problem Chain

### 1. SSO Session Not Found

**Issue**: The `openclaude` AWS profile referenced `sso_session = SystemAdministrator` which didn't exist in `~/.aws/config`.

**Fix**: Removed all SSO-related configuration from `[profile openclaude]`:
```ini
[profile openclaude]
region = us-west-2
output = json
```

### 2. Missing Credentials

**Issue**: After removing SSO config, the profile had no credentials.

**Fix**: Configure static credentials using `aws configure --profile openclaude` or create a dedicated IAM user (see IAM Setup below).

### 3. OAuth Header Leak to Bedrock (Critical Issue)

**Issue**: LiteLLM's `/v1/messages` Anthropic passthrough endpoint forwards the Authorization header (containing Claude Code's OAuth token `sk-ant-oat01-*`) to ALL backends, including Bedrock. Bedrock rejected it with:
```
Invalid API Key format: Must start with pre-defined prefix
```

**Attempted Fixes (All Failed)**:
- Removing `forward_client_headers_to_llm_api: true` — passthrough always forwards
- Setting `api_key: ""` on Bedrock model definition — no effect
- Adding explicit `aws_access_key_id`/`aws_secret_access_key` — header still leaked

**Root Cause**: LiteLLM's `/v1/messages` passthrough is designed for Anthropic API compatibility and ALWAYS forwards the Authorization header. No per-model header filtering exists.

**Solution**: Dual LiteLLM proxy architecture (see Architecture section below).

### 4. Missing IAM Permissions

**Issue**: IAM user had `bedrock:InvokeModel` but not `bedrock:InvokeModelWithResponseStream`.

**Fix**: Add both permissions (Claude Code uses streaming).

## Final Architecture

### Dual LiteLLM Proxy Setup

```
Claude Code → Instance 1 (:4000)
                ├─ claude-opus-4-6   → Anthropic API (OAuth passthrough ✓)
                ├─ claude-sonnet-4-5 → Anthropic API (OAuth passthrough ✓)
                └─ qwen-3-coder      → Instance 2 (:4001, via openai/ prefix)
                                         └─ Bedrock Converse (AWS creds only ✓)
```

**Why Two Instances**:
- Instance 1 handles all incoming requests from Claude Code
- Opus/Sonnet route directly to Anthropic API (OAuth token is correct)
- Qwen routes to Instance 2 using `openai/` prefix, which uses the standard completion path and strips the OAuth header
- Instance 2 receives clean requests and routes to Bedrock with AWS credentials only

**Key Insight**: The `openai/` prefix route through Instance 2 is the only way to prevent OAuth header leakage. The `/v1/messages` passthrough endpoint has no per-model header filtering.

## Configuration Files

### litellm-config.yaml (Instance 1, Port 4000)

```yaml
model_list:
  # Anthropic direct (OAuth passthrough)
  - model_name: claude-opus-4-6
    litellm_params:
      model: claude-opus-4-6
      api_base: https://api.anthropic.com/v1
      forward_client_headers_to_llm_api: true

  - model_name: claude-sonnet-4-5
    litellm_params:
      model: claude-sonnet-4-5
      api_base: https://api.anthropic.com/v1
      forward_client_headers_to_llm_api: true

  # Qwen via Instance 2 (strips OAuth header)
  - model_name: qwen-3-coder
    litellm_params:
      model: openai/qwen-3-coder
      api_base: http://localhost:4001

general_settings:
  master_key: sk-1234
```

### litellm-config-bedrock.yaml (Instance 2, Port 4001)

```yaml
model_list:
  - model_name: qwen-3-coder
    litellm_params:
      model: bedrock/converse/qwen.qwen3-next-80b-a3b
      aws_region_name: us-west-2
      aws_profile_name: openclaude

general_settings:
  master_key: sk-5678
```

## IAM Setup Steps

### Creating a Dedicated IAM User

1. **Create IAM User**:
   - AWS Console → IAM → Users → Create user
   - Username: `claude-bedrock` (or similar)
   - Access type: Programmatic access only (no console)

2. **Create IAM Policy** (`BedrockQwenInvoke`):
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

3. **Attach Policy to User**:
   - Attach the `BedrockQwenInvoke` policy directly to the user

4. **Create Access Keys**:
   - Security credentials → Create access key
   - Use case: "Application running outside AWS"
   - Save the access key ID and secret access key

5. **Configure AWS Profile**:
```bash
aws configure --profile openclaude
# Enter:
#   AWS Access Key ID: <from step 4>
#   AWS Secret Access Key: <from step 4>
#   Default region: us-west-2
#   Default output format: json
```

6. **Enable Model Access** (if not already enabled):
   - AWS Console → Bedrock → Model access (in us-west-2 region)
   - Request access to Qwen 3 Next 80B if needed

7. **Test Bedrock Access**:
```bash
aws bedrock-runtime converse \
  --model-id qwen.qwen3-next-80b-a3b \
  --region us-west-2 \
  --profile openclaude \
  --messages '[{"role":"user","content":[{"text":"Say hello"}]}]'
```

## AWS Configuration Files

### ~/.aws/config

```ini
[profile openclaude]
region = us-west-2
output = json
```

**Important**: No SSO configuration should be present.

### ~/.aws/credentials

```ini
[openclaude]
aws_access_key_id = AKIA...
aws_secret_access_key = ...
```

## Starting the Dual Proxy Setup

The `openClaude` script now starts both LiteLLM instances:

```bash
# Instance 1 (main proxy)
litellm --config ~/.litellm/config.yaml --port 4000 --detailed_debug &

# Instance 2 (Bedrock-only proxy)
litellm --config ~/.litellm/config-bedrock.yaml --port 4001 --detailed_debug &
```

Both instances are auto-started by the `openClaude` command and remain running until manually killed.

## Stopping LiteLLM

```bash
pkill -f litellm
```

Or individually:
```bash
pkill -f "litellm.*4000"
pkill -f "litellm.*4001"
```

## Key Learnings

1. **LiteLLM Passthrough Behavior**: The `/v1/messages` endpoint is tightly coupled to Anthropic API and cannot selectively filter headers per backend.

2. **Header Stripping via Proxy Chaining**: Using `openai/` prefix to route through a second LiteLLM instance is the cleanest way to strip unwanted headers.

3. **IAM Permissions for Streaming**: Bedrock streaming requires both `InvokeModel` AND `InvokeModelWithResponseStream` permissions.

4. **AWS Profile Isolation**: Static credentials in `~/.aws/credentials` completely replace SSO, no conflict between the two auth methods for the same profile.

## Testing Checklist

- [ ] Opus requests route to Anthropic API with OAuth token
- [ ] Sonnet requests route to Anthropic API with OAuth token
- [ ] Qwen requests route to Bedrock without OAuth header leak
- [ ] All three models respond successfully in Claude Code
- [ ] Streaming works for all models
- [ ] LiteLLM processes auto-start with `openClaude` command
