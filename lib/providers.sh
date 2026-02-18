#!/usr/bin/env bash

# ============================================================================
# Gentleman Guardian Angel - Provider Functions
# ============================================================================
# Handles execution for different AI providers:
# - claude: Anthropic Claude Code CLI
# - gemini: Google Gemini CLI
# - codex: OpenAI Codex CLI
# - opencode: OpenCode CLI (optional :model)
# - ollama:<model>: Ollama with specified model
# ============================================================================

# Colors (in case sourced independently)
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================================
# Provider Validation
# ============================================================================

validate_provider() {
  local provider="$1"
  local base_provider="${provider%%:*}"

  case "$base_provider" in
    claude)
      if ! command -v claude &> /dev/null; then
        echo -e "${RED}❌ Claude CLI not found${NC}"
        echo ""
        echo "Install Claude Code CLI:"
        echo "  https://claude.ai/code"
        echo ""
        return 1
      fi
      ;;
    gemini)
      if ! command -v gemini &> /dev/null; then
        echo -e "${RED}❌ Gemini CLI not found${NC}"
        echo ""
        echo "Install Gemini CLI:"
        echo "  npm install -g @anthropic-ai/gemini-cli"
        echo "  # or"
        echo "  brew install gemini"
        echo ""
        return 1
      fi
      ;;
    codex)
      if ! command -v codex &> /dev/null; then
        echo -e "${RED}❌ Codex CLI not found${NC}"
        echo ""
        echo "Install OpenAI Codex CLI:"
        echo "  npm install -g @openai/codex"
        echo "  # or"
        echo "  brew install --cask codex"
        echo ""
        return 1
      fi
      ;;
    opencode)
      if ! command -v opencode &> /dev/null; then
        echo -e "${RED}❌ OpenCode CLI not found${NC}"
        echo ""
        echo "Install OpenCode CLI:"
        echo "  https://opencode.ai"
        echo ""
        return 1
      fi
      ;;
    ollama)
      if ! command -v ollama &> /dev/null; then
        echo -e "${RED}❌ Ollama not found${NC}"
        echo ""
        echo "Install Ollama:"
        echo "  https://ollama.ai/download"
        echo "  # or"
        echo "  brew install ollama"
        echo ""
        return 1
      fi
      # Check if model is specified
      local model="${provider#*:}"
      if [[ "$model" == "$provider" || -z "$model" ]]; then
        echo -e "${RED}❌ Ollama requires a model${NC}"
        echo ""
        echo "Specify model in provider config:"
        echo "  PROVIDER=\"ollama:llama3.2\""
        echo "  PROVIDER=\"ollama:codellama\""
        echo ""
        return 1
      fi
      ;;
    *)
      echo -e "${RED}❌ Unknown provider: $provider${NC}"
      echo ""
      echo "Supported providers:"
      echo "  - claude"
      echo "  - gemini"
      echo "  - codex"
      echo "  - opencode"
      echo "  - ollama:<model>"
      echo ""
      return 1
      ;;
  esac

  return 0
}

# ============================================================================
# Provider Execution
# ============================================================================

