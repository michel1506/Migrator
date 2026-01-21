#!/bin/bash

# Domain Migration Script
# This script copies a directory from one domain to another

# Color codes for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

show_help() {
    echo "Usage: $0 [--db-only] [--config <file>]"
    echo "  --db-only   Only migrate the database (skip file copy)"
    echo "  --config    YAML config file with migration settings"
}

DB_ONLY=false
CONFIG_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --db-only)
            DB_ONLY=true
            shift
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            print_error "Unknown argument: $1"
            show_help
            exit 1
            ;;
    esac
done

is_true() {
    case "$1" in
        true|TRUE|1|y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

ensure_yaml_available() {
    if command -v python3 >/dev/null 2>&1; then
        PYTHON_BIN="python3"
    elif command -v python >/dev/null 2>&1; then
        PYTHON_BIN="python"
    else
        print_error "Python is required to read YAML config files."
        print_info "Install Python or run without --config."
        exit 1
    fi

    if ! "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import yaml
PY
    then
        print_error "PyYAML is required to read YAML config files."
        print_info "Install it with: pip install pyyaml"
        exit 1
    fi
}

load_config() {
    local file="$1"
    if [ ! -f "$file" ]; then
        print_error "Config file not found: $file"
        exit 1
    fi
    ensure_yaml_available
    eval "$($PYTHON_BIN - "$file" <<'PY'
import sys
import yaml
import shlex

def get_path(data, path):
    cur = data
    for key in path:
        if not isinstance(cur, dict) or key not in cur:
            return None
        cur = cur[key]
    return cur

def emit(key, value):
    if value is None:
        return
    if isinstance(value, bool):
        print(f"{key}={'true' if value else 'false'}")
    else:
        print(f"{key}={shlex.quote(str(value))}")

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}

emit('CFG_SOURCE_DOMAIN', get_path(data, ['source_domain']))
emit('CFG_DEST_DOMAIN', get_path(data, ['dest_domain']))
emit('CFG_PROCEED', get_path(data, ['proceed']))

emit('CFG_DB_MIGRATE', get_path(data, ['db', 'migrate']))
emit('CFG_DB_SOURCE_FROM_ENV', get_path(data, ['db', 'source_from_env']))
emit('CFG_DB_SOURCE_HOST', get_path(data, ['db', 'source', 'host']))
emit('CFG_DB_SOURCE_PORT', get_path(data, ['db', 'source', 'port']))
emit('CFG_DB_SOURCE_NAME', get_path(data, ['db', 'source', 'name']))
emit('CFG_DB_SOURCE_USER', get_path(data, ['db', 'source', 'user']))
emit('CFG_DB_SOURCE_PASS', get_path(data, ['db', 'source', 'password']))

emit('CFG_DB_DEST_NAME', get_path(data, ['db', 'dest', 'name']))
emit('CFG_DB_DEST_HOST', get_path(data, ['db', 'dest', 'host']))
emit('CFG_DB_DEST_PORT', get_path(data, ['db', 'dest', 'port']))
emit('CFG_DB_DEST_USER', get_path(data, ['db', 'dest', 'user']))
emit('CFG_DB_DEST_PASS', get_path(data, ['db', 'dest', 'password']))
emit('CFG_DB_DROP_EXISTING', get_path(data, ['db', 'drop_existing']))

emit('CFG_DELETE_EXISTING', get_path(data, ['file_copy', 'delete_existing']))
emit('CFG_UPDATE_DOMAINS', get_path(data, ['env_update', 'update_domains']))
PY
)"
}

# Ensure required tools are available
if [ "$DB_ONLY" = false ]; then
    if ! command -v rsync >/dev/null 2>&1; then
        print_error "rsync is required for progress bars but was not found."
        print_info "Please install rsync and try again."
        exit 1
    fi
    if ! command -v pv >/dev/null 2>&1; then
        print_error "pv is required for the copy progress bar but was not found."
        print_info "Please install pv and try again."
        exit 1
    fi
