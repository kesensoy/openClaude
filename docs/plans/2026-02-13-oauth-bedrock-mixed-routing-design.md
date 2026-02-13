# Mixed OAuth/Bedrock Routing Design

Date: 2026-02-13

## Problem

The current openClaude setup routes all models (opus, sonnet, haiku) through Bedrock using AWS credentials. We want to:
- Use Claude plan OAuth tokens for opus/sonnet (via Anthropic API)
- Keep Bedrock for haiku (using AWS credentials)

This allows using a Claude plan subscription for the main models while using cheaper Bedrock alternatives for fast/haiku tasks.

## Constraints

1. Claude Code does not support per-model endpoint routing - only one ANTHROPIC_BASE_URL for all models
2. Official LiteLLM (as of Feb 2026) has broken OAuth token forwarding for Anthropic
3. Need to maintain both `claude` (all-Bedrock) and `openclaude` (mixed routing) commands

## Solution

Route all models through LiteLLM proxy using a patched version (PR #19912) that supports OAuth token forwarding.

### Architecture

```
Claude Code → LiteLLM Proxy (localhost:4000) → Routes based on model:
                  ├─ claude-opus-4-6 → Anthropic API (OAuth token)
                  ├─ claude-sonnet-4-5 → Anthropic API (OAuth token)
                  └─ qwen-3-coder → Bedrock Converse (AWS creds)
```

### Authentication Flow

1. User runs `openclaude`
2. Claude Code authenticates via web browser (OAuth)
3. Claude Code gets session token (sk-ant-oat01-...)
4. Sends requests to LiteLLM with `Authorization: Bearer <token>` header
5. LiteLLM (with PR #19912 patch):
   - Detects OAuth token
   - Forwards to Anthropic API for opus/sonnet
   - Uses AWS credentials for haiku/Bedrock

## Configuration Changes

### litellm-config.yaml

```yaml
model_list:
  # Tier 1: Main session (opus) - Anthropic API with OAuth
  - model_name: claude-opus-4-6
    litellm_params:
      model: anthropic/claude-opus-4-6-20250514
      # No api_key needed - OAuth token forwarded from Authorization header

  # Tier 2: Subagents (sonnet) - Anthropic API with OAuth
  - model_name: claude-sonnet-4-5
    litellm_params:
      model: anthropic/claude-sonnet-4-5-20250929
      # No api_key needed - OAuth token forwarded from Authorization header

  # Tier 3: Fast subagents (haiku) - Bedrock with AWS creds
  - model_name: qwen-3-coder
    litellm_params:
      model: bedrock/converse/qwen.qwen3-next-80b-a3b
      aws_region_name: us-west-2
      # Uses AWS credentials from shell environment

litellm_settings:
  drop_params: true
  forward_client_headers_to_llm_api: true  # Enable OAuth header forwarding
```

Key changes:
- Opus/sonnet use `anthropic/` prefix (not `bedrock/`)
- No api_key specified for opus/sonnet
- Added `forward_client_headers_to_llm_api: true`
- Haiku unchanged (still Bedrock)

### openClaude Script

Changes to `openClaude` script:

1. **Remove dummy API key export** (line ~121):
   ```bash
   # DELETE THIS LINE:
   export ANTHROPIC_API_KEY="sk-1234"
   ```

2. **Update jq command** (lines 97-108) to NOT set ANTHROPIC_API_KEY:
   ```bash
   jq '
     .model = "claude-opus-4-6[1m]" |
     del(.awsCredentialExport) |
     del(.awsAuthRefresh) |
     .env = (.env |
       del(.CLAUDE_CODE_USE_BEDROCK) |
       del(.ANTHROPIC_API_KEY) |  # Don't override - let OAuth flow work
       .ANTHROPIC_DEFAULT_OPUS_MODEL = "claude-opus-4-6[1m]" |
       .ANTHROPIC_DEFAULT_SONNET_MODEL = "claude-sonnet-4-5[1m]" |
       .ANTHROPIC_SMALL_FAST_MODEL = "qwen-3-coder" |
       .ANTHROPIC_DEFAULT_HAIKU_MODEL = "qwen-3-coder"
     )
   ' "$CLAUDE_DIR/settings.json" > "$OPEN_CLAUDE_DIR/settings.json"
   ```

Rationale: Claude Code must use its native OAuth authentication. Setting ANTHROPIC_API_KEY prevents OAuth tokens from being sent.

## Installation

### Prerequisites

- Existing openClaude setup
- AWS credentials for Bedrock access
- Claude plan subscription (Pro or Max)

### Steps

1. **Install patched LiteLLM with OAuth support:**
   ```bash
   # Uninstall current version
   uv tool uninstall litellm

   # Install from PR #19912 branch
   uv tool install git+https://github.com/iamadamreed/litellm.git@fix/anthropic-oauth-token-forwarding
   ```

   **IMPORTANT CAVEAT:** This uses an unmerged PR branch. When PR #19912 is merged into LiteLLM main, switch back to official release:
   ```bash
   uv tool uninstall litellm
   uv tool install 'litellm[proxy]'
   ```

2. **Update configuration files:**
   - Update `litellm-config.yaml`
   - Update `openClaude` script

3. **Kill running LiteLLM:**
   ```bash
   pkill -f litellm
   ```

4. **Test:**
   ```bash
   openclaude
   # Authenticate via browser
   # LiteLLM auto-starts with new config
   ```

## Testing & Verification

### Test Each Model Tier

1. **Main session (opus):** Should use Anthropic OAuth
2. **Sonnet subagents:** Should use Anthropic OAuth
3. **Haiku subagents:** Should use Bedrock

### Verify Logs

```bash
tail -f /tmp/litellm.log
# Should see opus/sonnet → api.anthropic.com
# Should see haiku → bedrock
```

### Check OAuth Forwarding

- LiteLLM logs should show Authorization headers for opus/sonnet
- No "API key missing" errors for Anthropic models

## Rollback

If issues occur:

```bash
# Reinstall official LiteLLM
uv tool uninstall litellm
uv tool install 'litellm[proxy]'

# Restore original configs
git checkout litellm-config.yaml openClaude

# Kill and restart
pkill -f litellm
openclaude
```

## Future Considerations

### When PR #19912 Merges

Once https://github.com/BerriAI/litellm/pull/19912 is merged:

1. Switch to official LiteLLM release
2. Update README to remove caveat about PR branch
3. Test that OAuth forwarding still works

### If PR #19912 Never Merges

Options:
1. Fork LiteLLM and maintain our own branch
2. Switch all models to Bedrock (lose plan subscription benefit)
3. Use separate tool for opus/sonnet routing

## References

- LiteLLM PR #19912: https://github.com/BerriAI/litellm/pull/19912
- LiteLLM Issue #19618: OAuth tokens not forwarded
- Claude Code documentation: https://code.claude.com/docs
