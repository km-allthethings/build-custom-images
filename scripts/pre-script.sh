#!/bin/bash
echo "Workflow running on ref: ${GITHUB_REF}"

# Source environment variables from runner.env
if [ -f "/opt/runner.env" ]; then
    source /opt/runner.env
    echo "Loaded variables from /opt/runner.env"
else
    echo "Error: /opt/runner.env not found"
    exit 1
fi

# Define the output directory for downloaded workflow files
WORKFLOW_DIR=".github/workflows"
mkdir -p "$WORKFLOW_DIR"

# GitHub App credentials - sourced from runner.env
# Exit if required variables are not set
if [ -z "$APP_ID" ] || [ -z "$INSTALLATION_ID" ] || [ -z "$PRIVATE_KEY_PATH" ]; then
    echo "Error: Required environment variables (APP_ID, INSTALLATION_ID, PRIVATE_KEY_PATH) not set"
    exit 1
fi

# Create JWT header and payload
now=$(date +%s)
iat=$((${now} - 60)) # Issues 60 seconds in the past
exp=$((${now} + 600)) # Expires 10 minutes in the future
b64enc() { openssl base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n'; }
header_json='{
    "typ":"JWT",
    "alg":"RS256"
}'
# Header encode
header=$( echo -n "${header_json}" | b64enc )

payload_json="{
    \"iat\":${iat},
    \"exp\":${exp},
    \"iss\":\"${APP_ID}\"
}"
# Payload encode
payload=$( echo -n "${payload_json}" | b64enc )

# Signature
header_payload="${header}"."${payload}"
signature=$(
    openssl dgst -sha256 -sign "$PRIVATE_KEY_PATH" \
    <(echo -n "${header_payload}") | b64enc
)
# Create JWT
JWT="${header_payload}"."${signature}"

# Get installation token using JWT
response=$(curl --request POST -sL \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens")

# Get token and use it for API calls
AUTH_TOKEN=$(echo "$response" | jq -r '.token')

# (Assuming response from the actions runs API was already obtained)
response=$(curl -sL \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${AUTH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}")

# Extract the referenced_workflows JSON object (assumed to be an array of objects)
workflow_path=$(echo "$response" | jq -r '.path')
referenced_workflows=$(echo "$response" | jq '.referenced_workflows')
echo "Referenced workflows object: $referenced_workflows"

# Strip off everything after the '@' from GITHUB_WORKFLOW_REF to get the workflow file path
workflow_file="${workflow_path%%@*}"
echo "Primary workflow file: ${workflow_file}"

# Download the primary workflow file into WORKFLOW_DIR
curl -sL \
  -H "Accept: application/vnd.github.raw+json" \
  -H "Authorization: Bearer ${AUTH_TOKEN}" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/contents/${workflow_file}?ref=${GITHUB_WORKFLOW_SHA}" \
  -o "$WORKFLOW_DIR/$(basename "$workflow_file")"

mapping_json="{}"
mapping_json=$(jq --arg file "$(basename "$workflow_file")" --arg repo "$GITHUB_REPOSITORY" '. + {($file): $repo}' <<< "$mapping_json")

# Download additional files specified in referenced_workflows (if any)
workflow_count=$(echo "$referenced_workflows" | jq 'length')
if [ "$workflow_count" -eq 0 ]; then
  echo "No referenced workflows to download."
else
  for row in $(echo "$referenced_workflows" | jq -c '.[]'); do
      full_path=$(echo "$row" | jq -r '.path')
      GITHUB_LOCATION="${full_path%%/.github*}"
      workflow_path="${full_path%%@*}"
      WF_PART="${workflow_path#${GITHUB_LOCATION}/.github/}"
      referenced_workflow_path=".github/${WF_PART}"
      echo "Workflow path: $workflow_path"
      file_ref=$(echo "$row" | jq -r '.ref // empty')
      mapping_json=$(jq --arg file "$(basename "${referenced_workflow_path}")" --arg loc "$GITHUB_LOCATION" '. + {($file): $loc}' <<< "$mapping_json")

      echo "Downloading referenced file: $workflow_path (ref: $file_ref)"
      curl -sL \
        -H "Accept: application/vnd.github.raw+json" \
        -H "Authorization: Bearer ${AUTH_TOKEN}" \
        "https://api.github.com/repos/${GITHUB_LOCATION}/contents/${referenced_workflow_path}?ref=${file_ref}" \
        -o "${WORKFLOW_DIR}/$(basename "${referenced_workflow_path}")"
  done
fi

echo "Download of workflow files complete."

# ----- Security Check on Downloaded Workflows -----
# Define suspicious patterns to look for in workflow files
SUSPICIOUS_PATTERNS=(
  "curl"
  "wget"
  "base64.*-d"
  "eval.*\$\("
  "nc -e"
  "\.decode\("
  "rm -rf /*"
)

detected_patterns=()

# Process each file individually
while read -r file; do
  echo "Checking file: $file"
  
  # Get the mapping value for this file from mapping_json using its basename
  mapping_value=$(jq -r --arg key "$(basename "$file")" '.[$key]' <<< "$mapping_json")
  
  for pattern in "${SUSPICIOUS_PATTERNS[@]}"; do
    if grep -q -E "$pattern" "$file"; then
      echo "::error::Potential malicious pattern found: $pattern in $file"
      
      # Get matching lines for context
      matching_lines=$(grep -n -E "$pattern" "$file" | sed "s/^/Line /")
      
      # Build detection string including the mapping value
      detection="\`$pattern\` found in \`$file\` (from: \`$mapping_value\`)"
      
      detected_patterns+=("$detection")
    fi
  done
done < <(find "$WORKFLOW_DIR" -type f)

echo "Completed security scan of all files"
echo "Number of detections: ${#detected_patterns[@]}"

if [ ${#detected_patterns[@]} -gt 0 ]; then
    echo "Found ${#detected_patterns[@]} suspicious patterns"
    ref="${GITHUB_REF##*/}"
    title="Security Alert on \`${ref}\`: Suspicious patterns found in workflow files"
    
    issue_body=$(cat <<EOF
The following potential malicious patterns were detected in the workflow files:

$(for det in "${detected_patterns[@]}"; do
    echo "- $det"
done)

Please review immediately.
EOF
    )
    
    issue_json=$(jq -n --arg title "$title" --arg body "$issue_body" \
      '{title: $title, body: $body, labels: ["bug"], assignees: ["katiem0"]}')

    echo "Creating GitHub issue with the following payload:"
    echo "$issue_json" | jq .

    curl -s -X POST -H "Accept: application/vnd.github.v3+json" \
      -H "Authorization: Bearer ${AUTH_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$issue_json" \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues" > /dev/null 2>&1
                  
    echo "Cancelling workflow for security reasons."
    exit 1
fi

echo "Security check passed. The workflow files appear safe."
echo "sleeping for 5 minutes to test billing"
sleep 300