fi


get_dir_size_bytes() {
    if du -sb "$1" >/dev/null 2>&1; then
        du -sb "$1" | awk '{print $1}'
    else
        du -sk "$1" | awk '{print $1 * 1024}'
    fi
}

get_env_value() {
    local key="$1"
    local file="$2"
    grep -E "^${key}=" "$file" | tail -n 1 | cut -d '=' -f2- | tr -d '"\r'
}

set_env_value() {
    local key="$1"
    local value="$2"
    local file="$3"
    if grep -q "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$file"
    else
        echo "${key}=\"${value}\"" >> "$file"
    fi
}

db_exists() {
    local host="$1"
    local port="$2"
    local user="$3"
    local pass="$4"
    local name="$5"
    mysql -h "${host:-localhost}" -P "$port" -u "$user" -p"$pass" -e "USE \`$name\`;" >/dev/null 2>&1
}

clear_database() {
    local host="$1"
    local port="$2"
    local user="$3"
    local pass="$4"
    local name="$5"

    print_info "Clearing destination database '$name'..."
    drop_sql=$(mysql -h "${host:-localhost}" -P "$port" -u "$user" -p"$pass" -N -e "SELECT CONCAT('DROP TABLE IF EXISTS \`', table_name, '\`;') FROM information_schema.tables WHERE table_schema='${name}' AND table_type IN ('BASE TABLE','VIEW');")
    if [ $? -ne 0 ]; then
        print_error "Failed to read tables from destination database."
        exit 1
    fi

    if [ -n "$drop_sql" ]; then
        echo "SET FOREIGN_KEY_CHECKS=0; $drop_sql SET FOREIGN_KEY_CHECKS=1;" | mysql -h "${host:-localhost}" -P "$port" -u "$user" -p"$pass" "$name"
        if [ $? -ne 0 ]; then
            print_error "Failed to clear destination database."
            exit 1
        fi
        print_success "Destination database cleared."
    else
        print_info "Destination database is already empty."
    fi
}

ensure_destination_db() {
    local host="$1"
    local port="$2"
    local user="$3"
    local pass="$4"
    local name="$5"

    if db_exists "$host" "$port" "$user" "$pass" "$name"; then
        clear_database "$host" "$port" "$user" "$pass" "$name"
    else
        mysql -h "${host:-localhost}" -P "$port" -u "$user" -p"$pass" -e "CREATE DATABASE \`$name\`;"
        if [ $? -ne 0 ]; then
            print_error "Failed to create destination database."
            exit 1
        fi
        print_success "Created destination database '$name'."
    fi
}

update_domain_in_env() {
    local file="$1"
    if [ -f "$file" ]; then
        print_info "Updating domain inside $file..."
        sed -i "s|$source_domain|$dest_domain|g" "$file"
        if [ $? -eq 0 ]; then
            print_success "Updated domain in $(basename "$file")."
        else
            print_error "Failed to update $(basename "$file")."
            exit 1
        fi
    fi
}

update_db_in_env() {
    local file="$1"
    if [ -f "$file" ]; then
        print_info "Updating database credentials in $file..."
        if [ -n "$dest_db_pass" ]; then
            dest_db_creds="${dest_db_user}:${dest_db_pass}"
        else
            dest_db_creds="${dest_db_user}"
        fi
        dest_db_url="mysql://${dest_db_creds}@${dest_db_host}:${dest_db_port}/${dest_db_name}"
        set_env_value "DATABASE_URL" "$dest_db_url" "$file"
        set_env_value "DB_HOST" "$dest_db_host" "$file"
        set_env_value "DB_PORT" "$dest_db_port" "$file"
        set_env_value "DB_DATABASE" "$dest_db_name" "$file"
        set_env_value "DB_USERNAME" "$dest_db_user" "$file"
        set_env_value "DB_PASSWORD" "$dest_db_pass" "$file"
        print_success "Updated database settings in $(basename "$file")."
    fi
}

