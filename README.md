# Migrator

Migrate a domain folder and optionally its MySQL database using `migrate.sh`.


## SSH quick start

Migrator is a command-line script, not a hosted service. With SSH access to the hosting account, run it from the directory containing the source and destination website folders:

```bash
ssh <user>@<server>
cd /path/to/hosting
# Download once; reuse the checkout for later runs.
git clone https://github.com/michel1506/Migrator.git
bash Migrator/migrate.sh
```

Replace the placeholders with your hosting details. Follow the prompts for the source folder, destination folder, database copy and domain updates. For Shopware, use a separate destination database and enable the sales-channel URL and environment-domain updates. Existing destination data is overwritten after backup; check staging mail and external integrations before testing. Requirements are listed below.

## Requirements

- Bash environment (e.g., Git Bash on Windows)
- `rsync` and `pv` for file copy progress
- `mysql` and `mysqldump` for DB migration
- Python + `PyYAML` if using `--config`

## Usage

```bash
./migrate.sh
```

```bash
./migrate.sh --db-only
```

```bash
./migrate.sh --config migrate.config.example.yaml
```

## YAML Config

Copy `migrate.config.example.yaml`, adjust values, then run with `--config`. Any missing values still prompt interactively. Set `db.method` to `python` (software migration) or `mysql` (mysqldump|mysql). Set `db.source_from_env` to choose whether the source DB is read from the source domain env file. Set `db.update_sales_channel_url` to update `sales_channel_domain.url` after migration. The destination database is always cleared before import.

Before destructive operations, the script creates a backup of destination files and (when DB migration is enabled) the destination database. If migration fails, rollback automatically restores the destination. After success, the script prompts whether to delete or revert the backup; `backup.success_action_default` controls the prompt default.

```yaml
source_domain: "example.com"
dest_domain: "staging.example.com"
proceed: true
cms: "shopware"

db:
  migrate: true
  method: "python"
  update_sales_channel_url: true
  source_from_env: true
  source:
    host: "localhost"
    port: 3306
    name: "source_db"
    user: "source_user"
    password: "source_password"
  dest:
    host: "localhost"
    port: 3306
    name: "dest_db"
    user: "dest_user"
    password: "dest_password"

file_copy:
  delete_existing: false
  exclude_paths: "var/cache,var/log,var/sessions,public/var/cache,node_modules,var/theme,public/theme,public/media,wp-content/cache,wp-content/w3tc-cache,wp-content/wp-rocket-cache,wp-content/litespeed,wp-content/debug.log,wp-content/*.log,wp-content/backup,*.zip,*.tar.gz"
  incremental_media: true

env_update:
  update_domains: true

backup:
  success_action_default: "delete"
```
