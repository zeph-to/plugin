#!/usr/bin/env bash
# Zeph Agent Plugin — multi-agent installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/zeph-to/plugin/main/install.sh | bash
#
# Flags:
#   --only <agent>   Install only for named agent (repeatable)
#   --dry-run        Preview, write nothing
#   --uninstall      Remove Zeph from all detected agents
#   --skip-config    Skip API key configuration prompt
#   --check-update   Check if a newer version is available
#   --verify         Verify installation health

set -euo pipefail

REPO="zeph-to/plugin"
# ── Flags ──────────────────────────────────────────────────────────────────
DRY=0
UNINSTALL=0
SKIP_CONFIG=0
CHECK_UPDATE=0
VERIFY=0
ONLY=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)        DRY=1 ;;
    --uninstall)      UNINSTALL=1 ;;
    --skip-config)    SKIP_CONFIG=1 ;;
    --check-update)   CHECK_UPDATE=1 ;;
    --verify)         VERIFY=1 ;;
    --only)           shift; ONLY+=("$1") ;;
    -h|--help)        sed -n '2,14p' "$0"; exit 0 ;;
    *)                echo "Unknown flag: $1"; exit 1 ;;
  esac
  shift
done

# ── Helpers ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
skip() { echo -e "  ${YELLOW}✗${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }

should_install() {
  local agent="$1"
  if [ ${#ONLY[@]} -eq 0 ]; then return 0; fi
  for o in "${ONLY[@]}"; do
    if [ "$o" = "$agent" ]; then return 0; fi
  done
  return 1
}

inject_mcp_json() {
  local mcp_file="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 not found — skipping MCP injection into $mcp_file"
    return 1
  fi
  python3 -c "
import json, os
f = '$mcp_file'
d = {}
if os.path.exists(f):
    try: d = json.load(open(f))
    except: pass
if 'mcpServers' not in d: d['mcpServers'] = {}
d['mcpServers']['zeph'] = {
    'command': 'npx',
    'args': ['-y', '@zeph-to/mcp-server'],
    'env': {'ZEPH_API_KEY': '\${ZEPH_API_KEY}'}
}
json.dump(d, open(f, 'w'), indent=2)
"
}

# Read version from the canonical source so we don't drift from plugin.json.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_JSON="$SCRIPT_DIR/.claude-plugin/plugin.json"
if [ -f "$PLUGIN_JSON" ] && command -v python3 >/dev/null 2>&1; then
  LOCAL_VERSION=$(python3 -c "import json; print(json.load(open('$PLUGIN_JSON'))['version'])" 2>/dev/null || echo "0.0.0")
else
  # When piped from curl, the script isn't on disk — fetch the version inline.
  LOCAL_VERSION=$(curl -fsSL "https://raw.githubusercontent.com/$REPO/main/.claude-plugin/plugin.json" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])" 2>/dev/null || echo "0.0.0")
fi

# ── Skills CLI Helper ─────────────────────────────────────────────────────
install_skills() {
  local agents_flag="$1"
  if [ $DRY -eq 1 ]; then
    echo "  [dry-run] skills add $REPO -g -a $agents_flag -y"
    return
  fi
  # npx may misinterpret "skills" as an npm subcommand on npm 10.x; fall back to npm exec
  if command -v npx >/dev/null 2>&1 && npx -y skills add "$REPO" -g -a "$agents_flag" -y 2>/dev/null; then
    ok "Skills installed ($agents_flag)"
  elif command -v npm >/dev/null 2>&1 && npm exec -y -- skills add "$REPO" -g -a "$agents_flag" -y 2>/dev/null; then
    ok "Skills installed ($agents_flag)"
  else
    skip "Skills CLI unavailable — skipping skill install for $agents_flag"
  fi
}

# ── Check Update ──────────────────────────────────────────────────────────
if [ $CHECK_UPDATE -eq 1 ]; then
  echo -e "\n🔄 Checking for updates..."
  REMOTE_VERSION=$(curl -fsSL "https://raw.githubusercontent.com/$REPO/main/.claude-plugin/plugin.json" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('version','unknown'))" 2>/dev/null || echo "unknown")
  if [ "$REMOTE_VERSION" = "unknown" ]; then
    fail "Could not fetch remote version"
  elif [ "$REMOTE_VERSION" = "$LOCAL_VERSION" ]; then
    ok "Up to date (v$LOCAL_VERSION)"
  else
    echo -e "  ${YELLOW}⬆${NC}  Update available: v$LOCAL_VERSION → v$REMOTE_VERSION"
    echo "  Re-run the installer to update."
  fi
  exit 0
fi

# ── Detection ──────────────────────────────────────────────────────────────
echo -e "\n🔍 Detecting agents..."

HAS_CLAUDE=0
HAS_GEMINI=0
HAS_CURSOR=0
HAS_WINDSURF=0
HAS_CLINE=0
HAS_CODEX=0
HAS_COPILOT=0
HAS_AIDER=0

command -v claude >/dev/null 2>&1 && HAS_CLAUDE=1
command -v gemini >/dev/null 2>&1 && HAS_GEMINI=1
[ -d "$HOME/.cursor" ] && HAS_CURSOR=1
[ -d "$HOME/.codeium" ] && HAS_WINDSURF=1
{ command -v cline >/dev/null 2>&1 || [ -d "$HOME/.cline" ]; } && HAS_CLINE=1
command -v codex >/dev/null 2>&1 && HAS_CODEX=1
[ -d "$HOME/.copilot" ] && HAS_COPILOT=1
command -v aider >/dev/null 2>&1 && HAS_AIDER=1

[ $HAS_CLAUDE -eq 1 ]   && ok "Claude Code"   || skip "Claude Code — not found"
[ $HAS_GEMINI -eq 1 ]   && ok "Gemini CLI"    || skip "Gemini CLI — not found"
[ $HAS_CURSOR -eq 1 ]   && ok "Cursor IDE"    || skip "Cursor — not found"
[ $HAS_WINDSURF -eq 1 ] && ok "Windsurf IDE"  || skip "Windsurf — not found"
[ $HAS_CLINE -eq 1 ]    && ok "Cline"         || skip "Cline — not found"
[ $HAS_CODEX -eq 1 ]    && ok "Codex CLI"     || skip "Codex CLI — not found"
[ $HAS_COPILOT -eq 1 ]  && ok "Copilot CLI"   || skip "Copilot CLI — not found"
[ $HAS_AIDER -eq 1 ]    && ok "Aider"         || skip "Aider — not found"

# ── Verify ─────────────────────────────────────────────────────────────────
if [ $VERIFY -eq 1 ]; then
  echo -e "\n🩺 Verifying Zeph installation..."
  PASS=0
  TOTAL=0

  # Check env vars
  TOTAL=$((TOTAL + 1))
  if [ -n "${ZEPH_API_KEY:-}" ]; then
    ok "ZEPH_API_KEY is set"; PASS=$((PASS + 1))
  else
    fail "ZEPH_API_KEY not set"
  fi

  TOTAL=$((TOTAL + 1))
  if [ -n "${ZEPH_HOOK_ID:-}" ]; then
    ok "ZEPH_HOOK_ID is set (interactive features enabled)"; PASS=$((PASS + 1))
  else
    skip "ZEPH_HOOK_ID not set (prompt/input disabled)"
    PASS=$((PASS + 1))  # optional, not a failure
  fi

  # Check MCP server availability
  TOTAL=$((TOTAL + 1))
  if command -v npx >/dev/null 2>&1; then
    ok "npx available (MCP server can start via npx)"; PASS=$((PASS + 1))
  else
    fail "npx not found — install Node.js to enable MCP server"
  fi

  # Check CLI availability (used by hooks for notifications)
  TOTAL=$((TOTAL + 1))
  if command -v zeph >/dev/null 2>&1; then
    ok "zeph CLI available (hooks can send notifications)"; PASS=$((PASS + 1))
  else
    fail "zeph not found — run: npm install -g @zeph-to/hook-sdk"
  fi

  # Check per-agent configs
  if [ $HAS_CLAUDE -eq 1 ]; then
    TOTAL=$((TOTAL + 1))
    if claude plugin list 2>/dev/null | grep -q "zeph"; then
      ok "Claude Code: plugin installed"; PASS=$((PASS + 1))
    else
      fail "Claude Code: plugin not installed"
    fi
  fi

  if [ $HAS_CURSOR -eq 1 ]; then
    TOTAL=$((TOTAL + 1))
    if [ -f "$HOME/.cursor/mcp.json" ] && python3 -c "import json; d=json.load(open('$HOME/.cursor/mcp.json')); assert 'zeph' in d.get('mcpServers',{})" 2>/dev/null; then
      ok "Cursor: MCP configured"; PASS=$((PASS + 1))
    else
      fail "Cursor: zeph not in mcp.json"
    fi
  fi

  if [ $HAS_WINDSURF -eq 1 ]; then
    TOTAL=$((TOTAL + 1))
    MCP_FILE="$HOME/.codeium/windsurf/mcp_config.json"
    if [ -f "$MCP_FILE" ] && python3 -c "import json; d=json.load(open('$MCP_FILE')); assert 'zeph' in d.get('mcpServers',{})" 2>/dev/null; then
      ok "Windsurf: MCP configured"; PASS=$((PASS + 1))
    else
      fail "Windsurf: zeph not in mcp_config.json"
    fi
  fi

  if [ $HAS_CODEX -eq 1 ]; then
    TOTAL=$((TOTAL + 1))
    if [ -f "$HOME/.codex/hooks.json" ]; then
      ok "Codex: hooks.json exists"; PASS=$((PASS + 1))
    else
      fail "Codex: hooks.json not found"
    fi
  fi

  echo ""
  if [ $PASS -eq $TOTAL ]; then
    echo -e "${GREEN}✅ All checks passed ($PASS/$TOTAL)${NC}"
  else
    echo -e "${YELLOW}⚠️  $PASS/$TOTAL checks passed${NC}"
  fi
  exit 0
fi

# ── Uninstall ──────────────────────────────────────────────────────────────
if [ $UNINSTALL -eq 1 ]; then
  echo -e "\n🗑️  Uninstalling Zeph..."

  if [ $HAS_CLAUDE -eq 1 ]; then
    [ $DRY -eq 0 ] && claude plugin uninstall zeph 2>/dev/null && ok "Claude: plugin removed" || skip "Claude: not installed"
  fi

  if [ $HAS_GEMINI -eq 1 ]; then
    [ $DRY -eq 0 ] && gemini mcp remove zeph 2>/dev/null && ok "Gemini: MCP removed" || true
    [ $DRY -eq 0 ] && gemini extensions uninstall zeph 2>/dev/null && ok "Gemini: extension removed" || true
  fi

  # Remove MCP from JSON config files
  remove_mcp_json() {
    local f="$1" label="$2"
    if [ -f "$f" ] && command -v python3 >/dev/null 2>&1; then
      [ $DRY -eq 0 ] && python3 -c "
import json
f='$f'
try:
    d=json.load(open(f))
    if 'mcpServers' in d and 'zeph' in d['mcpServers']:
        del d['mcpServers']['zeph']
        json.dump(d, open(f,'w'), indent=2)
        print('  ✓ $label: MCP removed')
    else:
        print('  ✗ $label: zeph not configured')
except: pass
"
    fi
  }

  [ $HAS_CURSOR -eq 1 ] && remove_mcp_json "$HOME/.cursor/mcp.json" "Cursor"
  [ $HAS_WINDSURF -eq 1 ] && remove_mcp_json "$HOME/.codeium/windsurf/mcp_config.json" "Windsurf"

  # Remove legacy rule/config files
  [ -f "$HOME/.cursor/rules/zeph.mdc" ] && rm "$HOME/.cursor/rules/zeph.mdc" && ok "Cursor: legacy rule removed"
  [ -f "$HOME/.windsurf/rules/zeph.md" ] && rm "$HOME/.windsurf/rules/zeph.md" && ok "Windsurf: legacy rule removed"
  [ -f "$HOME/.cline/rules/zeph.md" ] && rm "$HOME/.cline/rules/zeph.md" && ok "Cline: legacy rule removed"
  [ -f "$HOME/.codex/hooks.json" ] && rm "$HOME/.codex/hooks.json" && ok "Codex: hooks removed"

  # Remove skills (installed via skills CLI)
  for base in "$HOME/.agents/skills" "$HOME/.claude/skills" "$HOME/.cursor/skills" "$HOME/.codeium/windsurf/skills" "$HOME/.gemini/skills"; do
    [ -d "$base" ] || continue
    for dir in "$base"/zeph*; do
      [ -e "$dir" ] || [ -L "$dir" ] || continue
      rm -rf "$dir" && ok "Skill removed: $(basename "$dir")"
    done
  done

  if [ -f "$HOME/.aider.conf.yml" ] && grep -q "# Added by Zeph" "$HOME/.aider.conf.yml" 2>/dev/null; then
    sed -i.bak '/# Added by Zeph/,/^$/d' "$HOME/.aider.conf.yml" && rm -f "$HOME/.aider.conf.yml.bak"
    ok "Aider: config cleaned"
  fi

  echo -e "\n${GREEN}✅ Uninstall complete.${NC} Remove ZEPH_API_KEY/ZEPH_HOOK_ID from your shell profile manually."
  exit 0
fi

# ── Install ────────────────────────────────────────────────────────────────
echo ""

# Install MCP server globally (npx broken with scoped packages on npm 10+)
echo -e "📦 Installing MCP server..."
if ! command -v npm >/dev/null 2>&1; then
  fail "npm not found — install Node.js first"
  exit 1
fi

# Resolve a user-writable npm prefix so we never need sudo. `sudo npm` is
# unsafe — npm runs package install scripts as the elevated user, which is a
# supply-chain hazard. Prefer the user's existing prefix (nvm/asdf/fnm), or
# fall back to ~/.local for a vanilla install.
NPM_PREFIX="$(npm config get prefix 2>/dev/null || echo "")"
PREFIX_FLAG=""
if [ -z "$NPM_PREFIX" ] || [ ! -w "$NPM_PREFIX" ]; then
  PREFIX_FLAG="--prefix=$HOME/.local"
  echo "  Using user prefix: $HOME/.local (no sudo required)"
fi

if [ $DRY -eq 0 ]; then
  if npm install -g $PREFIX_FLAG @zeph-to/mcp-server@latest @zeph-to/hook-sdk@latest 2>&1 | tail -1; then
    ok "MCP server & CLI installed"
    if [ -n "$PREFIX_FLAG" ] && ! echo ":$PATH:" | grep -q ":$HOME/.local/bin:"; then
      echo ""
      echo -e "  ${YELLOW}⚠${NC}  Add this to your shell profile so \`zeph\` is on PATH:"
      echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
  else
    fail "Install failed"
    echo "  If you saw an EACCES permission error, your global prefix isn't user-writable."
    echo "  Safe options (do NOT use sudo npm — it runs install scripts as root):"
    echo "    1. Use nvm:  https://github.com/nvm-sh/nvm"
    echo "    2. Re-run with: npm config set prefix ~/.local && bash install.sh"
    exit 1
  fi
else
  echo "  [dry-run] npm install -g $PREFIX_FLAG @zeph-to/mcp-server@latest @zeph-to/hook-sdk@latest"
fi

# Claude Code
if [ $HAS_CLAUDE -eq 1 ] && should_install "claude"; then
  echo -e "📦 Installing for Claude Code..."
  if [ $DRY -eq 0 ]; then
    claude plugin marketplace add "$REPO" 2>/dev/null && ok "Marketplace added" || ok "Marketplace already added"
    claude plugin install "zeph@zeph" 2>/dev/null && ok "Plugin installed" || ok "Plugin already installed"
  else
    echo "  [dry-run] claude plugin marketplace add $REPO"
    echo "  [dry-run] claude plugin install zeph@zeph"
  fi
fi

# Gemini CLI
if [ $HAS_GEMINI -eq 1 ] && should_install "gemini"; then
  echo -e "📦 Installing for Gemini CLI..."
  install_skills "gemini-cli"
  if [ $DRY -eq 0 ]; then
    gemini mcp add zeph -- npx -y @zeph-to/mcp-server 2>/dev/null && ok "MCP server added" || ok "MCP already configured"
    # AfterAgent hook for auto-notifications
    if command -v python3 >/dev/null 2>&1; then
      python3 -c "
import json, os
f = os.path.expanduser('~/.gemini/settings.json')
d = {}
if os.path.exists(f):
    try: d = json.load(open(f))
    except: pass
d.setdefault('hooks', {})
d['hooks']['AfterAgent'] = [{'matcher': '*', 'hooks': [{'name': 'zeph-notify', 'type': 'command', 'command': '\$(command -v zeph || echo \"npx -y @zeph-to/hook-sdk\") notify --title \"Task done\" 2>/dev/null || true'}]}]
d['hooksConfig'] = {'enabled': True}
os.makedirs(os.path.dirname(f), exist_ok=True)
json.dump(d, open(f, 'w'), indent=2)
" && ok "AfterAgent hook added"
    fi
  else
    echo "  [dry-run] gemini mcp add + hooks"
  fi
fi

# Cursor
if [ $HAS_CURSOR -eq 1 ] && should_install "cursor"; then
  echo -e "📦 Installing for Cursor..."
  install_skills "cursor"
  if [ $DRY -eq 0 ]; then
    inject_mcp_json "$HOME/.cursor/mcp.json" && ok "MCP server added"
    cat > "$HOME/.cursor/hooks.json" <<'CURSOR_HOOKS'
{
  "version": 1,
  "hooks": {
    "stop": [{ "command": "$(command -v zeph || echo \"npx -y @zeph-to/hook-sdk\") notify --title \"Task done\" 2>/dev/null || true" }]
  }
}
CURSOR_HOOKS
    ok "Stop hook added"
  else
    echo "  [dry-run] Inject zeph into ~/.cursor/mcp.json + hooks.json"
  fi
fi

# Windsurf
if [ $HAS_WINDSURF -eq 1 ] && should_install "windsurf"; then
  echo -e "📦 Installing for Windsurf..."
  install_skills "windsurf"
  if [ $DRY -eq 0 ]; then
    inject_mcp_json "$HOME/.codeium/windsurf/mcp_config.json" && ok "MCP server added"
    mkdir -p "$HOME/.codeium/windsurf"
    cat > "$HOME/.codeium/windsurf/hooks.json" <<'WINDSURF_HOOKS'
{
  "hooks": {
    "post_cascade_response": [{ "command": "$(command -v zeph || echo \"npx -y @zeph-to/hook-sdk\") notify --title \"Task done\" 2>/dev/null || true", "show_output": false }]
  }
}
WINDSURF_HOOKS
    ok "Response hook added"
  else
    echo "  [dry-run] Inject zeph into ~/.codeium/windsurf/mcp_config.json + hooks"
  fi
fi

# Cline
if [ $HAS_CLINE -eq 1 ] && should_install "cline"; then
  echo -e "📦 Installing for Cline..."
  install_skills "cline"
fi

# Codex CLI
if [ $HAS_CODEX -eq 1 ] && should_install "codex"; then
  echo -e "📦 Installing for Codex CLI..."
  install_skills "codex"
  if [ $DRY -eq 0 ]; then
    mkdir -p "$HOME/.codex"
    cat > "$HOME/.codex/hooks.json" <<'CODEX_HOOKS'
{
  "version": 1,
  "hooks": {
    "Stop": [{ "type": "command", "bash": "$(command -v zeph || echo \"npx -y @zeph-to/hook-sdk\") notify --title \"Task done\" 2>/dev/null || true" }]
  }
}
CODEX_HOOKS
    ok "Stop hook added"
  else
    echo "  [dry-run] Write ~/.codex/hooks.json"
  fi
fi

# Copilot CLI
if [ $HAS_COPILOT -eq 1 ] && should_install "copilot"; then
  echo -e "📦 Installing for Copilot CLI..."
  install_skills "github-copilot"
  if [ $DRY -eq 0 ]; then
    mkdir -p "$HOME/.copilot/hooks"
    cat > "$HOME/.copilot/hooks/zeph.json" <<'COPILOT_HOOKS'
{
  "version": 1,
  "hooks": {
    "sessionEnd": [{ "type": "command", "bash": "$(command -v zeph || echo \"npx -y @zeph-to/hook-sdk\") notify --title \"Task done\" 2>/dev/null || true", "timeoutSec": 10 }]
  }
}
COPILOT_HOOKS
    ok "Session end hook added"
  else
    echo "  [dry-run] Write ~/.copilot/hooks/zeph.json"
  fi
fi

# Aider
if [ $HAS_AIDER -eq 1 ] && should_install "aider"; then
  echo -e "📦 Installing for Aider..."
  install_skills "universal"
fi

# ── API Key Configuration ──────────────────────────────────────────────────
if [ $SKIP_CONFIG -eq 0 ] && [ $DRY -eq 0 ]; then
  echo ""
  echo -e "🔑 ${YELLOW}Configuration${NC}"

  CURRENT_KEY="${ZEPH_API_KEY:-}"
  CURRENT_HOOK="${ZEPH_HOOK_ID:-}"

  # When invoked via `curl … | bash`, stdin is the pipe — read from the
  # controlling terminal directly so prompts actually work.
  if [ -r /dev/tty ]; then
    READ_FROM="/dev/tty"
  else
    READ_FROM=""
    echo ""
    echo -e "  ${YELLOW}⚠${NC}  No TTY available — skipping interactive prompts."
    echo "  Set ZEPH_API_KEY (and optionally ZEPH_HOOK_ID) in your shell, then re-run."
  fi

  if [ -n "$CURRENT_KEY" ]; then
    echo "  ZEPH_API_KEY already set: ${CURRENT_KEY:0:10}..."
  elif [ -n "$READ_FROM" ]; then
    echo "  Get your API key from Zeph → Settings → API Keys (MCP preset)"
    echo -n "  Enter ZEPH_API_KEY: "
    read -r NEW_KEY < "$READ_FROM"
    if [ -n "$NEW_KEY" ]; then
      CURRENT_KEY="$NEW_KEY"
    fi
  fi

  if [ -n "$CURRENT_KEY" ] && [ -z "$CURRENT_HOOK" ] && [ -n "$READ_FROM" ]; then
    echo ""
    echo "  Optional: For remote two-way control (zeph_ask/zeph_prompt/zeph_input),"
    echo "  create a Hook at Settings → Developer → Hooks"
    echo -n "  Enter ZEPH_HOOK_ID (or press Enter to skip): "
    read -r NEW_HOOK < "$READ_FROM"
    if [ -n "$NEW_HOOK" ]; then
      CURRENT_HOOK="$NEW_HOOK"
    fi
  fi

  # Write to shell profile
  if [ -n "$CURRENT_KEY" ]; then
    if [ -f "$HOME/.zshrc" ]; then SHELL_RC="$HOME/.zshrc"
    elif [ -f "$HOME/.bashrc" ]; then SHELL_RC="$HOME/.bashrc"
    elif [ -f "$HOME/.bash_profile" ]; then SHELL_RC="$HOME/.bash_profile"
    elif [ -f "$HOME/.profile" ]; then SHELL_RC="$HOME/.profile"
    else SHELL_RC="$HOME/.zshrc"; fi

    MARKER="# Added by Zeph"
    if ! grep -q "$MARKER" "$SHELL_RC" 2>/dev/null; then
      echo "" >> "$SHELL_RC"
      echo "$MARKER" >> "$SHELL_RC"
      echo "export ZEPH_API_KEY=\"$CURRENT_KEY\"" >> "$SHELL_RC"
      [ -n "$CURRENT_HOOK" ] && echo "export ZEPH_HOOK_ID=\"$CURRENT_HOOK\"" >> "$SHELL_RC"
      echo ""
      ok "Added to $SHELL_RC"
      echo "  Run: source $SHELL_RC"
    else
      echo ""
      ok "Zeph env vars already in $SHELL_RC"
    fi
  fi
fi

# ── Done ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}✅ Done!${NC} Restart your agents to activate Zeph notifications."
echo ""