parse_database_url() {
    # mysql://user:pass@host:port/db
    local url="$1"
    url="${url#*://}"
    local creds_host_db="$url"
    local creds="${creds_host_db%@*}"
    local host_db="${creds_host_db#*@}"
    local user="${creds%%:*}"
    local pass="${creds#*:}"
    local host_port="${host_db%%/*}"
    local db="${host_db#*/}"
    local host="${host_port%%:*}"
    local port="${host_port#*:}"
    if [ "$port" = "$host_port" ]; then
        port="3306"
    fi
    echo "$user|$pass|$host|$port|$db"
}

# Load config if provided
if [ -n "$CONFIG_FILE" ]; then
    load_config "$CONFIG_FILE"
fi

# Prompt for source domain
echo "==================================="
echo "   Domain Migration Tool"
echo "==================================="
echo ""
source_domain="$CFG_SOURCE_DOMAIN"
if [ -z "$source_domain" ]; then
    read -p "Enter the source domain (e.g., tt-gmbh.de): " source_domain
fi

# Validate source domain is not empty
if [ -z "$source_domain" ]; then
    print_error "Source domain cannot be empty!"
    exit 1
fi

# Check if source directory exists
if [ ! -d "$source_domain" ]; then
    print_error "Source directory '$source_domain' does not exist!"
    exit 1
fi

# Prompt for destination domain
dest_domain="$CFG_DEST_DOMAIN"
if [ -z "$dest_domain" ]; then
    read -p "Enter the destination domain (e.g., test.tt-gmbh.de): " dest_domain
fi

# Validate destination domain is not empty
if [ -z "$dest_domain" ]; then
    print_error "Destination domain cannot be empty!"
    exit 1
fi

# Check if source and destination are the same
if [ "$source_domain" = "$dest_domain" ]; then
    print_error "Source and destination domains cannot be the same!"
    exit 1
fi

# Show migration summary
echo ""
print_info "Migration Summary:"
echo "  Source:      $source_domain"
echo "  Destination: $dest_domain"
echo ""

if [ -n "$CFG_PROCEED" ]; then
    if is_true "$CFG_PROCEED"; then
        confirm="y"
    else
        confirm="n"
    fi
else
    # Ask for confirmation
    read -p "Proceed with migration? (y/n): " confirm
fi
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    print_info "Migration cancelled."
    exit 0
fi

echo ""
print_info "Starting migration..."

# Database migration (optional)
env_file=""
if [ -f "$source_domain/.env.local" ]; then
    env_file="$source_domain/.env.local"
elif [ -f "$source_domain/.env" ]; then
    env_file="$source_domain/.env"
fi

