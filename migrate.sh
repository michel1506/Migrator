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
DB_MIGRATE=false
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

ensure_python_available() {
    if command -v python3 >/dev/null 2>&1; then
        PYTHON_BIN="python3"
    elif command -v python >/dev/null 2>&1; then
        PYTHON_BIN="python"
    else
        print_error "Python is required for software DB migration."
        exit 1
    fi
}

install_python_package() {
    local package="$1"
    ensure_python_available
    print_info "Installing Python package: $package"
    "$PYTHON_BIN" -m pip install "$package"
    if [ $? -ne 0 ]; then
        print_error "Failed to install $package."
        exit 1
    fi
}

ensure_yaml_available() {
    ensure_python_available

    if ! "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import yaml
PY
    then
        install_python_package "pyyaml"
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
emit('CFG_CMS', get_path(data, ['cms']))

emit('CFG_DB_MIGRATE', get_path(data, ['db', 'migrate']))
emit('CFG_DB_METHOD', get_path(data, ['db', 'method']))
emit('CFG_DB_SOURCE_FROM_ENV', get_path(data, ['db', 'source_from_env']))
emit('CFG_DB_SOURCE_FROM_WP_CONFIG', get_path(data, ['db', 'source_from_wp_config']))
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
emit('CFG_DB_UPDATE_SALES_CHANNEL_URL', get_path(data, ['db', 'update_sales_channel_url']))

emit('CFG_DELETE_EXISTING', get_path(data, ['file_copy', 'delete_existing']))
emit('CFG_COPY_EXCLUDE_PATHS', get_path(data, ['file_copy', 'exclude_paths']))
emit('CFG_INCREMENTAL_MEDIA', get_path(data, ['file_copy', 'incremental_media']))
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

    if [ "$DB_MIGRATE" != true ]; then
        print_info "Database migration disabled. Skipping destination database clear."
        return 0
    fi

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

    if [ "$DB_MIGRATE" != true ]; then
        print_info "Database migration disabled. Destination database will not be modified."
        return 0
    fi

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

ensure_pymysql_available() {
    ensure_python_available
    if ! "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import pymysql
PY
    then
        install_python_package "pymysql"
    fi
}

delete_dest_contents() {
    local dest="$1"
    local keep_media="$2"
    local keep_wp_uploads="$3"
    local delete_status=0

    if [ "$keep_media" = true ] || [ "$keep_wp_uploads" = true ]; then
        find "$dest" -mindepth 1 \( -path "$dest/public/media" -o -path "$dest/wp-content/uploads" \) -prune -o -exec rm -rf {} + 2>/dev/null
        delete_status=$?
    else
        if command -v rsync >/dev/null 2>&1; then
            empty_dir=$(mktemp -d)
            rsync -a --delete --force --ignore-errors --info=progress2 "$empty_dir"/ "$dest"/
            delete_status=$?
            rmdir "$empty_dir" 2>/dev/null
        else
            delete_status=1
        fi

        if [ $delete_status -ne 0 ]; then
            print_info "Retrying delete with rm -rf..."
            find "$dest" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
            delete_status=$?
        fi
    fi

    return $delete_status
}

ensure_php_available() {
    if ! command -v php >/dev/null 2>&1; then
        print_error "PHP is required to run wp-cli.phar."
        exit 1
    fi
}

set_wp_cli_cmd() {
    local base="$1"
    
    # First check for global wp-cli installation
    if command -v wp >/dev/null 2>&1; then
        WP_CLI_CMD=("wp")
        return 0
    fi
    
    # Check for wp-cli in the specific directory
    if [ -x "$base/wp" ]; then
        WP_CLI_CMD=("$base/wp")
        return 0
    fi
    if [ -x "$base/vendor/bin/wp" ]; then
        WP_CLI_CMD=("$base/vendor/bin/wp")
        return 0
    fi
    if [ -f "$base/wp-cli.phar" ]; then
        ensure_php_available
        WP_CLI_CMD=("php" "$base/wp-cli.phar")
        return 0
    fi
    
    return 1
}

escape_sed() {
    echo "$1" | sed -e 's/[\/&|]/\\&/g'
}

update_wp_config_db() {
    local file="$1" host="$2" port="$3" name="$4" user="$5" pass="$6"
    if [ ! -f "$file" ]; then
        print_error "wp-config.php not found at $file"
        return 1
    fi

    local host_value="$host"
    if [ -n "$port" ] && [ "$port" != "3306" ]; then
        host_value="${host}:${port}"
    fi

    local esc_name esc_user esc_pass esc_host
    esc_name=$(escape_sed "$name")
    esc_user=$(escape_sed "$user")
    esc_pass=$(escape_sed "$pass")
    esc_host=$(escape_sed "$host_value")

    sed -i "s|define( *'DB_NAME'.*|define('DB_NAME', '${esc_name}');|" "$file"
    sed -i "s|define( *'DB_USER'.*|define('DB_USER', '${esc_user}');|" "$file"
    sed -i "s|define( *'DB_PASSWORD'.*|define('DB_PASSWORD', '${esc_pass}');|" "$file"
    sed -i "s|define( *'DB_HOST'.*|define('DB_HOST', '${esc_host}');|" "$file"
}

update_wp_config_domain() {
    local file="$1" src_domain="$2" dest_domain="$3"
    if [ ! -f "$file" ]; then
        print_error "wp-config.php not found at $file"
        return 1
    fi
    sed -i "s|$src_domain|$dest_domain|g" "$file"
}

get_wp_config_define() {
    local file="$1" key="$2"
    if [ ! -f "$file" ]; then
        return 1
    fi
    grep -E "define\(\s*['\"]${key}['\"]" "$file" | head -n 1 \
        | sed -E "s/.*define\(\s*['\"]${key}['\"]\s*,\s*['\"]([^'\"]*)['\"].*/\1/"
}

read_wp_config_db() {
    local file="$1"
    WP_SRC_DB_NAME=$(get_wp_config_define "$file" "DB_NAME")
    WP_SRC_DB_USER=$(get_wp_config_define "$file" "DB_USER")
    WP_SRC_DB_PASS=$(get_wp_config_define "$file" "DB_PASSWORD")
    WP_SRC_DB_HOST_RAW=$(get_wp_config_define "$file" "DB_HOST")

    if [ -z "$WP_SRC_DB_NAME" ] || [ -z "$WP_SRC_DB_USER" ] || [ -z "$WP_SRC_DB_HOST_RAW" ]; then
        return 1
    fi

    if echo "$WP_SRC_DB_HOST_RAW" | grep -q ':'; then
        WP_SRC_DB_HOST="${WP_SRC_DB_HOST_RAW%%:*}"
        WP_SRC_DB_PORT="${WP_SRC_DB_HOST_RAW##*:}"
    else
        WP_SRC_DB_HOST="$WP_SRC_DB_HOST_RAW"
        WP_SRC_DB_PORT="3306"
    fi

    return 0
}

run_wp_cli() {
    local path="$1" url="$2"
    shift 2
    if [ -n "$url" ]; then
        "${WP_CLI_CMD[@]}" --path="$path" --url="$url" "$@"
    else
        "${WP_CLI_CMD[@]}" --path="$path" "$@"
    fi
}

run_wp_migration() {
    local src="$1" dst="$2" tmp_sql
    tmp_sql=$(mktemp)

    # Export from source using source wp-cli
    print_info "Exporting WordPress database from source using wp-cli..."
    if ! set_wp_cli_cmd "$src"; then
        print_error "wp-cli not found in source directory $src"
        rm -f "$tmp_sql"
        return 1
    fi
    run_wp_cli "$src" "$source_domain" db export "$tmp_sql"
    if [ $? -ne 0 ]; then
        print_error "wp-cli export failed."
        rm -f "$tmp_sql"
        return 1
    fi

    # Import to destination using destination wp-cli
    print_info "Importing WordPress database into destination using wp-cli..."
    if ! set_wp_cli_cmd "$dst"; then
        print_error "wp-cli not found in destination directory $dst"
        rm -f "$tmp_sql"
        return 1
    fi
    run_wp_cli "$dst" "$dest_domain" db import "$tmp_sql"
    if [ $? -ne 0 ]; then
        print_error "wp-cli import failed."
        rm -f "$tmp_sql"
        return 1
    fi

    rm -f "$tmp_sql"

    # Search-replace using destination wp-cli (already set above)
    # Skip email columns to avoid breaking email addresses
    print_info "Updating WordPress URLs using wp-cli search-replace..."
    run_wp_cli "$dst" "$dest_domain" search-replace "$source_domain" "$dest_domain" \
        --skip-columns=guid,user_email,comment_author_email \
        --all-tables
    if [ $? -ne 0 ]; then
        print_error "wp-cli search-replace failed."
        return 1
    fi

    return 0
}

run_mysqldump_to_mysql() {
    local src_host="$1" src_port="$2" src_user="$3" src_pass="$4" src_db="$5"
    local dst_host="$6" dst_port="$7" dst_user="$8" dst_pass="$9" dst_db="${10}"

    local dump_opts=(--single-transaction --routines --events --triggers --set-gtid-purged=OFF --no-tablespaces)
    if mysqldump --help 2>/dev/null | grep -q -- '--skip-definer'; then
        dump_opts+=(--skip-definer)
        mysqldump -h "${src_host:-localhost}" -P "$src_port" -u "$src_user" -p"$src_pass" "${dump_opts[@]}" "$src_db" \
            | mysql -h "${dst_host:-localhost}" -P "$dst_port" -u "$dst_user" -p"$dst_pass" "$dst_db"
    else
        mysqldump -h "${src_host:-localhost}" -P "$src_port" -u "$src_user" -p"$src_pass" "${dump_opts[@]}" "$src_db" \
            | sed -E "s/DEFINER=\`[^\`]+\`@\`[^\`]+\`/DEFINER=CURRENT_USER/g" \
            | mysql -h "${dst_host:-localhost}" -P "$dst_port" -u "$dst_user" -p"$dst_pass" "$dst_db"
    fi
}

run_python_migration() {
    local src_host="$1" src_port="$2" src_user="$3" src_pass="$4" src_db="$5"
    local dst_host="$6" dst_port="$7" dst_user="$8" dst_pass="$9" dst_db="${10}"

    if [ "$DB_MIGRATE" != true ]; then
        print_info "Database migration disabled. Skipping python migration."
        return 0
    fi

    ensure_pymysql_available

    SRC_HOST="$src_host" SRC_PORT="$src_port" SRC_USER="$src_user" SRC_PASS="$src_pass" SRC_DB="$src_db" \
    DST_HOST="$dst_host" DST_PORT="$dst_port" DST_USER="$dst_user" DST_PASS="$dst_pass" DST_DB="$dst_db" \
    "$PYTHON_BIN" - <<'PY'
import os
import sys
import pymysql

src = dict(
    host=os.environ.get("SRC_HOST") or "localhost",
    port=int(os.environ.get("SRC_PORT") or "3306"),
    user=os.environ.get("SRC_USER") or "",
    password=os.environ.get("SRC_PASS") or "",
    database=os.environ.get("SRC_DB") or "",
)
dst = dict(
    host=os.environ.get("DST_HOST") or "localhost",
    port=int(os.environ.get("DST_PORT") or "3306"),
    user=os.environ.get("DST_USER") or "",
    password=os.environ.get("DST_PASS") or "",
    database=os.environ.get("DST_DB") or "",
)

def connect(conf, server_side=False):
    return pymysql.connect(
        host=conf["host"],
        port=conf["port"],
        user=conf["user"],
        password=conf["password"],
        database=conf["database"],
        charset="utf8mb4",
        autocommit=False,
        cursorclass=pymysql.cursors.SSCursor if server_side else pymysql.cursors.Cursor,
    )

try:
    meta_conn = connect(src, server_side=False)
    data_conn = connect(src, server_side=True)
    dst_conn = connect(dst, server_side=False)

    with dst_conn.cursor() as dst_cur:
        dst_cur.execute("SET FOREIGN_KEY_CHECKS=0;")
        dst_cur.execute(
            "SELECT table_name FROM information_schema.tables WHERE table_schema=%s AND table_type='BASE TABLE'",
            (dst["database"],),
        )
        for (table_name,) in dst_cur.fetchall():
            dst_cur.execute(f"DROP TABLE IF EXISTS `{table_name}`")
        dst_conn.commit()

    def render_progress(current, total, table):
        width = 30
        if total <= 0:
            return
        filled = int(width * current / total)
        bar = "#" * filled + "-" * (width - filled)
        line = f"[{bar}] {current}/{total} {table}"
        sys.stdout.write("\r" + line)
        sys.stdout.flush()

    with meta_conn.cursor() as meta_cur, dst_conn.cursor() as dst_cur:
        meta_cur.execute(
            "SELECT table_name FROM information_schema.tables WHERE table_schema=%s AND table_type='BASE TABLE'",
            (src["database"],),
        )
        tables = [row[0] for row in meta_cur.fetchall()]

        total_tables = len(tables)
        current_index = 0

        for table in tables:
            current_index += 1
            render_progress(current_index, total_tables, table)
            meta_cur.execute(f"SHOW CREATE TABLE `{table}`")
            create_sql = meta_cur.fetchone()[1]
            dst_cur.execute(create_sql)
            dst_conn.commit()

            with data_conn.cursor() as data_cur:
                data_cur.execute(f"SELECT * FROM `{table}`")
                columns = [desc[0] for desc in data_cur.description]
                if not columns:
                    continue

                col_names = ",".join(f"`{c}`" for c in columns)
                placeholders = ",".join(["%s"] * len(columns))
                insert_sql = f"INSERT INTO `{table}` ({col_names}) VALUES ({placeholders})"

                while True:
                    rows = data_cur.fetchmany(1000)
                    if not rows:
                        break
                    dst_cur.executemany(insert_sql, rows)
                dst_conn.commit()

        if total_tables > 0:
            sys.stdout.write("\n")
            sys.stdout.flush()

    with dst_conn.cursor() as dst_cur:
        dst_cur.execute("SET FOREIGN_KEY_CHECKS=1;")
        dst_conn.commit()

    meta_conn.close()
    data_conn.close()
    dst_conn.close()
except Exception as exc:
    print(exc)
    sys.exit(1)
PY
}

update_sales_channel_domain_url() {
    local host="$1" port="$2" user="$3" pass="$4" name="$5"
    local source="$6" dest="$7" method="$8"

    if [ "$method" = "mysql" ]; then
        mysql -h "${host:-localhost}" -P "$port" -u "$user" -p"$pass" "$name" \
            -e "UPDATE sales_channel_domain SET url = REPLACE(url, '${source}', '${dest}') WHERE url LIKE '%${source}%';"
        return $?
    fi

    ensure_pymysql_available
    SRC_DOMAIN="$source" DEST_DOMAIN="$dest" DB_HOST="$host" DB_PORT="$port" DB_USER="$user" DB_PASS="$pass" DB_NAME="$name" \
    "$PYTHON_BIN" - <<'PY'
import os
import pymysql

conn = pymysql.connect(
    host=os.environ.get("DB_HOST") or "localhost",
    port=int(os.environ.get("DB_PORT") or "3306"),
    user=os.environ.get("DB_USER") or "",
    password=os.environ.get("DB_PASS") or "",
    database=os.environ.get("DB_NAME") or "",
    charset="utf8mb4",
    autocommit=True,
)
src = os.environ.get("SRC_DOMAIN") or ""
dst = os.environ.get("DEST_DOMAIN") or ""

with conn.cursor() as cur:
    cur.execute(
        "UPDATE sales_channel_domain SET url = REPLACE(url, %s, %s) WHERE url LIKE %s",
        (src, dst, f"%{src}%"),
    )
conn.close()
PY
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

# ========================================
# WordPress Migration Function
# ========================================
migrate_wordpress() {
    print_info "Running WordPress migration..."
    
    # Database migration
    if [ -n "$CFG_DB_MIGRATE" ]; then
        if is_true "$CFG_DB_MIGRATE"; then
            db_migrate_confirm="y"
        else
            db_migrate_confirm="n"
        fi
    else
        read -p "Migrate WordPress database? (y/n): " db_migrate_confirm
    fi

    if [ "$db_migrate_confirm" = "y" ] || [ "$db_migrate_confirm" = "Y" ]; then
        DB_MIGRATE=true
        # Source database settings
        use_wp_config_source=false
        if [ -n "$CFG_DB_SOURCE_FROM_WP_CONFIG" ]; then
            if is_true "$CFG_DB_SOURCE_FROM_WP_CONFIG"; then
                use_wp_config_source=true
            fi
        else
            if [ -f "$source_domain/wp-config.php" ]; then
                read -p "Read source DB from wp-config.php? (y/n): " wp_config_confirm
                if [ "$wp_config_confirm" = "y" ] || [ "$wp_config_confirm" = "Y" ]; then
                    use_wp_config_source=true
                fi
            fi
        fi

        if [ "$use_wp_config_source" = true ]; then
            if ! read_wp_config_db "$source_domain/wp-config.php"; then
                print_error "Failed to read source DB details from wp-config.php."
                exit 1
            fi
            db_host="$WP_SRC_DB_HOST"
            db_port="$WP_SRC_DB_PORT"
            db_name="$WP_SRC_DB_NAME"
            db_user="$WP_SRC_DB_USER"
            db_pass="$WP_SRC_DB_PASS"
            print_info "Source WordPress DB: ${db_name} @ ${db_host}:${db_port} (user: ${db_user})"
        else
            db_host=${CFG_DB_SOURCE_HOST:-$db_host}
            db_port=${CFG_DB_SOURCE_PORT:-3306}
            db_name=${CFG_DB_SOURCE_NAME:-$db_name}
            db_user=${CFG_DB_SOURCE_USER:-$db_user}
            db_pass=${CFG_DB_SOURCE_PASS:-$db_pass}
            
            if [ -z "$db_name" ] || [ -z "$db_user" ]; then
                if [ -z "$db_host" ]; then
                    read -p "Enter source DB host (default: localhost): " db_host
                    db_host=${db_host:-localhost}
                fi
                if [ -z "$db_name" ]; then
                    read -p "Enter source database name: " db_name
                fi
                if [ -z "$db_user" ]; then
                    read -p "Enter source DB username: " db_user
                fi
                if [ -z "$db_pass" ]; then
                    read -s -p "Enter source DB password: " db_pass
                    echo ""
                fi
            fi
        fi

        # Destination database settings
        dest_db_host=${CFG_DB_DEST_HOST:-$dest_db_host}
        dest_db_port=${CFG_DB_DEST_PORT:-3306}
        dest_db_name=${CFG_DB_DEST_NAME:-$dest_db_name}
        dest_db_user=${CFG_DB_DEST_USER:-$dest_db_user}
        dest_db_pass=${CFG_DB_DEST_PASS:-$dest_db_pass}

        if [ -z "$dest_db_name" ] || [ -z "$dest_db_user" ]; then
            if [ -z "$dest_db_name" ]; then
                read -p "Enter destination database name: " dest_db_name
            fi
            if [ -z "$dest_db_host" ]; then
                read -p "Enter destination DB host (default: $db_host): " dest_db_host
                dest_db_host=${dest_db_host:-$db_host}
            fi
            if [ -z "$dest_db_user" ]; then
                read -p "Enter destination DB username (default: $db_user): " dest_db_user
                dest_db_user=${dest_db_user:-$db_user}
            fi
            if [ -z "$dest_db_pass" ]; then
                read -s -p "Enter destination DB password (leave empty to keep same): " dest_db_pass
                echo ""
            fi
        fi
        if [ -z "$dest_db_pass" ]; then
            dest_db_pass="$db_pass"
        fi

        print_info "Destination WordPress DB: ${dest_db_name} @ ${dest_db_host}:${dest_db_port} (user: ${dest_db_user})"
    fi

    # File copy
    if [ "$DB_ONLY" = false ]; then
        copy_files_common
        
        # Update wp-config.php if DB migration is enabled
        if [ "$db_migrate_confirm" = "y" ] || [ "$db_migrate_confirm" = "Y" ]; then
            if [ -f "$dest_domain/wp-config.php" ]; then
                print_info "Updating wp-config.php with destination database credentials..."
                update_wp_config_db "$dest_domain/wp-config.php" "$dest_db_host" "$dest_db_port" "$dest_db_name" "$dest_db_user" "$dest_db_pass"
                if [ $? -ne 0 ]; then
                    print_error "Failed to update wp-config.php."
                    exit 1
                fi

                print_info "Updating wp-config.php domain references..."
                update_wp_config_domain "$dest_domain/wp-config.php" "$source_domain" "$dest_domain"
                if [ $? -ne 0 ]; then
                    print_error "Failed to update wp-config.php domain references."
                    exit 1
                fi
            fi
        fi
    fi

    # Database migration via wp-cli
    if [ "$db_migrate_confirm" = "y" ] || [ "$db_migrate_confirm" = "Y" ]; then
        wp_cli_available=false
        # Check for wp-cli in destination directory (after files are copied)
        if set_wp_cli_cmd "$dest_domain"; then
            wp_cli_available=true
        fi

        if [ "$wp_cli_available" = true ]; then
            print_info "Running WordPress migration via wp-cli..."
            run_wp_migration "$source_domain" "$dest_domain"
            if [ $? -eq 0 ]; then
                print_success "WordPress migration completed successfully."
            else
                print_error "WordPress migration failed."
                exit 1
            fi
        else
            print_error "wp-cli not found in $dest_domain. Cannot perform WordPress database migration."
            print_info "Make sure wp-cli (wp or wp-cli.phar) exists in the destination directory."
            exit 1
        fi
    fi
}

# ========================================
# Shopware Migration Function
# ========================================
migrate_shopware() {
    print_info "Running Shopware migration..."
    
    # Track if database was migrated
    db_migrated=false
    
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
            DB_MIGRATE=true
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

            db_method="$CFG_DB_METHOD"
            if [ -z "$db_method" ]; then
                read -p "Select DB migration method (python/mysql) [python]: " db_method
                db_method=${db_method:-python}
            fi
            db_method=$(echo "$db_method" | tr '[:upper:]' '[:lower:]')
            if [ "$db_method" = "mysql" ]; then
                if ! command -v mysqldump >/dev/null 2>&1 || ! command -v mysql >/dev/null 2>&1; then
                    print_error "mysqldump and mysql are required for mysql method."
                    print_info "Choose python method or install mysql client tools."
                    exit 1
                fi
            else
                ensure_pymysql_available
            fi

            ensure_destination_db "$dest_db_host" "$dest_db_port" "$dest_db_user" "$dest_db_pass" "$dest_db_name"

            print_info "Migrating database..."
            if [ "$db_method" = "mysql" ]; then
                run_mysqldump_to_mysql "$db_host" "$db_port" "$db_user" "$db_pass" "$db_name" "$dest_db_host" "$dest_db_port" "$dest_db_user" "$dest_db_pass" "$dest_db_name"
            else
                run_python_migration "$db_host" "$db_port" "$db_user" "$db_pass" "$db_name" "$dest_db_host" "$dest_db_port" "$dest_db_user" "$dest_db_pass" "$dest_db_name"
            fi
            if [ $? -eq 0 ]; then
                print_success "Database migration completed successfully."
                db_migrated=true
                if [ -n "$CFG_DB_UPDATE_SALES_CHANNEL_URL" ]; then
                    if is_true "$CFG_DB_UPDATE_SALES_CHANNEL_URL"; then
                        sales_channel_confirm="y"
                    else
                        sales_channel_confirm="n"
                    fi
                else
                    read -p "Update sales_channel_domain.url to replace $source_domain with $dest_domain? (y/n): " sales_channel_confirm
                fi
                if [ "$sales_channel_confirm" = "y" ] || [ "$sales_channel_confirm" = "Y" ]; then
                    update_sales_channel_domain_url "$dest_db_host" "$dest_db_port" "$dest_db_user" "$dest_db_pass" "$dest_db_name" "$source_domain" "$dest_domain" "$db_method"
                    if [ $? -eq 0 ]; then
                        print_success "Updated sales_channel_domain.url."
                    else
                        print_error "Failed to update sales_channel_domain.url."
                        exit 1
                    fi
                fi
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
            DB_MIGRATE=true
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

            db_method="$CFG_DB_METHOD"
            if [ -z "$db_method" ]; then
                read -p "Select DB migration method (python/mysql) [python]: " db_method
                db_method=${db_method:-python}
            fi
            db_method=$(echo "$db_method" | tr '[:upper:]' '[:lower:]')
            if [ "$db_method" = "mysql" ]; then
                if ! command -v mysqldump >/dev/null 2>&1 || ! command -v mysql >/dev/null 2>&1; then
                    print_error "mysqldump and mysql are required for mysql method."
                    print_info "Choose python method or install mysql client tools."
                    exit 1
                fi
            else
                ensure_pymysql_available
            fi

            ensure_destination_db "$dest_db_host" "$dest_db_port" "$dest_db_user" "$dest_db_pass" "$dest_db_name"

            print_info "Migrating database..."
            if [ "$db_method" = "mysql" ]; then
                run_mysqldump_to_mysql "$db_host" "$db_port" "$db_user" "$db_pass" "$db_name" "$dest_db_host" "$dest_db_port" "$dest_db_user" "$dest_db_pass" "$dest_db_name"
            else
                run_python_migration "$db_host" "$db_port" "$db_user" "$db_pass" "$db_name" "$dest_db_host" "$dest_db_port" "$dest_db_user" "$dest_db_pass" "$dest_db_name"
            fi
            if [ $? -eq 0 ]; then
                print_success "Database migration completed successfully."
                db_migrated=true
                if [ -n "$CFG_DB_UPDATE_SALES_CHANNEL_URL" ]; then
                    if is_true "$CFG_DB_UPDATE_SALES_CHANNEL_URL"; then
                        sales_channel_confirm="y"
                    else
                        sales_channel_confirm="n"
                    fi
                else
                    read -p "Update sales_channel_domain.url to replace $source_domain with $dest_domain? (y/n): " sales_channel_confirm
                fi
                if [ "$sales_channel_confirm" = "y" ] || [ "$sales_channel_confirm" = "Y" ]; then
                    update_sales_channel_domain_url "$dest_db_host" "$dest_db_port" "$dest_db_user" "$dest_db_pass" "$dest_db_name" "$source_domain" "$dest_domain" "$db_method"
                    if [ $? -eq 0 ]; then
                        print_success "Updated sales_channel_domain.url."
                    else
                        print_error "Failed to update sales_channel_domain.url."
                        exit 1
                    fi
                fi
            else
                print_error "Database migration failed."
                exit 1
            fi
        fi
    fi

    # File copy (skipped in --db-only mode)
    if [ "$DB_ONLY" = false ]; then
        copy_files_common

        # Update .env files (only if database was migrated)
        if [ "$db_migrated" = true ]; then
            update_db_in_env "$dest_domain/.env.local"
            update_db_in_env "$dest_domain/public/.env"
        else
            print_info "Skipping DB env update (database was not migrated)."
        fi

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
        
        # Clear and warmup Shopware cache (only if database was migrated)
        if [ "$db_migrated" = true ]; then
            if [ -x "$dest_domain/bin/console" ]; then
                print_info "Clearing Shopware cache..."
                (cd "$dest_domain" && bin/console cache:clear)
                if [ $? -eq 0 ]; then
                    print_success "Cache cleared successfully."
                else
                    print_error "Failed to clear cache."
                fi
                
                print_info "Warming up Shopware cache..."
                (cd "$dest_domain" && bin/console cache:warmup)
                if [ $? -eq 0 ]; then
                    print_success "Cache warmed up successfully."
                else
                    print_error "Failed to warm up cache."
                fi
            else
                print_info "bin/console not found or not executable in $dest_domain, skipping cache operations."
            fi
        else
            print_info "Skipping cache operations (database was not migrated)."
        fi
    fi
}

# ========================================
# Common file copy function
# ========================================
copy_files_common() {
    excludes=()
    exclude_input=""
    if [ -n "$CFG_COPY_EXCLUDE_PATHS" ]; then
        exclude_input="$CFG_COPY_EXCLUDE_PATHS"
    else
        read -p "Enter comma-separated paths to exclude (e.g., var/cache,var/log,var/sessions,public/var/cache,node_modules,var/theme,public/theme,public/media,wp-content/cache,wp-content/w3tc-cache,wp-content/wp-rocket-cache,wp-content/litespeed,wp-content/debug.log,wp-content/*.log,wp-content/backup,*.zip,*.tar.gz) or leave empty: " exclude_input
    fi
    if [ -n "$exclude_input" ]; then
        IFS=',' read -ra raw_excludes <<< "$exclude_input"
        for item in "${raw_excludes[@]}"; do
            path=$(echo "$item" | sed 's/^ *//;s/ *$//')
            if [ -n "$path" ]; then
                excludes+=("--exclude=$path")
            fi
        done
    fi

    incremental_media=false
    incremental_wp_uploads=false
    if [ -n "$CFG_INCREMENTAL_MEDIA" ]; then
        if is_true "$CFG_INCREMENTAL_MEDIA"; then
            incremental_media=true
            incremental_wp_uploads=true
        fi
    else
        if [ -d "$dest_domain/public/media" ]; then
            read -p "Incrementally rsync public/media (keep existing files)? (y/n): " media_confirm
            if [ "$media_confirm" = "y" ] || [ "$media_confirm" = "Y" ]; then
                incremental_media=true
            fi
        fi
        if [ -d "$dest_domain/wp-content/uploads" ]; then
            read -p "Incrementally rsync wp-content/uploads (keep existing files)? (y/n): " wp_media_confirm
            if [ "$wp_media_confirm" = "y" ] || [ "$wp_media_confirm" = "Y" ]; then
                incremental_wp_uploads=true
            fi
        fi
    fi

    if [ "$incremental_media" = true ]; then
        excludes+=("--exclude=public/media/")
    fi
    if [ "$incremental_wp_uploads" = true ]; then
        excludes+=("--exclude=wp-content/uploads/")
    fi

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
                delete_dest_contents "$dest_domain" "$incremental_media" "$incremental_wp_uploads"
                delete_status=$?
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
    rsync -a --info=progress2 "${excludes[@]}" "$source_domain"/ "$dest_domain"/
    copy_status=$?

    if [ $copy_status -eq 0 ] && [ "$incremental_media" = true ] && [ -d "$source_domain/public/media" ]; then
        print_info "Incrementally syncing public/media..."
        mkdir -p "$dest_domain/public/media"
        rsync -a --info=progress2 "$source_domain/public/media/" "$dest_domain/public/media/"
        copy_status=$?
    fi
    if [ $copy_status -eq 0 ] && [ "$incremental_wp_uploads" = true ] && [ -d "$source_domain/wp-content/uploads" ]; then
        print_info "Incrementally syncing wp-content/uploads..."
        mkdir -p "$dest_domain/wp-content/uploads"
        rsync -a --info=progress2 "$source_domain/wp-content/uploads/" "$dest_domain/wp-content/uploads/"
        copy_status=$?
    fi

    # Check if copy was successful
    if [ $copy_status -eq 0 ]; then
        # Count files copied
        file_count=$(find "$dest_domain" -type f | wc -l)
        print_success "File copy completed successfully!"
        print_success "Total files copied: $file_count"
        echo ""
        print_info "Destination: $dest_domain"
    else
        print_error "Migration failed during file copy!"
        exit 1
    fi
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

# Detect CMS type
cms_type=$(echo "${CFG_CMS:-}" | tr '[:upper:]' '[:lower:]')
if [ -z "$cms_type" ]; then
    if [ -f "$source_domain/wp-config.php" ] && set_wp_cli_cmd "$source_domain"; then
        cms_type="wordpress"
        print_info "Auto-detected CMS: WordPress"
    else
        cms_type="shopware"
        print_info "Auto-detected CMS: Shopware"
    fi
else
    print_info "CMS type from config: $cms_type"
fi

# Route to appropriate migration function
if [ "$cms_type" = "wordpress" ]; then
    migrate_wordpress
else
    migrate_shopware
fi

print_success "Migration completed!"