# Execute provider with retry and fallback support
# Usage: execute_with_retry provider prompt retry_count retry_delay fallback_provider
execute_with_retry() {
  local provider="$1"
  local prompt="$2"
  local retry_count="${3:-3}"
  local retry_delay="${4:-2}"
  local fallback_provider="${5:-}"

  local result
  local status
  local attempt=1
  local current_delay="$retry_delay"
  local last_error=""

  # Try primary provider with retries
  while [[ $attempt -le $retry_count ]]; do
    # Capture both stdout and exit status
    result=$(execute_provider_internal "$provider" "$prompt" 2>&1)
    status=$?

    if [[ $status -eq 0 ]]; then
      # Success - output result and return
      printf '%s' "$result"
      return 0
    fi

    # Save error for later reporting
    last_error="$result"

    # Log retry attempt (if not last attempt)
    if [[ $attempt -lt $retry_count ]]; then
      echo -e "${YELLOW}⚠️  Provider $provider failed (attempt $attempt/$retry_count)${NC}" >&2
      if [[ -n "$last_error" ]]; then
        echo -e "${YELLOW}   Error: $(echo "$last_error" | head -n 1)${NC}" >&2
      fi
      echo -e "${CYAN}⏳ Retrying in ${current_delay}s...${NC}" >&2
      sleep "$current_delay"
      # Exponential backoff: double the delay
      current_delay=$((current_delay * 2))
    fi

    attempt=$((attempt + 1))
  done

  # All retries failed
  echo -e "${RED}❌ Provider $provider failed after $retry_count attempts${NC}" >&2

  # Try fallback provider if configured
  if [[ -n "$fallback_provider" ]]; then
    echo -e "${CYAN}🔄 Attempting fallback provider: $fallback_provider${NC}" >&2

    # Validate fallback provider
    if ! validate_provider "$fallback_provider" 2>/dev/null; then
      echo -e "${RED}❌ Fallback provider $fallback_provider is not available${NC}" >&2
      printf '%s' "$last_error"
      return 1
    fi

    # Execute fallback (single attempt, no retry)
    result=$(execute_provider_internal "$fallback_provider" "$prompt" 2>&1)
    status=$?

    if [[ $status -eq 0 ]]; then
      echo -e "${CYAN}✅ Fallback provider $fallback_provider succeeded${NC}" >&2
      printf '%s' "$result"
      return 0
    fi

    echo -e "${RED}❌ Fallback provider $fallback_provider also failed${NC}" >&2
    echo -e "${RED}   Primary error: $(echo "$last_error" | head -n 1)${NC}" >&2
    echo -e "${RED}   Fallback error: $(echo "$result" | head -n 1)${NC}" >&2
    printf '%s' "$result"
    return 1
  fi

  # No fallback, return last error
  printf '%s' "$last_error"
  return 1
}

# Internal provider execution (no retry logic)
execute_provider_internal() {
  local provider="$1"
  local prompt="$2"
  local base_provider="${provider%%:*}"

  case "$base_provider" in
    claude)
      execute_claude "$prompt"
      ;;
    gemini)
      execute_gemini "$prompt"
      ;;
    codex)
      execute_codex "$prompt"
      ;;
    opencode)
      local model="${provider#*:}"
      if [[ "$model" == "$provider" ]]; then
        model=""
      fi
      execute_opencode "$model" "$prompt"
      ;;
    ollama)
      local model="${provider#*:}"
      execute_ollama "$model" "$prompt"
      ;;
  esac
}

# Legacy function for backwards compatibility
execute_provider() {
  local provider="$1"
  local prompt="$2"

  execute_provider_internal "$provider" "$prompt"
}

# ============================================================================
# Individual Provider Implementations
# ============================================================================

execute_claude() {
  local prompt="$1"
  
  # Claude CLI accepts prompt via stdin pipe
  # Redirect stderr to stdout to capture any error messages
  printf '%s' "$prompt" | claude --print 2>&1
  return "${PIPESTATUS[1]}"
}

execute_gemini() {
  local prompt="$1"
  
  if ! is_gemini_authenticated; then
    echo -e "${RED}❌ Gemini CLI is not authenticated${NC}" >&2
    echo ""
    echo "Please log in to Gemini CLI first:"
    echo "  gemini login"
    echo ""
    echo "Or visit: https://gemini.google.com"
    return 1
  fi
  
  gemini -p "$prompt" 2>&1
  return $?
}

is_gemini_authenticated() {
  gemini whoami &>/dev/null
}

execute_codex() {
  local prompt="$1"
  
  # Codex uses exec subcommand for non-interactive mode
  # Using --output-last-message to get just the final response
  codex exec "$prompt" 2>&1
  return $?
}

execute_opencode() {
  local model="$1"
  local prompt="$2"
  
  # OpenCode CLI accepts prompt as positional argument
  # opencode run [message..] - message is a positional array
  if [[ -n "$model" ]]; then
    opencode run --model "$model" "$prompt" 2>&1
  else
    opencode run "$prompt" 2>&1
  fi
  return $?
}

