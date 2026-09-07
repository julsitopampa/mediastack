#!/bin/bash
set -euo pipefail

function create_database() {
    local db="$1"
    echo "  Creating database '$db' owned by '$POSTGRES_USER'"

    # Check if the database already exists
    if psql -U "$POSTGRES_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1; then
        echo "  Database '$db' already exists, skipping."
    else
        # Create the database with POSTGRES_USER as owner
        psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" \
            -c "CREATE DATABASE \"$db\" OWNER \"$POSTGRES_USER\";"
        echo "  Database '$db' created successfully."
    fi
}

if [[ -n "${POSTGRES_MULTIPLE_DATABASES:-}" ]]; then
    echo "Multiple database creation requested: $POSTGRES_MULTIPLE_DATABASES"
    IFS=':' read -ra DBS <<< "$POSTGRES_MULTIPLE_DATABASES"
    for db in "${DBS[@]}"; do
        create_database "$db"
    done
    echo "All databases processed."
else
    echo "No multiple database configuration provided. Set POSTGRES_MULTIPLE_DATABASES."
fi

