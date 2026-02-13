# OAuth/Bedrock Mixed Routing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable openClaude to route opus/sonnet through Anthropic API using Claude plan OAuth tokens, while keeping haiku on Bedrock with AWS credentials.

**Architecture:** Replace official LiteLLM with patched version (PR #19912) that supports OAuth token forwarding. Update LiteLLM config to route opus/sonnet to `anthropic/` provider (OAuth) and haiku to `bedrock/converse/` (AWS creds). Modify openClaude script to stop overriding ANTHROPIC_API_KEY so Claude Code's native OAuth flow works.

**Tech Stack:** LiteLLM proxy, Claude Code, Anthropic Messages API, AWS Bedrock, bash, jq

---

## Task 1: Install Patched LiteLLM

**Files:**
- None (package installation only)

**Step 1: Uninstall current LiteLLM**

Run:
```bash
uv tool uninstall litellm
```

Expected: `Uninstalled litellm`

**Step 2: Install patched LiteLLM from PR #19912**

Run:
```bash
uv tool install git+https://github.com/iamadamreed/litellm.git@fix/anthropic-oauth-token-forwarding
```

Expected: Installation success, `litellm` and `litellm-proxy` executables installed

**Step 3: Verify installation**

Run:
```bash
litellm --version
```

Expected: Version output (likely 1.x.x from fork)

**Step 4: Kill any running LiteLLM processes**

Run:
```bash
pkill -f litellm
```

Expected: Process killed or "no matching processes found"

---

## Task 2: Update LiteLLM Configuration

**Files:**
- Modify: `litellm-config.yaml`

**Step 1: Backup current config**

Run:
```bash
cp litellm-config.yaml litellm-config.yaml.backup
```

Expected: Backup file created

**Step 2: Update config to route opus/sonnet to Anthropic**

Replace entire `litellm-config.yaml` with:

```yaml
# LiteLLM routing config for openClaude - OAuth/Bedrock mixed mode
#
# Claude Code sends firstParty model names (e.g. "claude-opus-4-6").
# LiteLLM matches model_name and routes to the appropriate provider.
#
# OAuth tokens (sk-ant-oat01-*) are forwarded from Authorization headers
# to Anthropic API for opus/sonnet. AWS credentials from shell are used
# for Bedrock Converse requests for haiku.

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

**Step 3: Verify config syntax**

Run:
```bash
cat litellm-config.yaml | python3 -m yaml
```

Expected: Valid YAML (Python parses without error)

If `yaml` module not available, just verify file was written:
```bash
cat litellm-config.yaml
```

**Step 4: Copy to ~/.litellm/**

Run:
```bash
cp litellm-config.yaml ~/.litellm/config.yaml
```

Expected: File copied

**Step 5: Commit config changes**

Run:
```bash
git add litellm-config.yaml
git commit -m "feat: route opus/sonnet to Anthropic OAuth, haiku to Bedrock

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

Expected: Commit created

---

## Task 3: Update openClaude Script - Remove API Key Override

**Files:**
- Modify: `openClaude`

**Step 1: Remove dummy ANTHROPIC_API_KEY export**

Find line ~121:
```bash
export ANTHROPIC_API_KEY="sk-1234"
```

Delete this line entirely.

**Step 2: Verify removal**

Run:
```bash
grep -n "ANTHROPIC_API_KEY" openClaude
```

Expected: Should NOT find export statement around line 121 (may find references in jq command, that's OK)

**Step 3: Test script syntax**

Run:
```bash
bash -n openClaude
```

Expected: No output (syntax valid)

---

## Task 4: Update openClaude Script - Fix jq Command

**Files:**
- Modify: `openClaude` (lines ~97-108)

**Step 1: Update jq command to delete ANTHROPIC_API_KEY**

Find the jq command (lines 97-108). Replace it with:

```bash
jq '
  .model = "claude-opus-4-6[1m]" |
  del(.awsCredentialExport) |
  del(.awsAuthRefresh) |
  .env = (.env |
    del(.CLAUDE_CODE_USE_BEDROCK) |
    del(.ANTHROPIC_API_KEY) |
    .ANTHROPIC_DEFAULT_OPUS_MODEL = "claude-opus-4-6[1m]" |
    .ANTHROPIC_DEFAULT_SONNET_MODEL = "claude-sonnet-4-5[1m]" |
    .ANTHROPIC_SMALL_FAST_MODEL = "qwen-3-coder" |
    .ANTHROPIC_DEFAULT_HAIKU_MODEL = "qwen-3-coder"
  )
' "$CLAUDE_DIR/settings.json" > "$OPEN_CLAUDE_DIR/settings.json"
```

Key change: Added `del(.ANTHROPIC_API_KEY) |` to ensure OAuth tokens are used.

**Step 2: Verify jq syntax**

Run:
```bash
echo '{"model":"test","env":{"ANTHROPIC_API_KEY":"sk-test"}}' | jq '
  .model = "claude-opus-4-6[1m]" |
  del(.awsCredentialExport) |
  del(.awsAuthRefresh) |
  .env = (.env |
    del(.CLAUDE_CODE_USE_BEDROCK) |
    del(.ANTHROPIC_API_KEY) |
    .ANTHROPIC_DEFAULT_OPUS_MODEL = "claude-opus-4-6[1m]" |
    .ANTHROPIC_DEFAULT_SONNET_MODEL = "claude-sonnet-4-5[1m]" |
    .ANTHROPIC_SMALL_FAST_MODEL = "qwen-3-coder" |
    .ANTHROPIC_DEFAULT_HAIKU_MODEL = "qwen-3-coder"
  )
'
```

Expected: Valid JSON output with no ANTHROPIC_API_KEY in env

**Step 3: Test entire script syntax**

Run:
```bash
bash -n openClaude
```

Expected: No output (syntax valid)

**Step 4: Copy to installation directory**

Run:
```bash
cp openClaude ~/.local/bin/openClaude && chmod +x ~/.local/bin/openClaude
```

Expected: File copied and executable

**Step 5: Commit script changes**

Run:
```bash
git add openClaude
git commit -m "feat: enable OAuth token passthrough for opus/sonnet

Remove ANTHROPIC_API_KEY override to let Claude Code use native OAuth.
Delete API key from settings.json so Authorization headers are sent.

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

Expected: Commit created

---

## Task 5: Update README with OAuth Instructions

**Files:**
- Modify: `README.md`

**Step 1: Add OAuth caveat section**

After the "Manual Setup" section (after line 21), add:

```markdown
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

```

**Step 2: Update Model Tiers table**

Replace the Model Tiers table (line 24-28) with:

```markdown
## Model Tiers

| Tier | Claude Code slot | Routed to | Used by |
|------|-----------------|-----------|---------|
| 1 | opus | Claude Opus 4.6 (Anthropic OAuth) | Main session |
| 2 | sonnet | Claude Sonnet 4.5 (Anthropic OAuth) | `Task` tool with `model: "sonnet"` |
| 3 | haiku | Qwen 3 Next 80B (Bedrock Converse) | `Task` tool with `model: "haiku"` |
```

**Step 3: Verify markdown formatting**

View the file to ensure formatting looks correct:
```bash
head -n 60 README.md
```

Expected: Well-formatted sections with OAuth caveat clearly visible

**Step 4: Commit README updates**

Run:
```bash
git add README.md
git commit -m "docs: add OAuth authentication setup and PR caveat

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

Expected: Commit created

---

## Task 6: Test OAuth Flow

**Files:**
- None (manual testing)

**Step 1: Ensure AWS credentials are available**

Run:
```bash
aws sts get-caller-identity
```

Expected: Valid AWS identity output (for Bedrock haiku routing)

**Step 2: Kill any running LiteLLM**

Run:
```bash
pkill -f litellm
```

Expected: Process killed or "no matching processes found"

**Step 3: Remove existing openClaude config**

Run:
```bash
rm -rf ~/.openClaude
```

Expected: Directory removed (will be regenerated)

**Step 4: Launch openClaude**

Run:
```bash
openclaude
```

Expected:
- "Starting LiteLLM proxy on port 4000..."
- "LiteLLM ready."
- Browser opens for Claude OAuth login
- Claude Code starts after successful login

**Step 5: Verify LiteLLM routing in logs**

In another terminal:
```bash
tail -f /tmp/litellm.log
```

Expected: Log entries showing LiteLLM starting with config from `~/.litellm/config.yaml`

**Step 6: Test opus routing**

In Claude Code session, send a simple prompt:
```
Hello, what model are you?
```

Expected:
- Response from Claude Opus
- LiteLLM logs show request to `api.anthropic.com` with `anthropic/claude-opus-4-6-20250514`
- No "API key missing" errors

**Step 7: Test sonnet subagent routing**

In Claude Code, trigger a subagent task (or check logs when subagents spawn).

Expected:
- LiteLLM logs show requests to `api.anthropic.com` for sonnet
- No authentication errors

**Step 8: Test haiku/Bedrock routing**

In Claude Code, test a fast model task (haiku slot).

Expected:
- LiteLLM logs show requests to Bedrock Converse
- Uses AWS credentials from shell
- No authentication errors

---

## Task 7: Document Testing Results

**Files:**
- Create: `docs/plans/2026-02-13-oauth-testing-results.md`

**Step 1: Create testing results document**

Write:
```markdown
# OAuth/Bedrock Mixed Routing - Testing Results

Date: 2026-02-13

## Test Environment

- LiteLLM version: [output from `litellm --version`]
- LiteLLM source: PR #19912 branch (iamadamreed/litellm@fix/anthropic-oauth-token-forwarding)
- AWS credentials: [yes/no]
- Claude plan: [Pro/Max]

## Test Results

### Opus (Anthropic OAuth)

- **Status:** [PASS/FAIL]
- **Evidence:** [Paste relevant log snippets showing api.anthropic.com requests]
- **Errors:** [None or describe errors]

### Sonnet (Anthropic OAuth)

- **Status:** [PASS/FAIL]
- **Evidence:** [Paste relevant log snippets]
- **Errors:** [None or describe errors]

### Haiku/Qwen (Bedrock)

- **Status:** [PASS/FAIL]
- **Evidence:** [Paste relevant log snippets showing Bedrock requests]
- **Errors:** [None or describe errors]

## Issues Encountered

[List any issues and how they were resolved]

## Conclusion

[Summary: Does mixed OAuth/Bedrock routing work as designed?]
```

**Step 2: Fill in actual test results**

Populate the document with real outputs from Task 6 testing.

**Step 3: Commit testing results**

Run:
```bash
git add docs/plans/2026-02-13-oauth-testing-results.md
git commit -m "test: document OAuth/Bedrock mixed routing results

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

Expected: Commit created

---

## Task 8: Update CLAUDE.md Implementation Notes

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Add OAuth routing section**

After the "LiteLLM Lifecycle" section (after line 71), add:

```markdown
## OAuth Token Routing

When using openClaude with OAuth authentication:

- **Opus/Sonnet:** Routed to Anthropic API using Claude plan OAuth tokens
  - Tokens are forwarded from `Authorization` header by LiteLLM
  - No `ANTHROPIC_API_KEY` should be set (prevents OAuth flow)
  - Requires patched LiteLLM (PR #19912) until officially released

- **Haiku:** Routed to Bedrock using AWS credentials
  - Uses shell's AWS credentials (no profile switching)
  - Bedrock Converse API for non-Claude models

### LiteLLM OAuth Support

**Current status (Feb 2026):** Requires installing from PR branch

```bash
uv tool install git+https://github.com/iamadamreed/litellm.git@fix/anthropic-oauth-token-forwarding
```

**When PR #19912 merges:** Switch back to official release

```bash
uv tool uninstall litellm
uv tool install 'litellm[proxy]'
```

### Troubleshooting OAuth

If opus/sonnet requests fail with "API key missing":

1. Check `~/.openClaude/settings.json` has NO `ANTHROPIC_API_KEY` in env
2. Verify LiteLLM config has `forward_client_headers_to_llm_api: true`
3. Check LiteLLM logs for `Authorization: Bearer sk-ant-oat01-*` headers
4. Ensure using patched LiteLLM, not official release

```

**Step 2: Commit CLAUDE.md updates**

Run:
```bash
git add CLAUDE.md
git commit -m "docs: add OAuth routing implementation notes

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

Expected: Commit created

---

## Rollback Plan

If OAuth routing doesn't work and you need to rollback:

```bash
# 1. Restore original configs
git checkout HEAD~8 litellm-config.yaml openClaude README.md CLAUDE.md

# 2. Reinstall official LiteLLM
uv tool uninstall litellm
uv tool install 'litellm[proxy]'

# 3. Copy restored configs
cp openClaude ~/.local/bin/openClaude
cp litellm-config.yaml ~/.litellm/config.yaml

# 4. Kill and restart
pkill -f litellm
openclaude
```

This returns to the all-Bedrock configuration.

---

## Success Criteria

- [ ] Patched LiteLLM installed and running
- [ ] LiteLLM config routes opus/sonnet to `anthropic/`, haiku to `bedrock/`
- [ ] openClaude script doesn't override ANTHROPIC_API_KEY
- [ ] OAuth login flow works (browser authentication)
- [ ] Opus requests go to api.anthropic.com with OAuth tokens
- [ ] Sonnet requests go to api.anthropic.com with OAuth tokens
- [ ] Haiku requests go to Bedrock with AWS credentials
- [ ] No authentication errors in LiteLLM logs
- [ ] README documents OAuth setup and PR caveat
- [ ] All changes committed to git
