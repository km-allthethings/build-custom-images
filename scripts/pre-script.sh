#!/bin/bash
echo "Workflow running on ref: ${GITHUB_REF}"

echo "Adding a 10-minute wait period..."
echo "Start time: $(date)"
sleep 600  # Sleep for 600 seconds (10 minutes)
echo "Wait complete at: $(date)"
