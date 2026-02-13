#!/usr/bin/env bash
# install.sh — Set up openClaude on this machine
#
# Idempotent: safe to re-run. Overwrites openClaude script and LiteLLM config
# each time (they're source-controlled here). Prompts before touching ~/.aws/config.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "openClaude installer"
echo "===================="
echo ""

# ── Check prerequisites ──────────────────────────────────────────────
missing=()
command -v claude >/dev/null 2>&1 || missing+=("claude (Claude Code)")
command -v jq >/dev/null 2>&1 || missing+=("jq")
command -v aws >/dev/null 2>&1 || missing+=("aws (AWS CLI)")

if ! command -v litellm >/dev/null 2>&1; then
  missing+=("litellm")
fi

if [ ${#missing[@]} -gt 0 ]; then
  echo "Missing prerequisites:"
  for m in "${missing[@]}"; do
    echo "  - $m"
  done
  echo ""
  echo "Install litellm with: uv tool install 'litellm[proxy]'"
  echo "Install jq with: brew install jq"
  exit 1
fi

echo "All prerequisites found."
echo ""

# ── Prompt for configuration ─────────────────────────────────────────
read -rp "AWS profile name [openclaude]: " aws_profile
aws_profile="${aws_profile:-openclaude}"

read -rp "AWS region [us-west-2]: " aws_region
aws_region="${aws_region:-us-west-2}"

# ── Install openClaude script ────────────────────────────────────────
mkdir -p "$HOME/.local/bin"
cp "$SCRIPT_DIR/openClaude" "$HOME/.local/bin/openClaude"
chmod +x "$HOME/.local/bin/openClaude"
echo "Installed openClaude -> ~/.local/bin/openClaude"

# ── Install LiteLLM config ──────────────────────────────────────────
mkdir -p "$HOME/.litellm"
sed "s/aws_region_name: us-west-2/aws_region_name: $aws_region/g" \
  "$SCRIPT_DIR/litellm-config.yaml" > "$HOME/.litellm/config.yaml"
echo "Installed LiteLLM config -> ~/.litellm/config.yaml"

# ── AWS profile setup ───────────────────────────────────────────────
if grep -q "\[profile $aws_profile\]" "$HOME/.aws/config" 2>/dev/null; then
  echo "AWS profile '$aws_profile' already exists in ~/.aws/config — skipping."
else
  echo ""
  echo "No AWS profile '$aws_profile' found in ~/.aws/config."
  echo "openClaude needs an AWS profile with Bedrock access to route model requests."
  echo ""
  read -rp "Add profile '$aws_profile' to ~/.aws/config? [y/N]: " add_profile
  if [[ "$add_profile" =~ ^[Yy] ]]; then
    read -rp "SSO session name: " sso_session
    read -rp "SSO account ID: " sso_account_id
    read -rp "SSO role name: " sso_role_name

    cat >> "$HOME/.aws/config" <<EOF

[profile $aws_profile]
sso_session = $sso_session
sso_account_id = $sso_account_id
sso_role_name = $sso_role_name
region = $aws_region
output = json
EOF
    echo "Added profile '$aws_profile' to ~/.aws/config"
  else
    echo "Skipped. You'll need to configure the '$aws_profile' AWS profile manually."
  fi
fi

# ── Verify PATH ─────────────────────────────────────────────────────
if ! echo "$PATH" | tr ':' '\n' | grep -q "$HOME/.local/bin"; then
  echo ""
  echo "Warning: ~/.local/bin is not in your PATH."
  echo "Add this to your shell profile:"
  echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# ── Done ─────────────────────────────────────────────────────────────
echo ""
echo "Done! To get started:"
echo "  1. Log in to AWS SSO:  aws sso login --profile $aws_profile"
echo "  2. Run:                openclaude"
echo ""
echo "To override the AWS profile:  OPENCLAUDE_AWS_PROFILE=myprofile openclaude"