if [ -n "$env_file" ]; then
    echo ""
    if [ -n "$CFG_DB_MIGRATE" ]; then
        if is_true "$CFG_DB_MIGRATE"; then
            db_confirm="y"
        else
            db_confirm="n"
        fi
    else
        read -p "Do you want to migrate the database using $env_file? (y/n): " db_confirm
    fi
    if [ "$db_confirm" = "y" ] || [ "$db_confirm" = "Y" ]; then
        if ! command -v mysqldump >/dev/null 2>&1 || ! command -v mysql >/dev/null 2>&1; then
            print_error "mysqldump and mysql are required for database migration."
            print_info "Please install them and try again."
            exit 1
        fi

        use_env_source=false
        if [ -n "$CFG_DB_SOURCE_FROM_ENV" ]; then
            if is_true "$CFG_DB_SOURCE_FROM_ENV"; then
                use_env_source=true
            fi
        else
            read -p "Read source DB details from $env_file? (y/n): " source_env_confirm
            if [ "$source_env_confirm" = "y" ] || [ "$source_env_confirm" = "Y" ]; then
                use_env_source=true
            fi
        fi

        if [ "$use_env_source" = true ]; then
            # Read DB credentials from .env.local/.env
            db_host=$(get_env_value "DB_HOST" "$env_file")
            db_port=$(get_env_value "DB_PORT" "$env_file")
            db_name=$(get_env_value "DB_DATABASE" "$env_file")
            db_user=$(get_env_value "DB_USERNAME" "$env_file")
            db_pass=$(get_env_value "DB_PASSWORD" "$env_file")
            db_url=$(get_env_value "DATABASE_URL" "$env_file")

            if [ -n "$db_url" ] && ( [ -z "$db_user" ] || [ -z "$db_name" ] ); then
                parsed=$(parse_database_url "$db_url")
                db_user=$(echo "$parsed" | cut -d '|' -f1)
                db_pass=$(echo "$parsed" | cut -d '|' -f2)
                db_host=$(echo "$parsed" | cut -d '|' -f3)
                db_port=$(echo "$parsed" | cut -d '|' -f4)
                db_name=$(echo "$parsed" | cut -d '|' -f5)
            fi
        fi

        if [ -z "$db_port" ]; then
            db_port=3306
        fi

        if [ "$use_env_source" = false ]; then
            db_host=${CFG_DB_SOURCE_HOST:-$db_host}
            db_port=${CFG_DB_SOURCE_PORT:-$db_port}
            db_name=${CFG_DB_SOURCE_NAME:-$db_name}
            db_user=${CFG_DB_SOURCE_USER:-$db_user}
            db_pass=${CFG_DB_SOURCE_PASS:-$db_pass}
        fi

        if [ -z "$db_name" ] || [ -z "$db_user" ]; then
            print_error "Could not read DB credentials from .env."
            exit 1
        fi

        echo ""
        print_info "Database source settings:"
        echo "  Host: $db_host"
        echo "  Database: $db_name"
        echo "  User: $db_user"
        echo "  Port: $db_port"
        echo ""

        dest_db_name=${CFG_DB_DEST_NAME:-$dest_db_name}
        if [ -z "$dest_db_name" ]; then
            read -p "Enter destination database name: " dest_db_name
        fi
        if [ -z "$dest_db_name" ]; then
            print_error "Destination database name cannot be empty!"
            exit 1
        fi

        dest_db_host=${CFG_DB_DEST_HOST:-$dest_db_host}
        if [ -z "$dest_db_host" ]; then
            read -p "Enter destination DB host (default: $db_host): " dest_db_host
        fi
        dest_db_host=${dest_db_host:-$db_host}

        dest_db_port=${CFG_DB_DEST_PORT:-$dest_db_port}
        if [ -z "$dest_db_port" ]; then
            read -p "Enter destination DB port (default: $db_port): " dest_db_port
        fi
        dest_db_port=${dest_db_port:-$db_port}

        dest_db_user=${CFG_DB_DEST_USER:-$dest_db_user}
        if [ -z "$dest_db_user" ]; then
            read -p "Enter destination DB username (default: $db_user): " dest_db_user
        fi
        dest_db_user=${dest_db_user:-$db_user}

        dest_db_pass=${CFG_DB_DEST_PASS:-$dest_db_pass}
        if [ -z "$dest_db_pass" ]; then
            read -s -p "Enter destination DB password (leave empty to keep same): " dest_db_pass
            echo ""
        fi
        if [ -z "$dest_db_pass" ]; then
            dest_db_pass="$db_pass"
        fi

        ensure_destination_db "$dest_db_host" "$dest_db_port" "$dest_db_user" "$dest_db_pass" "$dest_db_name"

        print_info "Migrating database..."
        mysqldump -h "${db_host:-localhost}" -P "$db_port" -u "$db_user" -p"$db_pass" "$db_name" | mysql -h "${dest_db_host:-localhost}" -P "$dest_db_port" -u "$dest_db_user" -p"$dest_db_pass" "$dest_db_name"
        if [ $? -eq 0 ]; then
            print_success "Database migration completed successfully."
            update_db_in_env "$dest_domain/.env.local"
            update_db_in_env "$dest_domain/public/.env"
        else
            print_error "Database migration failed."
            exit 1
        fi
    fi
