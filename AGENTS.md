# Agent Instructions

This repository contains Ralph for GitHub Copilot CLI - an autonomous AI agent loop.

## Project Structure

```
.
├── ralph.sh          # Main loop script
├── prompt.md         # Instructions for each Copilot iteration
├── prd.json.example  # Example PRD format
├── README.md         # User documentation
└── AGENTS.md         # This file
```

## Commands

```bash
# Run Ralph with default 10 iterations
./ralph.sh

# Run with custom max iterations
./ralph.sh 25

# Check story status
cat prd.json | jq '.userStories[] | {id, title, passes}'

# View progress log
cat progress.txt
```

## How It Works

1. `ralph.sh` runs a bash loop
2. Each iteration calls: `copilot -p "$PROMPT" --allow-all-tools`
3. Copilot reads `prd.json` and `progress.txt` for context
4. Copilot implements one story, commits, updates `prd.json`
5. Loop checks for `<promise>COMPLETE</promise>` to exit
6. Otherwise, next iteration picks up remaining work

## Key Files Created During Runs

| File | Purpose |
|------|---------|
| `prd.json` | User's PRD with stories (copy from prd.json.example) |
| `progress.txt` | Append-only log of learnings |
| `.ralph-last-branch` | Tracks branch for archiving |
| `archive/` | Previous runs archived here |

## Modifying This Project

- **prompt.md**: Edit to customize agent behavior, add project-specific commands
- **ralph.sh**: Modify loop logic, add pre/post hooks
- **prd.json.example**: Update template for your use cases

## Patterns

- Each iteration is a fresh Copilot instance with clean context
- Memory persists only via: git history, `progress.txt`, `prd.json`
- Stories should be small enough to complete in one context window
- Always update progress.txt with learnings for future iterations
