#!/usr/bin/env bash
#
# APDF Framework Installer for Unix/Mac
# Installs the Agent Principal Development Framework to a target project directory
# with conflict detection, backup, and smart merge capabilities.
#
# Usage: ./install.sh <target-path> [--force]
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
FILES_TO_COPY=(
    "agents"
    "phases"
    "methodologies"
    "meta.json"
    "roles.json"
    "state.json"
    "state.example.json"
)

CLAUDE_COMMANDS_DIR=".claude/commands"
CLAUDE_SETTINGS_FILE=".claude/settings.json"
CLAUDE_MD_FILE=".claude/CLAUDE.md"
GITIGNORE_FILE=".gitignore.apdf"

# Globals
TARGET_PATH=""
FORCE=false
BACKUP_DIR=""
BACKUP_TIMESTAMP=$(date +%Y%m%d-%H%M%S)
CONFLICTS=()

# Helper functions
print_success() { echo -e "${GREEN}$1${NC}"; }
print_warning() { echo -e "${YELLOW}$1${NC}"; }
print_error() { echo -e "${RED}$1${NC}"; }
print_info() { echo -e "${CYAN}$1${NC}"; }

usage() {
    echo "Usage: $0 <target-path> [--force]"
    echo ""
    echo "Arguments:"
    echo "  target-path    The project directory to install APDF into"
    echo "  --force        Skip confirmation prompts"
    exit 1
}

# Check if file/dir exists in target
test_conflict() {
    local rel_path="$1"
    [[ -e "${TARGET_PATH}/${rel_path}" ]]
}

# Backup a file before modifying
backup_file() {
    local rel_path="$1"
    local source_path="${TARGET_PATH}/${rel_path}"

    [[ ! -e "$source_path" ]] && return

    local backup_path="${BACKUP_DIR}/${BACKUP_TIMESTAMP}/${rel_path}"
    local backup_folder=$(dirname "$backup_path")

    mkdir -p "$backup_folder"
    cp -r "$source_path" "$backup_path"
    print_info "  Backed up: $rel_path"
}

# Merge .gitignore (append APDF entries)
merge_gitignore() {
    local source_path="${SCRIPT_DIR}/${GITIGNORE_FILE}"
    local target_file="${TARGET_PATH}/.gitignore"

    local apdf_content=$(cat "$source_path")
    local marker=$'\n\n# === APDF Framework ==='
    local end_marker='# === End APDF Framework ==='

    if [[ -f "$target_file" ]]; then
        # Check if APDF section already exists
        if grep -q "# === APDF Framework ===" "$target_file" 2>/dev/null; then
            print_warning "  .gitignore already contains APDF section, skipping"
            return
        fi

        # Append APDF entries
        {
            echo ""
            echo ""
            echo "# === APDF Framework ==="
            cat "$source_path"
            echo "# === End APDF Framework ==="
        } >> "$target_file"
        print_success "  Merged .gitignore (appended APDF entries)"
    else
        # Create new .gitignore
        {
            echo "# === APDF Framework ==="
            cat "$source_path"
            echo "# === End APDF Framework ==="
        } > "$target_file"
        print_success "  Created .gitignore with APDF entries"
    fi
}

# Merge CLAUDE.md (append APDF section)
merge_claude_md() {
    local source_path="${SCRIPT_DIR}/${CLAUDE_MD_FILE}"
    local target_file="${TARGET_PATH}/${CLAUDE_MD_FILE}"
    local target_dir=$(dirname "$target_file")

    local marker=$'\n\n# === APDF Framework Configuration ===\n'
    local end_marker=$'\n# === End APDF Framework Configuration ==='

    if [[ -f "$target_file" ]]; then
        backup_file "$CLAUDE_MD_FILE"

        # Check if APDF section already exists
        if grep -q "# === APDF Framework Configuration ===" "$target_file" 2>/dev/null; then
            print_warning "  CLAUDE.md already contains APDF section, skipping"
            return
        fi

        # Append APDF section
        {
            echo ""
            echo ""
            echo "# === APDF Framework Configuration ==="
            echo ""
            cat "$source_path"
            echo ""
            echo "# === End APDF Framework Configuration ==="
        } >> "$target_file"
        print_success "  Merged CLAUDE.md (appended APDF configuration)"
    else
        # Create new CLAUDE.md
        mkdir -p "$target_dir"
        cp "$source_path" "$target_file"
        print_success "  Created CLAUDE.md"
    fi
}