else
    echo ""
    print_info "No .env file found in source directory."
    if [ -n "$CFG_DB_MIGRATE" ]; then
        if is_true "$CFG_DB_MIGRATE"; then
            manual_db_confirm="y"
        else
            manual_db_confirm="n"
        fi
    else
        read -p "Do you want to enter database details manually? (y/n): " manual_db_confirm
    fi
    if [ "$manual_db_confirm" = "y" ] || [ "$manual_db_confirm" = "Y" ]; then
        if ! command -v mysqldump >/dev/null 2>&1 || ! command -v mysql >/dev/null 2>&1; then
            print_error "mysqldump and mysql are required for database migration."
            print_info "Please install them and try again."
            exit 1
        fi

        db_host=${CFG_DB_SOURCE_HOST:-$db_host}
        if [ -z "$db_host" ]; then
            read -p "Enter DB host (default: localhost): " db_host
        fi
        db_host=${db_host:-localhost}

        db_port=${CFG_DB_SOURCE_PORT:-$db_port}
        if [ -z "$db_port" ]; then
            read -p "Enter DB port (default: 3306): " db_port
        fi
        db_port=${db_port:-3306}

        db_name=${CFG_DB_SOURCE_NAME:-$db_name}
        if [ -z "$db_name" ]; then
            read -p "Enter source database name: " db_name
        fi

        db_user=${CFG_DB_SOURCE_USER:-$db_user}
        if [ -z "$db_user" ]; then
            read -p "Enter DB username: " db_user
        fi

        db_pass=${CFG_DB_SOURCE_PASS:-$db_pass}
        if [ -z "$db_pass" ]; then
            read -s -p "Enter DB password (leave empty if none): " db_pass
            echo ""
        fi

        if [ -z "$db_name" ] || [ -z "$db_user" ]; then
            print_error "Database name and username are required."
            exit 1
        fi

        dest_db_name=${CFG_DB_DEST_NAME:-$dest_db_name}
        if [ -z "$dest_db_name" ]; then
            read -p "Enter destination database name: " dest_db_name
        fi
        if [ -z "$dest_db_name" ]; then
            print_error "Destination database name cannot be empty!"
            exit 1
        fi

        dest_db_host=${CFG_DB_DEST_HOST:-$dest_db_host}
        if [ -z "$dest_db_host" ]; then
            read -p "Enter destination DB host (default: $db_host): " dest_db_host
        fi
        dest_db_host=${dest_db_host:-$db_host}

        dest_db_port=${CFG_DB_DEST_PORT:-$dest_db_port}
        if [ -z "$dest_db_port" ]; then
            read -p "Enter destination DB port (default: $db_port): " dest_db_port
        fi
        dest_db_port=${dest_db_port:-$db_port}

        dest_db_user=${CFG_DB_DEST_USER:-$dest_db_user}
        if [ -z "$dest_db_user" ]; then
            read -p "Enter destination DB username (default: $db_user): " dest_db_user
        fi
        dest_db_user=${dest_db_user:-$db_user}

        dest_db_pass=${CFG_DB_DEST_PASS:-$dest_db_pass}
        if [ -z "$dest_db_pass" ]; then
            read -s -p "Enter destination DB password (leave empty to keep same): " dest_db_pass
            echo ""
        fi
        if [ -z "$dest_db_pass" ]; then
            dest_db_pass="$db_pass"
        fi

        ensure_destination_db "$dest_db_host" "$dest_db_port" "$dest_db_user" "$dest_db_pass" "$dest_db_name"

        print_info "Migrating database..."
        mysqldump -h "$db_host" -P "$db_port" -u "$db_user" -p"$db_pass" "$db_name" | mysql -h "$dest_db_host" -P "$dest_db_port" -u "$dest_db_user" -p"$dest_db_pass" "$dest_db_name"
        if [ $? -eq 0 ]; then
            print_success "Database migration completed successfully."
            update_db_in_env "$dest_domain/.env.local"
            update_db_in_env "$dest_domain/public/.env"
        else
            print_error "Database migration failed."
            exit 1
        fi
    fi
