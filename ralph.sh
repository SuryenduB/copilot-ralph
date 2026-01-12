#!/bin/bash
# Ralph for GitHub Copilot CLI
# An autonomous AI agent loop that runs Copilot CLI repeatedly until all PRD items are complete.
# Based on Geoffrey Huntley's Ralph pattern: https://ghuntley.com/ralph/
#
# Usage: ./ralph.sh [max_iterations]

set -e

MAX_ITERATIONS=${1:-10}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="prd.json"
PROGRESS_FILE="progress.txt"
ARCHIVE_DIR="archive"
LAST_BRANCH_FILE=".ralph-last-branch"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Check if copilot CLI is installed
if ! command -v copilot &> /dev/null; then
    echo -e "${RED}Error: GitHub Copilot CLI is not installed.${NC}"
    echo "Install it with: npm install -g @github/copilot"
    echo "Then authenticate with: copilot"
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is not installed.${NC}"
    echo "Install it with: apt-get install jq (Linux) or brew install jq (macOS)"
    exit 1
fi

# Check if prd.json exists
if [ ! -f "$PRD_FILE" ]; then
    echo -e "${RED}Error: $PRD_FILE not found.${NC}"
    echo ""
    echo "Create a PRD file with your user stories. See prd.json.example for format."
    exit 1
fi

# Archive previous run if branch changed
if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
    CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
    LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")

    if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
        DATE=$(date +%Y-%m-%d)
        FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^ralph/||')
        ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"

        echo -e "${YELLOW}Archiving previous run: $LAST_BRANCH${NC}"
        mkdir -p "$ARCHIVE_FOLDER"
        [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
        [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
        echo "Archived to: $ARCHIVE_FOLDER"

        # Reset progress file for new run
        echo "# Ralph Progress Log" > "$PROGRESS_FILE"
        echo "Started: $(date)" >> "$PROGRESS_FILE"
        echo "---" >> "$PROGRESS_FILE"
    fi
fi

# Track current branch
if [ -f "$PRD_FILE" ]; then
    CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
    if [ -n "$CURRENT_BRANCH" ]; then
        echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
    fi
fi

# Initialize progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
    echo "# Ralph Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
fi

# Count remaining stories
count_remaining() {
    jq '[.userStories[] | select(.passes == false)] | length' "$PRD_FILE" 2>/dev/null || echo "?"
}

# Get current story being worked on
get_current_story() {
    jq -r '[.userStories[] | select(.passes == false)] | sort_by(.priority // 999) | .[0] | "\(.id): \(.title)"' "$PRD_FILE" 2>/dev/null || echo "unknown"
}

echo ""
echo -e "${BOLD}${CYAN}Ralph for GitHub Copilot CLI${NC}"
echo -e "${CYAN}----------------------------${NC}"
echo -e "Max iterations: ${YELLOW}$MAX_ITERATIONS${NC}"
echo -e "Remaining stories: ${YELLOW}$(count_remaining)${NC}"
echo ""

for i in $(seq 1 $MAX_ITERATIONS); do
    REMAINING=$(count_remaining)
    CURRENT=$(get_current_story)

    echo -e "${BLUE}--- Iteration $i of $MAX_ITERATIONS ---${NC}"
    echo -e "Stories remaining: ${YELLOW}$REMAINING${NC}"
    echo -e "Current: ${CYAN}$CURRENT${NC}"
    echo ""

    # Read the prompt template
    PROMPT=$(cat "$SCRIPT_DIR/prompt.md")

    # Run copilot with the prompt
    # Using -p for programmatic mode and --allow-all-tools for autonomous operation
    OUTPUT=$(copilot -p "$PROMPT" --allow-all-tools 2>&1 | tee /dev/stderr) || true

    # Check for completion signal
    if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
        echo ""
        echo -e "${GREEN}----------------------------${NC}"
        echo -e "${GREEN}Ralph completed all tasks!${NC}"
        echo -e "${GREEN}Finished at iteration $i${NC}"
        echo -e "${GREEN}----------------------------${NC}"
        echo ""
        exit 0
    fi

    echo ""
    echo -e "${YELLOW}Iteration $i complete. Continuing...${NC}"
    echo ""
    sleep 2
done

echo ""
echo -e "${RED}----------------------------${NC}"
echo -e "${RED}Ralph reached max iterations ($MAX_ITERATIONS)${NC}"
echo -e "${RED}Check $PROGRESS_FILE for status${NC}"
echo -e "${RED}----------------------------${NC}"
echo ""
exit 1