# Merge settings.json (deep merge hooks and permissions)
merge_claude_settings() {
    local source_path="${SCRIPT_DIR}/${CLAUDE_SETTINGS_FILE}"
    local target_file="${TARGET_PATH}/${CLAUDE_SETTINGS_FILE}"
    local target_dir=$(dirname "$target_file")

    if [[ -f "$target_file" ]]; then
        backup_file "$CLAUDE_SETTINGS_FILE"

        # Check if jq is available for proper JSON merging
        if command -v jq &> /dev/null; then
            # Deep merge using jq
            local merged=$(jq -s '
                def deep_merge:
                    reduce .[] as $item ({}; . * $item);
                .[0] as $existing | .[1] as $apdf |
                {
                    hooks: {
                        PreToolUse: (($existing.hooks.PreToolUse // []) + ($apdf.hooks.PreToolUse // [])),
                        PostToolUse: (($existing.hooks.PostToolUse // []) + ($apdf.hooks.PostToolUse // [])),
                        Notification: (($existing.hooks.Notification // []) + ($apdf.hooks.Notification // []))
                    },
                    agentPrincipal: ($existing.agentPrincipal // $apdf.agentPrincipal),
                    permissions: {
                        allow: (($existing.permissions.allow // []) + ($apdf.permissions.allow // []) | unique),
                        deny: (($existing.permissions.deny // []) + ($apdf.permissions.deny // []) | unique)
                    }
                } * ($existing | del(.hooks, .agentPrincipal, .permissions))
            ' "$target_file" "$source_path" 2>/dev/null)

            if [[ -n "$merged" ]]; then
                echo "$merged" > "$target_file"
                print_success "  Merged settings.json (combined hooks and permissions)"
            else
                print_warning "  Could not merge settings.json, backing up and replacing"
                cp "$source_path" "$target_file"
            fi
        else
            # No jq available, just replace with warning
            print_warning "  jq not found - replacing settings.json (backup created)"
            cp "$source_path" "$target_file"
        fi
    else
        # Create new settings.json
        mkdir -p "$target_dir"
        cp "$source_path" "$target_file"
        print_success "  Created settings.json"
    fi
}

# Copy APDF command files
copy_claude_commands() {
    local source_dir="${SCRIPT_DIR}/${CLAUDE_COMMANDS_DIR}"
    local target_dir="${TARGET_PATH}/${CLAUDE_COMMANDS_DIR}"

    mkdir -p "$target_dir"

    local copied=0
    local skipped=0

    for file in "$source_dir"/APDF_*.md; do
        [[ ! -f "$file" ]] && continue

        local filename=$(basename "$file")
        local target_file="${target_dir}/${filename}"

        if [[ -f "$target_file" ]]; then
            if [[ "$FORCE" != true ]]; then
                print_warning "  Command exists: $filename (skipped)"
                ((skipped++))
                continue
            fi
            backup_file "${CLAUDE_COMMANDS_DIR}/${filename}"
        fi

        cp "$file" "$target_file"
        ((copied++))
    done

    local msg="  Copied $copied command files"
    [[ $skipped -gt 0 ]] && msg+=", skipped $skipped existing"
    print_success "$msg"
}

# Copy framework files
copy_framework_files() {
    for item in "${FILES_TO_COPY[@]}"; do
        local source_path="${SCRIPT_DIR}/${item}"
        local target_path="${TARGET_PATH}/${item}"

        if [[ -d "$source_path" ]]; then
            # Directory
            if [[ -d "$target_path" ]]; then
                [[ "$FORCE" != true ]] && print_warning "  Directory exists: $item (merging contents)"
            fi

            mkdir -p "$target_path"
            cp -r "$source_path"/* "$target_path/"
            print_success "  Copied directory: $item"
        else
            # File
            if [[ -f "$target_path" ]]; then
                backup_file "$item"
            fi
            cp "$source_path" "$target_path"
            print_success "  Copied file: $item"
        fi
    done
}

# Main installation flow
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                FORCE=true
                shift
                ;;
            --help|-h)
                usage
                ;;
            *)
                if [[ -z "$TARGET_PATH" ]]; then
                    TARGET_PATH="$1"
                else
                    print_error "Unknown argument: $1"
                    usage
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$TARGET_PATH" ]]; then
        print_error "Error: Target path is required"
        usage
    fi

    # Resolve to absolute path
    TARGET_PATH=$(cd "$TARGET_PATH" 2>/dev/null && pwd) || {
        print_error "Error: Target path does not exist: $TARGET_PATH"
        exit 1
    }

    BACKUP_DIR="${TARGET_PATH}/.apdf-backup"

    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  APDF Framework Installer${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    print_info "Target: $TARGET_PATH"
    echo ""

    # Scan for conflicts
    echo -e "${YELLOW}Scanning for conflicts...${NC}"
    echo ""

    local conflict_count=0

    # Check framework files
    for item in "${FILES_TO_COPY[@]}"; do
        if test_conflict "$item"; then
            echo "  [CONFLICT] $item (will backup & replace)"
            ((conflict_count++))
        fi
    done

    # Check .claude files
    if test_conflict "$CLAUDE_MD_FILE"; then
        echo "  [CONFLICT] $CLAUDE_MD_FILE (will smart merge)"
        ((conflict_count++))
    fi

    if test_conflict "$CLAUDE_SETTINGS_FILE"; then
        echo "  [CONFLICT] $CLAUDE_SETTINGS_FILE (will smart merge)"
        ((conflict_count++))
    fi

    if test_conflict ".gitignore"; then
        echo "  [CONFLICT] .gitignore (will append)"
        ((conflict_count++))
    fi

    # Check commands
    if [[ -d "${TARGET_PATH}/${CLAUDE_COMMANDS_DIR}" ]]; then
        local cmd_conflicts=0
        for file in "$SCRIPT_DIR/$CLAUDE_COMMANDS_DIR"/APDF_*.md; do
            [[ ! -f "$file" ]] && continue
            local filename=$(basename "$file")
            if [[ -f "${TARGET_PATH}/${CLAUDE_COMMANDS_DIR}/${filename}" ]]; then
                ((cmd_conflicts++))
            fi
        done
        if [[ $cmd_conflicts -gt 0 ]]; then
            echo "  [CONFLICT] .claude/commands/APDF_*.md ($cmd_conflicts files)"
            ((conflict_count++))
        fi
    fi

    echo ""

    if [[ $conflict_count -gt 0 ]]; then
        print_warning "Found $conflict_count potential conflicts"
        echo ""

        if [[ "$FORCE" != true ]]; then
            echo -n "Continue with installation? Existing files will be backed up to .apdf-backup/ (Y/n) "
            read -r response
            if [[ "$response" =~ ^[Nn]$ ]]; then
                echo "Installation cancelled."
                exit 0
            fi
        fi
    else
        print_success "No conflicts detected!"
    fi

    echo ""
    echo -e "${CYAN}Installing APDF Framework...${NC}"
    echo ""

    # Perform installation
    copy_framework_files
    merge_gitignore
    merge_claude_md
    merge_claude_settings
    copy_claude_commands

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Installation Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""

    if [[ -d "$BACKUP_DIR" ]]; then
        print_info "Backups saved to: .apdf-backup/$BACKUP_TIMESTAMP/"
    fi

    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "  1. Open Claude Code in your project directory"
    echo "  2. Run /APDF_init for new projects"
    echo "  3. Run /APDF_onboard for existing projects"
    echo ""
}

main "$@"
