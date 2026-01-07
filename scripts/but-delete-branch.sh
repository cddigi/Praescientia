#!/bin/bash
#=============================================================================
# but-delete-branch.sh - Delete GitButler branch handling edge cases
#=============================================================================
# "It pays to be obvious, especially if you have a reputation for subtlety."
# - Salvor Hardin
#
# Handles the "anonymous segment" error by squashing commits before deletion.
#
# Usage:
#   ./scripts/but-delete-branch.sh <branch-name>
#   ./scripts/but-delete-branch.sh --all-unapplied
#
# Returns: SUCCESS or FAIL
#=============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

BRANCH_NAME="${1:-}"
DELETE_ALL_UNAPPLIED=false

if [[ "$1" == "--all-unapplied" ]]; then
    DELETE_ALL_UNAPPLIED=true
fi

if [[ -z "$BRANCH_NAME" ]] && ! $DELETE_ALL_UNAPPLIED; then
    echo "Usage: $0 <branch-name> | --all-unapplied"
    exit 1
fi

#-----------------------------------------------------------------------------
# Get commits in a branch
#-----------------------------------------------------------------------------
get_branch_commits() {
    local branch="$1"
    but branch show "$branch" 2>/dev/null | grep -E "^[a-f0-9]{7}" | awk '{print $1}' || echo ""
}

#-----------------------------------------------------------------------------
# Check if branch is applied
#-----------------------------------------------------------------------------
is_branch_applied() {
    local branch="$1"
    but branch list --json 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); applied=[h['name'] for s in d.get('appliedStacks',[]) for h in s.get('heads',[])]; print('yes' if '$branch' in applied else 'no')" 2>/dev/null
}

#-----------------------------------------------------------------------------
# Delete a single branch with all edge case handling
#-----------------------------------------------------------------------------
delete_branch() {
    local branch="$1"
    log_info "Attempting to delete: $branch"

    # Try simple delete first
    if but branch delete "$branch" --force 2>/dev/null; then
        log_success "Deleted: $branch"
        return 0
    fi

    # Check if branch exists
    if ! but branch show "$branch" &>/dev/null; then
        log_info "Branch not found (may already be deleted): $branch"
        return 0
    fi

    # Get error from delete attempt
    error_output=$(but branch delete "$branch" --force 2>&1 || true)

    if echo "$error_output" | grep -q "anonymous segment"; then
        log_info "Branch has commits - applying squash strategy"

        # Ensure branch is applied
        if [[ "$(is_branch_applied "$branch")" != "yes" ]]; then
            but branch apply "$branch" 2>/dev/null || {
                log_fail "Could not apply branch: $branch"
                return 1
            }
        fi

        # Get commits
        commits=$(get_branch_commits "$branch")
        commit_count=$(echo "$commits" | wc -w | tr -d ' ')

        if [[ "$commit_count" -eq 0 ]]; then
            # No commits, should be deletable now
            if but branch delete "$branch" --force 2>/dev/null; then
                log_success "Deleted empty branch: $branch"
                return 0
            fi
        fi

        if [[ "$commit_count" -eq 1 ]]; then
            log_info "Single commit - need temp branch strategy"

            # Create temp branch if doesn't exist
            but branch new "__temp_delete_$$" 2>/dev/null || true

            # Move commit to temp branch
            commit=$(echo "$commits" | head -1)
            if but rub "$commit" "__temp_delete_$$" 2>/dev/null; then
                # Now delete original branch
                if but branch delete "$branch" --force 2>/dev/null; then
                    log_success "Deleted: $branch (via temp branch)"
                    # Clean up temp branch
                    but branch unapply "__temp_delete_$$" --force 2>/dev/null || true
                    return 0
                fi
            fi
        fi

        if [[ "$commit_count" -gt 1 ]]; then
            log_info "Multiple commits ($commit_count) - squashing first"

            # Squash from bottom to top
            commit_array=($commits)
            while [[ "${#commit_array[@]}" -gt 1 ]]; do
                # Get last two commits (bottom-most)
                len=${#commit_array[@]}
                bottom="${commit_array[$len-1]}"
                next="${commit_array[$len-2]}"

                if but rub "$bottom" "$next" 2>/dev/null; then
                    log_info "Squashed $bottom -> $next"
                    # Refresh commit list
                    commits=$(get_branch_commits "$branch")
                    commit_array=($commits)
                else
                    log_fail "Squash failed - branch may have conflicts"
                    return 1
                fi
            done

            # Now have single commit, use temp branch strategy
            commit=$(echo "$commits" | head -1)
            but branch new "__temp_delete_$$" 2>/dev/null || true

            if but rub "$commit" "__temp_delete_$$" 2>/dev/null; then
                if but branch delete "$branch" --force 2>/dev/null; then
                    log_success "Deleted: $branch (after squash)"
                    but branch unapply "__temp_delete_$$" --force 2>/dev/null || true
                    return 0
                fi
            fi
        fi

        log_fail "Could not delete: $branch (complex state)"
        return 1

    elif echo "$error_output" | grep -q "conflicted"; then
        log_fail "Branch has conflicts - requires manual resolution: $branch"
        return 1
    else
        log_fail "Unknown error deleting: $branch"
        echo "$error_output"
        return 1
    fi
}

#-----------------------------------------------------------------------------
# Delete all unapplied branches
#-----------------------------------------------------------------------------
delete_all_unapplied() {
    log_info "Deleting all unapplied branches..."

    branches=$(but branch list --json 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join([b['name'] for b in d.get('branches',[])]))" 2>/dev/null || echo "")

    if [[ -z "$branches" ]]; then
        log_success "No unapplied branches to delete"
        return 0
    fi

    success_count=0
    fail_count=0

    for branch in $branches; do
        if delete_branch "$branch"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done

    echo ""
    echo "Results: $success_count deleted, $fail_count failed"

    if [[ "$fail_count" -gt 0 ]]; then
        return 1
    fi
    return 0
}

#-----------------------------------------------------------------------------
# Main
#-----------------------------------------------------------------------------
main() {
    echo "=============================================="
    echo "  GitButler Branch Deletion"
    echo "=============================================="

    if $DELETE_ALL_UNAPPLIED; then
        delete_all_unapplied
    else
        delete_branch "$BRANCH_NAME"
    fi

    result=$?

    echo ""
    if [[ $result -eq 0 ]]; then
        log_success "OPERATION COMPLETE"
    else
        log_fail "OPERATION FAILED"
    fi

    exit $result
}

main