fi

# File copy (skipped in --db-only mode)
if [ "$DB_ONLY" = false ]; then
    # Create destination directory if it doesn't exist
    if [ -d "$dest_domain" ]; then
        # Check if destination directory contains any files
        if [ "$(ls -A "$dest_domain")" ]; then
            existing_count=$(find "$dest_domain" -type f | wc -l)
            print_info "Destination directory already exists and contains $existing_count file(s)."
            echo ""
            print_info "You must delete existing content before copying new files."
            if [ -n "$CFG_DELETE_EXISTING" ]; then
                if is_true "$CFG_DELETE_EXISTING"; then
                    delete_confirm="y"
                else
                    delete_confirm="n"
                fi
            else
                read -p "Do you want to DELETE all existing files and proceed? (y/n): " delete_confirm
            fi
            
            if [ "$delete_confirm" = "y" ] || [ "$delete_confirm" = "Y" ]; then
                print_info "Deleting existing files in $dest_domain..."
                empty_dir=$(mktemp -d)
                rsync -a --delete --info=progress2 "$empty_dir"/ "$dest_domain"/
                delete_status=$?
                rmdir "$empty_dir" 2>/dev/null
                if [ $delete_status -eq 0 ]; then
                    print_success "Existing files deleted successfully."
                else
                    print_error "Failed to delete existing files!"
                    exit 1
                fi
            else
                print_info "Migration cancelled. Existing files were not modified."
                exit 0
            fi
        else
            print_info "Destination directory exists but is empty."
        fi
    else
        mkdir -p "$dest_domain"
        if [ $? -eq 0 ]; then
            print_success "Created destination directory: $dest_domain"
        else
            print_error "Failed to create destination directory!"
            exit 1
        fi
    fi

    # Copy all files from source to destination with a progress bar
    print_info "Copying files..."
    total_bytes=$(get_dir_size_bytes "$source_domain")
    if [ -n "$total_bytes" ] && [ "$total_bytes" -gt 0 ] 2>/dev/null; then
        tar -C "$source_domain" -cf - . | pv -s "$total_bytes" | tar -C "$dest_domain" -xf -
    else
        tar -C "$source_domain" -cf - . | pv | tar -C "$dest_domain" -xf -
    fi
    copy_status=$?

    # Check if copy was successful
    if [ $copy_status -eq 0 ]; then
        # Count files copied
        file_count=$(find "$dest_domain" -type f | wc -l)
        print_success "Migration completed successfully!"
        print_success "Total files copied: $file_count"
        echo ""
        print_info "Destination: $dest_domain"

        # Update domain references inside destination env files
        if [ -n "$CFG_UPDATE_DOMAINS" ]; then
            if is_true "$CFG_UPDATE_DOMAINS"; then
                update_domain_confirm="y"
            else
                update_domain_confirm="n"
            fi
        else
            read -p "Update domain in $dest_domain/.env.local and $dest_domain/public/.env? (y/n): " update_domain_confirm
        fi
        if [ "$update_domain_confirm" = "y" ] || [ "$update_domain_confirm" = "Y" ]; then
            update_domain_in_env "$dest_domain/.env.local"
            update_domain_in_env "$dest_domain/public/.env"
        else
            print_info "Skipped updating domains in env files."
        fi
    else
        print_error "Migration failed during file copy!"
        exit 1
    fi
fi
