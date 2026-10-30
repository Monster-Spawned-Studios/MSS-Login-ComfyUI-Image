#!/bin/bash
set -e

# ============================================================
# Download custom ComfyUI nodes from Git repositories
# ============================================================
# Reads URLs from custom-nodes.txt (or CUSTOM_NODES_TO_DOWNLOAD).
#
# Line format:
#   <git-url>
#   <git-url>@<ref>
#
# When @<ref> is present, resolution order is:
#   1. Tag named <ref>
#   2. Branch named <ref>
#   3. Repository default (current HEAD)
#
# Examples:
#   https://github.com/user/ComfyUI-AwesomeNode
#   https://github.com/user/ComfyUI-AwesomeNode@v1.2.0
#   https://github.com/user/ComfyUI-AwesomeNode@main
#   https://gitea.example.com/user/ComfyUI-Node@release
# ============================================================

CUSTOM_NODES_DIR="${COMFYUI_CUSTOM_NODES_DIR:-${CUSTOM_NODES_DIR:-/app/ComfyUI/custom_nodes}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST_FILE="${SCRIPT_DIR}/custom-nodes.txt"

echo "[Nodes] Custom nodes directory: $CUSTOM_NODES_DIR"
mkdir -p "$CUSTOM_NODES_DIR"

# Also support environment variable (comma or newline separated)
if [ -n "$CUSTOM_NODES_TO_DOWNLOAD" ]; then
    echo "$CUSTOM_NODES_TO_DOWNLOAD" | tr ',' '\n' > /tmp/custom_nodes_env.txt
    LIST_FILE="/tmp/custom_nodes_env.txt"
fi

if [ ! -f "$LIST_FILE" ]; then
    echo "[Nodes] No custom-nodes.txt found and CUSTOM_NODES_TO_DOWNLOAD not set. Skipping."
    exit 0
fi

if ! command -v git &> /dev/null; then
    echo "[Nodes] ERROR: git is not installed. Cannot download custom nodes."
    exit 1
fi

echo "[Nodes] Processing download list from: $LIST_FILE"
echo "------------------------------------------------------------"