execute_ollama() {
  local model="$1"
  local prompt="$2"
  local host="${OLLAMA_HOST:-http://localhost:11434}"
  
  # Validate OLLAMA_HOST format to prevent injection attacks
  if ! validate_ollama_host "$host"; then
    echo "Error: Invalid OLLAMA_HOST format. Expected: http(s)://hostname(:port)" >&2
    return 1
  fi
  
  # Use python3 + curl if available (cleaner output, supports remote hosts)
  # Falls back to CLI with ANSI stripping if python3 is not available
  if command -v python3 &> /dev/null && command -v curl &> /dev/null; then
    execute_ollama_api "$model" "$prompt" "$host"
    return $?
  else
    execute_ollama_cli "$model" "$prompt"
    return $?
  fi
}

# Validate OLLAMA_HOST to prevent command injection
# Accepts: http(s)://hostname(:port) with optional trailing slash
validate_ollama_host() {
  local host="$1"
  
  # Regex: http or https, followed by hostname (alphanumeric, dots, hyphens), 
  # optional port, optional trailing slash
  if [[ "$host" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?/?$ ]]; then
    return 0
  fi
  return 1
}

# Execute Ollama via REST API using curl + python3
# This approach produces clean output without terminal escape codes
execute_ollama_api() {
  local model="$1"
  local prompt="$2"
  local host="$3"
  
  # Build JSON payload safely using python3 to escape special characters
  # Using stdin to avoid ARG_MAX limits with large prompts
  local json_payload
  if ! json_payload=$(printf '%s' "$prompt" | python3 -c "
import sys, json
prompt = sys.stdin.read()
model = sys.argv[1]
payload = json.dumps({
    'model': model,
    'prompt': prompt,
    'stream': False
})
print(payload)
" "$model" 2>&1); then
    echo "Error: Failed to build JSON payload" >&2
    echo "$json_payload" >&2
    return 1
  fi
  
  # Remove trailing slash from host if present
  host="${host%/}"
  
  # Call Ollama API
  local api_response
  api_response=$(curl -s --fail-with-body \
    -H "Content-Type: application/json" \
    -d "$json_payload" \
    "${host}/api/generate" 2>&1)
  
  local curl_status=$?
  if [[ $curl_status -ne 0 ]]; then
    echo "Error: Failed to connect to Ollama at $host" >&2
    echo "$api_response" >&2
    return 1
  fi
  
  # Extract response safely using python3
  printf '%s' "$api_response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    response = data.get('response', '')
    if response:
        print(response)
    else:
        error = data.get('error', 'Unknown error from Ollama')
        print(f'Error: {error}', file=sys.stderr)
        sys.exit(1)
except json.JSONDecodeError as e:
    print(f'Error: Invalid JSON response from Ollama: {e}', file=sys.stderr)
    sys.exit(1)
"
  return $?
}

# Execute Ollama via CLI (fallback when python3/curl not available)
# Strips ANSI escape codes from output to fix STATUS detection
execute_ollama_cli() {
  local model="$1"
  local prompt="$2"
  
  # Run ollama CLI, suppress stderr (spinner/progress), strip ANSI codes from stdout
  # The 2>/dev/null removes spinner and progress messages
  # The sed removes any remaining ANSI escape sequences
  ollama run "$model" "$prompt" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
  return "${PIPESTATUS[0]}"
}

# ============================================================================
# Provider Info
# ============================================================================

get_provider_info() {
  local provider="$1"
  local base_provider="${provider%%:*}"

  case "$base_provider" in
    claude)
      echo "Anthropic Claude Code CLI"
      ;;
    gemini)
      echo "Google Gemini CLI"
      ;;
    codex)
      echo "OpenAI Codex CLI"
      ;;
    opencode)
      local model="${provider#*:}"
      if [[ "$model" == "$provider" ]]; then
        echo "OpenCode CLI"
      else
        echo "OpenCode CLI (model: $model)"
      fi
      ;;
    ollama)
      local model="${provider#*:}"
      echo "Ollama (model: $model)"
      ;;
    *)
      echo "Unknown provider"
      ;;
  esac
}
