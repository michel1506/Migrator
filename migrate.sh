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

# Ensure required tools are available
if ! command -v rsync >/dev/null 2>&1; then
    print_error "rsync is required for progress bars but was not found."
    print_info "Please install rsync and try again."
    exit 1
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

# Prompt for source domain
echo "==================================="
echo "   Domain Migration Tool"
echo "==================================="
echo ""
read -p "Enter the source domain (e.g., tt-gmbh.de): " source_domain

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
read -p "Enter the destination domain (e.g., test.tt-gmbh.de): " dest_domain

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

# Ask for confirmation
read -p "Proceed with migration? (y/n): " confirm
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
    read -p "Do you want to migrate the database using $env_file? (y/n): " db_confirm
    if [ "$db_confirm" = "y" ] || [ "$db_confirm" = "Y" ]; then
        if ! command -v mysqldump >/dev/null 2>&1 || ! command -v mysql >/dev/null 2>&1; then
            print_error "mysqldump and mysql are required for database migration."
            print_info "Please install them and try again."
            exit 1
        fi

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

        if [ -z "$db_port" ]; then
            db_port=3306
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

        read -p "Enter destination database name: " dest_db_name
        if [ -z "$dest_db_name" ]; then
            print_error "Destination database name cannot be empty!"
            exit 1
        fi

        read -p "Enter destination DB host (default: $db_host): " dest_db_host
        dest_db_host=${dest_db_host:-$db_host}
        read -p "Enter destination DB port (default: $db_port): " dest_db_port
        dest_db_port=${dest_db_port:-$db_port}
        read -p "Enter destination DB username (default: $db_user): " dest_db_user
        dest_db_user=${dest_db_user:-$db_user}
        read -s -p "Enter destination DB password (leave empty to keep same): " dest_db_pass
        echo ""
        if [ -z "$dest_db_pass" ]; then
            dest_db_pass="$db_pass"
        fi

        # Ensure destination database is new (drop if it exists)
        if db_exists "$dest_db_host" "$dest_db_port" "$dest_db_user" "$dest_db_pass" "$dest_db_name"; then
            print_info "Destination database '$dest_db_name' already exists."
            read -p "Drop and recreate it? This will DELETE all data. (y/n): " drop_confirm
            if [ "$drop_confirm" != "y" ] && [ "$drop_confirm" != "Y" ]; then
                print_info "Migration cancelled."
                exit 0
            fi
            mysql -h "${dest_db_host:-localhost}" -P "$dest_db_port" -u "$dest_db_user" -p"$dest_db_pass" -e "DROP DATABASE \`$dest_db_name\`;"
            if [ $? -ne 0 ]; then
                print_error "Failed to drop existing destination database."
                exit 1
            fi
        fi

        mysql -h "${dest_db_host:-localhost}" -P "$dest_db_port" -u "$dest_db_user" -p"$dest_db_pass" -e "CREATE DATABASE \`$dest_db_name\`;"
        if [ $? -ne 0 ]; then
            print_error "Failed to create destination database."
            exit 1
        fi

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
    read -p "Do you want to enter database details manually? (y/n): " manual_db_confirm
    if [ "$manual_db_confirm" = "y" ] || [ "$manual_db_confirm" = "Y" ]; then
        if ! command -v mysqldump >/dev/null 2>&1 || ! command -v mysql >/dev/null 2>&1; then
            print_error "mysqldump and mysql are required for database migration."
            print_info "Please install them and try again."
            exit 1
        fi

        read -p "Enter DB host (default: localhost): " db_host
        db_host=${db_host:-localhost}
        read -p "Enter DB port (default: 3306): " db_port
        db_port=${db_port:-3306}
        read -p "Enter source database name: " db_name
        read -p "Enter DB username: " db_user
        read -s -p "Enter DB password (leave empty if none): " db_pass
        echo ""

        if [ -z "$db_name" ] || [ -z "$db_user" ]; then
            print_error "Database name and username are required."
            exit 1
        fi

        read -p "Enter destination database name: " dest_db_name
        if [ -z "$dest_db_name" ]; then
            print_error "Destination database name cannot be empty!"
            exit 1
        fi

        read -p "Enter destination DB host (default: $db_host): " dest_db_host
        dest_db_host=${dest_db_host:-$db_host}
        read -p "Enter destination DB port (default: $db_port): " dest_db_port
        dest_db_port=${dest_db_port:-$db_port}
        read -p "Enter destination DB username (default: $db_user): " dest_db_user
        dest_db_user=${dest_db_user:-$db_user}
        read -s -p "Enter destination DB password (leave empty to keep same): " dest_db_pass
        echo ""
        if [ -z "$dest_db_pass" ]; then
            dest_db_pass="$db_pass"
        fi

        # Ensure destination database is new (drop if it exists)
        if db_exists "$dest_db_host" "$dest_db_port" "$dest_db_user" "$dest_db_pass" "$dest_db_name"; then
            print_info "Destination database '$dest_db_name' already exists."
            read -p "Drop and recreate it? This will DELETE all data. (y/n): " drop_confirm
            if [ "$drop_confirm" != "y" ] && [ "$drop_confirm" != "Y" ]; then
                print_info "Migration cancelled."
                exit 0
            fi
            mysql -h "$dest_db_host" -P "$dest_db_port" -u "$dest_db_user" -p"$dest_db_pass" -e "DROP DATABASE \`$dest_db_name\`;"
            if [ $? -ne 0 ]; then
                print_error "Failed to drop existing destination database."
                exit 1
            fi
        fi

        mysql -h "$dest_db_host" -P "$dest_db_port" -u "$dest_db_user" -p"$dest_db_pass" -e "CREATE DATABASE \`$dest_db_name\`;"
        if [ $? -ne 0 ]; then
            print_error "Failed to create destination database."
            exit 1
        fi

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

# Create destination directory if it doesn't exist
if [ -d "$dest_domain" ]; then
    # Check if destination directory contains any files
    if [ "$(ls -A "$dest_domain")" ]; then
        existing_count=$(find "$dest_domain" -type f | wc -l)
        print_info "Destination directory already exists and contains $existing_count file(s)."
        echo ""
        print_info "You must delete existing content before copying new files."
        read -p "Do you want to DELETE all existing files and proceed? (y/n): " delete_confirm
        
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

# Copy all files from source to destination with a consistent progress bar
print_info "Copying files..."
rsync -a --info=progress2 --no-inc-recursive "$source_domain"/ "$dest_domain"/
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
    update_domain_in_env "$dest_domain/.env.local"
    update_domain_in_env "$dest_domain/public/.env"
else
    print_error "Migration failed during file copy!"
    exit 1
fi
