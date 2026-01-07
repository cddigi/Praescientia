#!/bin/bash
#=============================================================================
# but-cleanup.sh - GitButler Workspace Cleanup Automation
#=============================================================================
# "Violence is the last refuge of the incompetent." - Salvor Hardin
# Translation: Automate before you brute-force.
#
# Usage:
#   ./scripts/but-cleanup.sh              # Full cleanup
#   ./scripts/but-cleanup.sh --dry-run    # Show what would be done
#   ./scripts/but-cleanup.sh --unapply    # Only unapply all branches
#   ./scripts/but-cleanup.sh --sync       # Only sync with upstream
#
# Returns: SUCCESS or FAIL with details
#=============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

DRY_RUN=false
UNAPPLY_ONLY=false
SYNC_ONLY=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --unapply) UNAPPLY_ONLY=true ;;
        --sync) SYNC_ONLY=true ;;
        --help|-h)
            echo "Usage: $0 [--dry-run] [--unapply] [--sync]"
            exit 0
            ;;
    esac
done

log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
log_step() { echo -e "\n${YELLOW}==>${NC} $1"; }

#-----------------------------------------------------------------------------
# Step 1: Stash local changes that block operations
#-----------------------------------------------------------------------------
stash_blocking_files() {
    log_step "Checking for blocking local changes..."

    # Common files that block GitButler operations
    BLOCKING_FILES=(".claude/settings.local.json" ".env" ".env.local")
    STASHED=()

    for file in "${BLOCKING_FILES[@]}"; do
        if [[ -f "$file" ]] && git diff --name-only | grep -q "$file"; then
            if $DRY_RUN; then
                log_info "Would stash: $file"
            else
                mv "$file" "/tmp/$(basename $file).backup.$$" 2>/dev/null && STASHED+=("$file")
                log_info "Stashed: $file"
            fi
        fi
    done

    echo "${STASHED[@]}"
}

restore_stashed_files() {
    log_step "Restoring stashed files..."

    BLOCKING_FILES=(".claude/settings.local.json" ".env" ".env.local")

    for file in "${BLOCKING_FILES[@]}"; do
        backup="/tmp/$(basename $file).backup.$$"
        if [[ -f "$backup" ]]; then
            mkdir -p "$(dirname $file)"
            mv "$backup" "$file"
            log_info "Restored: $file"
        fi
    done
}

#-----------------------------------------------------------------------------
# Step 2: Get list of applied branches
#-----------------------------------------------------------------------------
get_applied_branches() {
    but branch list --json 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join([h['name'] for s in d.get('appliedStacks',[]) for h in s.get('heads',[])]))" 2>/dev/null || echo ""
}

get_unapplied_branches() {
    but branch list --json 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join([b['name'] for b in d.get('branches',[])]))" 2>/dev/null || echo ""
}

#-----------------------------------------------------------------------------
# Step 3: Unapply all branches
#-----------------------------------------------------------------------------
unapply_all_branches() {
    log_step "Unapplying all branches..."

    branches=$(get_applied_branches)

    if [[ -z "$branches" ]]; then
        log_info "No applied branches to unapply"
        return 0
    fi

    for branch in $branches; do
        if $DRY_RUN; then
            log_info "Would unapply: $branch"
        else
            if but branch unapply "$branch" --force 2>/dev/null; then
                log_success "Unapplied: $branch"
            else
                log_fail "Could not unapply: $branch"
            fi
        fi
    done
}

#-----------------------------------------------------------------------------
# Step 4: Sync with upstream
#-----------------------------------------------------------------------------
sync_with_upstream() {
    log_step "Syncing with upstream..."

    if $DRY_RUN; then
        log_info "Would run: but base update"
        but base check 2>/dev/null || true
        return 0
    fi

    # Check for upstream changes
    check_output=$(but base check 2>&1) || true

    if echo "$check_output" | grep -q "new commits"; then
        log_info "Upstream changes detected, updating..."
        if but base update 2>/dev/null; then
            log_success "Base updated successfully"
        else
            log_fail "Base update failed"
            return 1
        fi
    else
        log_success "Already up to date with upstream"
    fi
}

#-----------------------------------------------------------------------------
# Step 5: Reset working directory to match base
#-----------------------------------------------------------------------------
reset_working_directory() {
    log_step "Resetting working directory to match base..."

    if $DRY_RUN; then
        log_info "Would reset modified/deleted files to match origin/main"
        return 0
    fi

    # Get list of files that differ from base
    changed_files=$(git diff --name-only HEAD 2>/dev/null || echo "")

    if [[ -n "$changed_files" ]]; then
        for file in $changed_files; do
            # Skip local config files
            if [[ "$file" == ".claude/"* ]] || [[ "$file" == ".env"* ]]; then
                log_info "Skipping local file: $file"
                continue
            fi

            git checkout -- "$file" 2>/dev/null && log_info "Reset: $file" || true
        done
    fi

    log_success "Working directory reset"
}

#-----------------------------------------------------------------------------
# Step 6: Report final status
#-----------------------------------------------------------------------------
report_status() {
    log_step "Final Status Report"

    echo ""
    echo "Applied branches:"
    applied=$(get_applied_branches)
    if [[ -z "$applied" ]]; then
        echo "  (none)"
    else
        echo "$applied" | sed 's/^/  /'
    fi

    echo ""
    echo "Unapplied branches:"
    unapplied=$(get_unapplied_branches)
    if [[ -z "$unapplied" ]]; then
        echo "  (none)"
    else
        echo "$unapplied" | sed 's/^/  /'
    fi

    echo ""
    but status 2>/dev/null | head -5
}

#-----------------------------------------------------------------------------
# Main
#-----------------------------------------------------------------------------
main() {
    echo "=============================================="
    echo "  GitButler Workspace Cleanup"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=============================================="

    if $DRY_RUN; then
        log_info "DRY RUN MODE - No changes will be made"
    fi

    # Trap to restore files on error
    trap restore_stashed_files EXIT

    # Stash blocking files
    stash_blocking_files

    if $SYNC_ONLY; then
        sync_with_upstream
        report_status
        echo ""
        log_success "SYNC COMPLETE"
        exit 0
    fi

    if $UNAPPLY_ONLY; then
        unapply_all_branches
        report_status
        echo ""
        log_success "UNAPPLY COMPLETE"
        exit 0
    fi

    # Full cleanup
    unapply_all_branches
    sync_with_upstream
    reset_working_directory

    # Restore stashed files before final report
    trap - EXIT
    restore_stashed_files

    report_status

    echo ""
    echo "=============================================="
    log_success "CLEANUP COMPLETE"
    echo "=============================================="
}

main "$@"
