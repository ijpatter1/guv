#!/bin/bash
# .claude/hooks/auto-format.sh
# PostToolUse hook for Write/Edit/MultiEdit — formats modified files.
# Receives JSON on stdin with tool_input containing file path.
# Exit 0 = success (non-blocking).
#
# Stack-agnostic: the formatter command and the extensions it handles are read
# from the manifest (.claude/project.json), not hardcoded. This hook is already
# root-agnostic — it formats whatever path it is handed, in either repo, so no
# path logic is needed.
#
# If commands.format is null (project has no formatter), this hook exits silently.

INPUT=$(cat)

# Extract file path — different tools use different field names
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty')

if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  exit 0
fi

MANIFEST=".claude/project.json"
if [ ! -f "$MANIFEST" ]; then
  exit 0
fi

# Read the format command from the manifest. Null/absent means "no formatter."
FORMAT_CMD=$(jq -r '.commands.format // empty' "$MANIFEST")
if [ -z "$FORMAT_CMD" ]; then
  exit 0
fi

# Only format extensions the manifest declares the formatter handles.
EXT="${FILE##*.}"
MATCH=$(jq -r --arg ext "$EXT" '(.formatExtensions // []) | index($ext)' "$MANIFEST")
if [ "$MATCH" = "null" ]; then
  exit 0
fi

# Run the configured formatter against the file. Suppress all output — this hook
# should be invisible when it works and silent when it can't (e.g., the formatter
# isn't installed yet during scaffolding).
eval "$FORMAT_CMD \"$FILE\"" 2>/dev/null || true

exit 0
