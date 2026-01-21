# Migrator

Migrate a domain folder and optionally its MySQL database using `migrate.sh`.

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

```yaml
source_domain: "tt-gmbh.de"
dest_domain: "test.tt-gmbh.de"
proceed: true

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

env_update:
  update_domains: true
```
