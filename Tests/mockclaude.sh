#!/bin/bash
# Stand-in for the `claude` command, for the Claude Code provider tests: reads the prompt on stdin like `claude -p`.
in=$(cat); model=""; effort=""; tools="x"; allowed="none"
while [ $# -gt 0 ]; do case "$1" in --model) model=$2;; --effort) effort=$2;; --tools) tools=$2;; --allowedTools|--allowed-tools|--add-dir) allowed=$2;; esac; shift; done
case "$in" in
  *"Pictures the user attached"*) echo "picture tools=$tools allowed=$allowed folder=$(basename "$PWD") files=$(ls | tr '\n' ' ')" ;;
  *"Tool result (calculate)"*) echo "17 times 23 is 391." ;;
  *"17 times 23"*) echo "Let me work that out."; echo 'TOOL {"name": "calculate", "args": {"expression": "17*23"}}' ;;
  *) echo "hello from stand-in model=$model effort=$effort tools=$tools" ;;
esac
