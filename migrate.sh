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

# Copy all files from source to destination with progress
print_info "Copying files..."
rsync -a --info=progress2 "$source_domain"/ "$dest_domain"/
copy_status=$?

# Check if copy was successful
if [ $copy_status -eq 0 ]; then
    # Count files copied
    file_count=$(find "$dest_domain" -type f | wc -l)
    print_success "Migration completed successfully!"
    print_success "Total files copied: $file_count"
    echo ""
    print_info "Destination: $dest_domain"
else
    print_error "Migration failed during file copy!"
    exit 1
fi
