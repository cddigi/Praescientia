#!/bin/bash
#=============================================================================
# GitButler Workspace Cleanup Automation
#=============================================================================
# "Violence is the last refuge of the incompetent." - Salvor Hardin
#
# Instead of manually running cleanup commands repeatedly, automate them.
#
# Usage:
#   ./scripts/but-cleanup.sh [--dry-run] [--unapply] [--sync] [--all]
#
# Options:
#   --dry-run   Show what would be done without executing
#   --unapply   Unapply all branches (clean slate)
#   --sync      Sync with upstream (but base update)
#   --all       Run full cleanup: unapply + sync + reset
#=============================================================================

set -e

DRY_RUN=false
DO_UNAPPLY=false
DO_SYNC=false
DO_ALL=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --unapply) DO_UNAPPLY=true ;;
        --sync) DO_SYNC=true ;;
        --all) DO_ALL=true ;;
        -h|--help)
            echo "GitButler Workspace Cleanup"
            echo ""
            echo "Usage: $0 [--dry-run] [--unapply] [--sync] [--all]"
            echo ""
            echo "Options:"
            echo "  --dry-run   Show what would be done"
            echo "  --unapply   Unapply all applied branches"
            echo "  --sync      Sync base with upstream"
            echo "  --all       Full cleanup (unapply + sync + reset)"
            exit 0
            ;;
    esac
done

run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] $*"
    else
        echo "[RUNNING] $*"
        eval "$*"
    fi
}

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  GitButler Workspace Cleanup                                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Show current status
echo "Current status:"
but status
echo ""

if [ "$DO_ALL" = true ] || [ "$DO_UNAPPLY" = true ]; then
    echo "── Unapplying all branches ──"

    # Get list of applied branches (those with ├ or ╰ prefix, not unapplied)
    branches=$(but branch list 2>/dev/null | grep -E "^[├╰]" | awk '{print $2}' | grep -v "^\[" || true)

    if [ -z "$branches" ]; then
        echo "No applied branches to unapply."
    else
        for branch in $branches; do
            echo "Unapplying: $branch"
            run_cmd "but branch unapply '$branch' --force" || echo "  (failed, may already be unapplied)"
        done
    fi
    echo ""
fi

if [ "$DO_ALL" = true ] || [ "$DO_SYNC" = true ]; then
    echo "── Syncing with upstream ──"

    # Check for blocking local changes
    if git status --porcelain | grep -q .; then
        echo "Local changes detected, stashing..."
        run_cmd "git stash push -m 'but-cleanup auto-stash'"
    fi

    run_cmd "but base update" || echo "Base update failed (may already be synced)"
    echo ""
fi

if [ "$DO_ALL" = true ]; then
    echo "── Resetting local changes ──"
    run_cmd "git checkout -- ." || true
    echo ""
fi

echo "── Final status ──"
but status

echo ""
echo "Cleanup complete."
