#!/usr/bin/env bash

# This script is designed to be run as an early step in a GitHub Actions workflow.
# It checks the workflow file name and cancels the workflow if it is not
# 'dynamic/copilot-swe-agent/copilot' and '.github/workflows/copilot-setup-steps' are the valid workflows
# Extensive debugging output is provided to help discover available context.

# echo "=== DEBUG: Printing All Environment Variables ==="
# env | sort
# echo "=== END ENV ==="
# echo

# echo "=== DEBUG: Key GitHub Environment Variables ==="
# for var in \
#   GITHUB_WORKFLOW \
#   GITHUB_WORKFLOW_REF \
#   GITHUB_RUN_ID \
#   GITHUB_RUN_NUMBER \
#   GITHUB_ACTION \
#   GITHUB_ACTION_PATH \
#   GITHUB_ACTION_REPOSITORY \
#   GITHUB_EVENT_NAME \
#   GITHUB_EVENT_PATH \
#   GITHUB_SHA \
#   GITHUB_REF \
#   GITHUB_REPOSITORY \
#   GITHUB_ACTOR \
#   GITHUB_HEAD_REF \
#   GITHUB_BASE_REF \
#   RUNNER_NAME
# do
#   echo "$var=${!var}"
# done
# echo "=== END KEY ENV ==="
# echo

# Attempt to determine workflow file path
workflowFilePath=""

if [ -n "$GITHUB_WORKFLOW_REF" ]; then
  # Two possible formats for workflows:
  # 1. Dynamic: ${owner}/${repo}/dynamic/copilot-swe-agent/copilot@refs...
  # 2. Standard: ${owner}/${repo}/.github/workflows/copilot-setup-steps.yml@refs...
  # Format: owner/repo/path/to/workflow@ref
  # Extract the workflow path by removing the @ref suffix and the owner/repo prefix
  workflowRefWithoutSuffix="${GITHUB_WORKFLOW_REF%@*}"
  # Remove owner/repo/ prefix (first two path components)
  workflowFilePath="${workflowRefWithoutSuffix#*/}"
  workflowFilePath="${workflowFilePath#*/}"
fi

echo "=== DEBUG: Workflow file path detected ==="
echo "workflowFilePath='$workflowFilePath'"
echo "=== END WORKFLOW FILE PATH ==="
echo

# List of allowed workflow paths (without .yml/.yaml extension)
allowedPaths=(
  "dynamic/copilot-swe-agent/copilot"
  ".github/workflows/copilot-setup-steps"
)

shortenedPath="${workflowFilePath%.yml}"
shortenedPath="${shortenedPath%.yaml}"

# Check if the workflow path is in the allowed list
allowed=false
for path in "${allowedPaths[@]}"; do
  if [[ "$shortenedPath" == "$path" ]]; then
    allowed=true
    break
  fi
done

if [[ "$allowed" != "true" ]]; then
  echo "ERROR: This runner is only for Copilot Coding Agent, please select another runner for your workflow." >&2
  echo "Workflow file: $workflowFilePath"
  exit 1
fi

echo "Workflow file path allowed. Proceeding."
