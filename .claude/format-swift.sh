#!/bin/sh
# Hook PostToolUse: format file .swift vừa được sửa.
file=$(jq -r '.tool_input.file_path // empty')
case "$file" in
  *.swift) swift format --in-place "$file" 2>&1 || true ;;
esac
exit 0
