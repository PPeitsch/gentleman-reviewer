# shellcheck shell=bash

Describe 'Retry and fallback functionality'
  # Colors
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  CYAN='\033[0;36m'
  NC='\033[0m'

  # Test state files
  MOCK_STATE_DIR=""

  setup() {
    MOCK_STATE_DIR=$(mktemp -d)
    echo "0" > "$MOCK_STATE_DIR/call_count"
    echo "0" > "$MOCK_STATE_DIR/fail_count"
  }

  cleanup() {
    rm -rf "$MOCK_STATE_DIR"
  }

  BeforeEach 'setup'
  AfterEach 'cleanup'

  # Mock sleep to avoid delays
  sleep() {
    echo "$1" >> "$MOCK_STATE_DIR/sleep_calls"
  }

  # Configurable mock provider
  mock_execute_provider_internal() {
    local provider="$1"
    local prompt="$2"

    # Increment call count
    local count
    count=$(cat "$MOCK_STATE_DIR/call_count")
    count=$((count + 1))
    echo "$count" > "$MOCK_STATE_DIR/call_count"
    echo "$provider" >> "$MOCK_STATE_DIR/providers"

    # Check if should fail
    local fail_count
    fail_count=$(cat "$MOCK_STATE_DIR/fail_count")

    if [[ $count -le $fail_count ]]; then
      echo "Error: Mock failure $count" >&2
      return 1
    fi
    echo "SUCCESS: Mock response from $provider"
    return 0
  }

  # Implementation under test
  execute_with_retry_testable() {
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

    while [[ $attempt -le $retry_count ]]; do
      result=$(mock_execute_provider_internal "$provider" "$prompt" 2>&1)
      status=$?

      if [[ $status -eq 0 ]]; then
        printf '%s' "$result"
        return 0
      fi

      last_error="$result"

      if [[ $attempt -lt $retry_count ]]; then
        echo -e "${YELLOW}Provider $provider failed (attempt $attempt/$retry_count)${NC}" >&2
        echo -e "${CYAN}Retrying in ${current_delay}s...${NC}" >&2
        sleep "$current_delay"
        current_delay=$((current_delay * 2))
      fi

      attempt=$((attempt + 1))
    done

    echo -e "${RED}Provider $provider failed after $retry_count attempts${NC}" >&2

    if [[ -n "$fallback_provider" ]]; then
      echo -e "${CYAN}Attempting fallback provider: $fallback_provider${NC}" >&2

      result=$(mock_execute_provider_internal "$fallback_provider" "$prompt" 2>&1)
      status=$?

      if [[ $status -eq 0 ]]; then
        echo -e "${CYAN}Fallback provider $fallback_provider succeeded${NC}" >&2
        printf '%s' "$result"
        return 0
      fi

      echo -e "${RED}Fallback provider $fallback_provider also failed${NC}" >&2
      printf '%s' "$result"
      return 1
    fi

    printf '%s' "$last_error"
    return 1
  }

  get_call_count() {
    cat "$MOCK_STATE_DIR/call_count"
  }

  set_fail_count() {
    echo "$1" > "$MOCK_STATE_DIR/fail_count"
  }

  Describe 'execute_with_retry()'
    It 'succeeds on first attempt'
      set_fail_count 0

      result=$(execute_with_retry_testable "claude" "test prompt" 3 1 "" 2>/dev/null)
      call_count=$(get_call_count)

      The value "$result" should include "SUCCESS"
      The value "$call_count" should equal "1"
    End

    It 'retries on failure and succeeds on third attempt'
      set_fail_count 2

      result=$(execute_with_retry_testable "claude" "test prompt" 3 1 "" 2>/dev/null)
      call_count=$(get_call_count)

      The value "$result" should include "SUCCESS"
      The value "$call_count" should equal "3"
    End

    It 'fails after all retries exhausted'
      set_fail_count 10

      local status=0
      execute_with_retry_testable "claude" "test prompt" 3 1 "" 2>/dev/null || status=$?
      call_count=$(get_call_count)

      The value "$status" should equal "1"
      The value "$call_count" should equal "3"
    End

    It 'uses fallback provider when primary fails'
      set_fail_count 3

      result=$(execute_with_retry_testable "claude" "test prompt" 3 1 "gemini" 2>/dev/null)
      call_count=$(get_call_count)

      The value "$result" should include "SUCCESS"
      The value "$result" should include "gemini"
      The value "$call_count" should equal "4"
    End

    It 'fails when both primary and fallback fail'
      set_fail_count 100

      local status=0
      execute_with_retry_testable "claude" "test prompt" 3 1 "gemini" 2>/dev/null || status=$?
      call_count=$(get_call_count)

      The value "$status" should equal "1"
      The value "$call_count" should equal "4"
    End

    It 'respects retry count parameter'
      set_fail_count 10

      execute_with_retry_testable "claude" "test prompt" 5 1 "" 2>/dev/null || true
      call_count=$(get_call_count)

      The value "$call_count" should equal "5"
    End

    It 'works without fallback configured'
      set_fail_count 3

      local status=0
      execute_with_retry_testable "claude" "test prompt" 3 1 "" 2>/dev/null || status=$?
      call_count=$(get_call_count)

      The value "$status" should equal "1"
      The value "$call_count" should equal "3"
    End
  End

  Describe 'execute_with_retry() logging'
    It 'logs retry attempts to stderr'
      set_fail_count 2

      stderr=$(execute_with_retry_testable "claude" "test prompt" 3 1 "" 2>&1 >/dev/null)

      The value "$stderr" should include "failed"
      The value "$stderr" should include "attempt"
      The value "$stderr" should include "Retrying"
    End

    It 'logs fallback attempt to stderr'
      set_fail_count 3

      stderr=$(execute_with_retry_testable "claude" "test prompt" 3 1 "gemini" 2>&1 >/dev/null)

      The value "$stderr" should include "fallback"
      The value "$stderr" should include "gemini"
    End
  End

  Describe 'exponential backoff'
    It 'doubles delay on each retry'
      set_fail_count 10

      execute_with_retry_testable "claude" "test prompt" 4 2 "" 2>/dev/null || true

      sleep_calls=$(cat "$MOCK_STATE_DIR/sleep_calls" 2>/dev/null || echo "")

      # Should have called sleep with: 2, 4, 8 (for 3 retries after initial attempt)
      The value "$sleep_calls" should include "2"
      The value "$sleep_calls" should include "4"
      The value "$sleep_calls" should include "8"
    End
  End
End