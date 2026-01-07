#!/bin/bash
#=============================================================================
# GitButler Branch Deletion Handler
#=============================================================================
# Handles edge cases when deleting GitButler branches, including:
# - "anonymous segment" errors (branch has commits)
# - Conflicted branches
# - Branches blocking worktree operations
#
# Usage:
#   ./scripts/but-delete-branch.sh <branch-name>
#   ./scripts/but-delete-branch.sh --all-unapplied
#   ./scripts/but-delete-branch.sh --list
#
# Strategy for "anonymous segment" errors:
# 1. Try direct delete with --force
# 2. If fails, try squashing commits first (but rub)
# 3. If conflicted, warn user to use GUI
#=============================================================================

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <branch-name> | --all-unapplied | --list"
    exit 1
fi

delete_branch() {
    local branch="$1"
    echo "Attempting to delete: $branch"

    # First try: direct delete
    if but branch delete "$branch" --force 2>/dev/null; then
        echo "  ✓ Deleted successfully"
        return 0
    fi

    echo "  Direct delete failed, checking for commits..."

    # Check if branch has commits (look for commit hashes in branch show)
    if but branch show "$branch" 2>/dev/null | grep -qE "^[a-f0-9]{7}"; then
        echo "  Branch has commits, attempting to squash..."

        # Get the first commit hash
        commit=$(but branch show "$branch" 2>/dev/null | grep -oE "^[a-f0-9]{7}" | head -1)

        if [ -n "$commit" ]; then
            # Try to squash
            if but rub "$commit" "$branch" 2>/dev/null; then
                echo "  Squashed commits, retrying delete..."
                if but branch delete "$branch" --force 2>/dev/null; then
                    echo "  ✓ Deleted after squash"
                    return 0
                fi
            fi
        fi
    fi

    # Check if conflicted
    if but branch show "$branch" 2>/dev/null | grep -qi "conflict"; then
        echo "  ✗ Branch is conflicted - use GitButler GUI to resolve"
        return 1
    fi

    echo "  ✗ Could not delete branch - may need manual intervention"
    return 1
}

case "$1" in
    --list)
        echo "Unapplied branches:"
        but branch list 2>/dev/null | grep -E "^\s+[a-zA-Z]" | awk '{print "  " $1}' || echo "  (none)"
        ;;

    --all-unapplied)
        echo "Deleting all unapplied branches..."
        echo ""

        # Get unapplied branches (indented in listing, not applied)
        branches=$(but branch list 2>/dev/null | grep -E "^\s+[a-zA-Z]" | awk '{print $1}' || true)

        if [ -z "$branches" ]; then
            echo "No unapplied branches to delete."
            exit 0
        fi

        for branch in $branches; do
            delete_branch "$branch" || true
            echo ""
        done

        echo "Done."
        ;;

    *)
        delete_branch "$1"
        ;;
esac
