#!/usr/bin/env bash
# install.sh — Set up openClaude on this machine
#
# Idempotent: safe to re-run. Overwrites openClaude script and LiteLLM configs
# each time (they're source-controlled here). Prompts before touching AWS config.

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
  echo "Install litellm with:"
  echo "  uv tool install git+https://github.com/iamadamreed/litellm.git@fix/anthropic-oauth-token-forwarding"
  echo ""
  echo "  (See README.md for details on the patched LiteLLM requirement)"
  echo ""
  echo "Install jq with: brew install jq (macOS) or apt install jq (Linux)"
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

# ── Install LiteLLM configs ─────────────────────────────────────────
mkdir -p "$HOME/.litellm"

# Instance 1 config (main proxy — Anthropic OAuth + routing to Instance 2)
cp "$SCRIPT_DIR/litellm-config.yaml" "$HOME/.litellm/config.yaml"
echo "Installed LiteLLM config -> ~/.litellm/config.yaml"

# Instance 2 config (Bedrock-only proxy)
sed "s/aws_region_name: us-west-2/aws_region_name: $aws_region/g; s/aws_profile_name: openclaude/aws_profile_name: $aws_profile/g" \
  "$SCRIPT_DIR/litellm-config-bedrock.yaml" > "$HOME/.litellm/config-bedrock.yaml"
echo "Installed LiteLLM Bedrock config -> ~/.litellm/config-bedrock.yaml"

# ── AWS profile setup ───────────────────────────────────────────────
if grep -q "\[profile $aws_profile\]" "$HOME/.aws/config" 2>/dev/null; then
  echo "AWS profile '$aws_profile' already exists in ~/.aws/config — skipping."
else
  echo ""
  echo "No AWS profile '$aws_profile' found in ~/.aws/config."
  echo "openClaude needs an AWS profile with Bedrock access for the haiku model slot."
  echo ""
  read -rp "Set up profile '$aws_profile' now? [y/N]: " setup_profile
  if [[ "$setup_profile" =~ ^[Yy] ]]; then
    echo ""
    echo "Choose auth method:"
    echo "  1) IAM access keys (recommended for personal machines)"
    echo "  2) SSO (for corporate/federated environments)"
    echo ""
    read -rp "Auth method [1]: " auth_method
    auth_method="${auth_method:-1}"

    if [[ "$auth_method" == "2" ]]; then
      read -rp "SSO session name: " sso_session
      read -rp "SSO account ID: " sso_account_id
      read -rp "SSO role name: " sso_role_name

      mkdir -p "$HOME/.aws"
      cat >> "$HOME/.aws/config" <<EOF

[profile $aws_profile]
sso_session = $sso_session
sso_account_id = $sso_account_id
sso_role_name = $sso_role_name
region = $aws_region
output = json
EOF
      echo "Added SSO profile '$aws_profile' to ~/.aws/config"
      echo "Run 'aws sso login --profile $aws_profile' before using openclaude."
    else
      echo ""
      echo "Enter IAM credentials for Bedrock access."
      echo "(Create a dedicated IAM user with bedrock:InvokeModel and"
      echo " bedrock:InvokeModelWithResponseStream permissions.)"
      echo ""
      read -rp "AWS Access Key ID: " aws_key_id
      read -rsp "AWS Secret Access Key: " aws_secret_key
      echo ""

      mkdir -p "$HOME/.aws"

      # Add profile to config
      cat >> "$HOME/.aws/config" <<EOF

[profile $aws_profile]
region = $aws_region
output = json
EOF

      # Add credentials
      cat >> "$HOME/.aws/credentials" <<EOF

[$aws_profile]
aws_access_key_id = $aws_key_id
aws_secret_access_key = $aws_secret_key
EOF
      echo "Added IAM profile '$aws_profile' to ~/.aws/config and ~/.aws/credentials"
    fi
  else
    echo "Skipped. You'll need to configure the '$aws_profile' AWS profile manually."
    echo "See README.md for IAM setup instructions."
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
echo "  Run:  openclaude"
echo ""
echo "To override the AWS profile:  OPENCLAUDE_AWS_PROFILE=myprofile openclaude"
