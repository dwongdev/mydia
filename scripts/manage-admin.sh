#!/usr/bin/env bash
# Mydia Admin Management Script
# Provides options to delete or reset the admin user password

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

show_usage() {
    cat << EOF
Mydia Admin Management Script

Usage: $0 [COMMAND]

Commands:
    delete          Delete all admin users from the database (works with OIDC and local auth)
    reset           Reset the admin password to 'admin' (local auth only)
    help            Show this help message

If no command is provided, an interactive menu will be shown.

Examples:
    $0 delete       # Delete all admin users
    $0 reset        # Reset admin password to 'admin' (for local auth admin)
    $0              # Show interactive menu

Note: For OIDC-only setups, admin users can be auto-promoted on first login.
EOF
}

delete_admin() {
    echo "🗑️  Deleting admin users..."
    ./dev mix mydia.delete_admin
}

reset_password() {
    echo "🔑 Resetting admin password to 'admin'..."
    ./dev mix mydia.reset_admin_password
}

interactive_menu() {
    echo ""
    echo "╔═══════════════════════════════════════╗"
    echo "║   Mydia Admin Management              ║"
    echo "╚═══════════════════════════════════════╝"
    echo ""
    echo "What would you like to do?"
    echo ""
    echo "  1) Delete all admin users (OIDC & local)"
    echo "  2) Reset admin password to 'admin' (local auth only)"
    echo "  3) Exit"
    echo ""
    read -p "Enter your choice [1-3]: " choice

    case $choice in
        1)
            echo ""
            delete_admin
            ;;
        2)
            echo ""
            reset_password
            ;;
        3)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo "Invalid choice. Please enter 1, 2, or 3."
            exit 1
            ;;
    esac
}

# Main script logic
case "${1:-}" in
    delete)
        delete_admin
        ;;
    reset)
        reset_password
        ;;
    help|--help|-h)
        show_usage
        ;;
    "")
        interactive_menu
        ;;
    *)
        echo "Error: Unknown command '$1'"
        echo ""
        show_usage
        exit 1
        ;;
esac