# Returns 0 if the URL looks like a usable Git remote
is_valid_git_url() {
    local url="$1"
    # https://, http://, git://, ssh://host/...
    if [[ "$url" =~ ^(https?|git|ssh)://.+ ]]; then
        return 0
    fi
    # scp-style: git@host:owner/repo(.git)
    if [[ "$url" =~ ^git@[^[:space:]]+:[^[:space:]]+ ]]; then
        return 0
    fi
    return 1
}

# Derive a folder name from the repository URL
repo_dirname() {
    local url="$1"
    local name
    # Strip trailing slashes and optional .git
    url="${url%/}"
    name=$(basename "$url")
    name="${name%.git}"
    echo "$name"
}

# Parse "url" or "url@ref" into REPO_URL and REF (REF may be empty).
# Uses the last '@' so scp-style git@host:path@ref still works.
parse_node_line() {
    local line="$1"
    REPO_URL=""
    REF=""

    if [[ "$line" == *"@"* ]]; then
        # scp-style without a ref: git@host:owner/repo — only one '@', after "git"
        if [[ "$line" =~ ^git@[^@]+:[^@]+$ ]]; then
            REPO_URL="$line"
            REF=""
        else
            REF="${line##*@}"
            REPO_URL="${line%@*}"
        fi
    else
        REPO_URL="$line"
        REF=""
    fi
}

# Clone (or update) a node into CUSTOM_NODES_DIR/<name>
install_node() {
    local repo_url="$1"
    local ref="$2"
    local dest_name
    local dest
    local cloned=false

    dest_name=$(repo_dirname "$repo_url")
    if [ -z "$dest_name" ] || [ "$dest_name" = "/" ] || [ "$dest_name" = "." ]; then
        echo "  ⚠ Could not derive a directory name from: $repo_url"
        return 1
    fi

    dest="$CUSTOM_NODES_DIR/$dest_name"

    if [ -d "$dest/.git" ]; then
        echo "  Already present: $dest_name — updating..."
        (
            cd "$dest"
            git fetch --tags --prune --force 2>/dev/null || true
            if [ -n "$ref" ]; then
                checkout_ref "$ref"
            else
                # Stay on current branch; pull if tracking is set
                git pull --ff-only 2>/dev/null || true
            fi
        ) || echo "  ⚠ Update/checkout failed for $dest_name (leaving as-is)"
        return 0
    fi

    if [ -d "$dest" ]; then
        echo "  ⚠ Directory exists but is not a Git repo: $dest — skipping"
        return 1
    fi

    if [ -z "$ref" ]; then
        echo "  Cloning default HEAD → $dest_name"
        if git clone --depth 1 "$repo_url" "$dest"; then
            cloned=true
        fi
    else
        # 1) Prefer tag
        echo "  Trying tag: $ref"
        if git ls-remote --exit-code --tags "$repo_url" "refs/tags/${ref}" >/dev/null 2>&1; then
            echo "  ✓ Found tag '$ref' — cloning"
            if git clone --depth 1 --branch "$ref" "$repo_url" "$dest"; then
                cloned=true
            fi
        fi

        # 2) Then branch
        if [ "$cloned" = false ]; then
            echo "  Trying branch: $ref"
            if git ls-remote --exit-code --heads "$repo_url" "refs/heads/${ref}" >/dev/null 2>&1; then
                echo "  ✓ Found branch '$ref' — cloning"
                if git clone --depth 1 --branch "$ref" "$repo_url" "$dest"; then
                    cloned=true
                fi
            fi
        fi

        # 3) Fall back to repository default
        if [ "$cloned" = false ]; then
            echo "  ⚠ Ref '$ref' not found as tag or branch — cloning repository default"
            if git clone --depth 1 "$repo_url" "$dest"; then
                cloned=true
            fi
        fi
    fi

    if [ "$cloned" = true ]; then
        echo "  ✓ Installed → $dest"
        return 0
    fi

    echo "  ⚠ Failed to clone $repo_url"
    rm -rf "$dest" 2>/dev/null || true
    return 1
}

# Checkout tag → branch → leave current (for existing clones)
checkout_ref() {
    local ref="$1"

    # Tag
    if git rev-parse "refs/tags/${ref}" >/dev/null 2>&1; then
        echo "  ✓ Checking out tag: $ref"
        git checkout -f "tags/${ref}" 2>/dev/null || git checkout -f "$ref"
        return 0
    fi
    if git fetch --depth 1 origin "refs/tags/${ref}:refs/tags/${ref}" 2>/dev/null; then
        echo "  ✓ Checking out fetched tag: $ref"
        git checkout -f "tags/${ref}" 2>/dev/null || git checkout -f "$ref"
        return 0
    fi

    # Branch
    if git show-ref --verify --quiet "refs/heads/${ref}" || \
       git show-ref --verify --quiet "refs/remotes/origin/${ref}"; then
        echo "  ✓ Checking out branch: $ref"
        git checkout -f "$ref" 2>/dev/null || git checkout -B "$ref" "origin/$ref"
        return 0
    fi
    if git fetch --depth 1 origin "${ref}:${ref}" 2>/dev/null; then
        echo "  ✓ Checking out fetched branch: $ref"
        git checkout -f "$ref"
        return 0
    fi

    echo "  ⚠ Ref '$ref' not found as tag or branch — leaving repository at current state"
    return 0
}

while IFS= read -r line || [ -n "$line" ]; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    line=$(echo "$line" | xargs)  # trim whitespace
    [[ -z "$line" ]] && continue

    parse_node_line "$line"

    echo "[Nodes] Source: $REPO_URL"
    if [ -n "$REF" ]; then
        echo "         Ref:    $REF (tag → branch → default)"
    else
        echo "         Ref:    (repository default)"
    fi

    if ! is_valid_git_url "$REPO_URL"; then
        echo "  ⚠ Not a valid Git repository URL — skipping: $REPO_URL"
        echo "------------------------------------------------------------"
        continue
    fi

    install_node "$REPO_URL" "$REF" || true

    echo "------------------------------------------------------------"
done < "$LIST_FILE"

echo "[Nodes] Finished processing custom node list."
