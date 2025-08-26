#!/bin/bash
#
# mssql_dumps.sh
# Backup script for Microsoft SQL: creates CREATE TABLE and INSERT statements.
# - Adds MSSQL_GLOBAL_WHERE_CLAUSE support: when set, appended to all data SELECTs used for dumping rows.
# - Robust health_check (connects directly to target DB)
# - Supports MSSQL_DROP_TABLES and fallback CSV->INSERT for non-binary tables

set -euo pipefail

if ! command -v sqlcmd &> /dev/null; then
    echo "Error: sqlcmd not found. Install sqlcmd or run it in a container with the appropriate tools."
    exit 1
fi

ENV_FILE=".env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    echo "Environment variables loaded from $ENV_FILE"
fi

SERVER_RAW="${MSSQL_SERVER:-}"
DATABASE_RAW="${MSSQL_DATABASE:-}"
USERNAME="${MSSQL_USER:-}"
PASSWORD="${MSSQL_PASSWORD:-}"
OUTPUT_FILE="${MSSQL_OUTPUT_FILE:-backup_$(date +%Y%m%d_%H%M%S).sql}"
TABLES="${MSSQL_TABLES:-}"
QUERY_TIMEOUT="${MSSQL_QUERY_TIMEOUT:-0}"
MSSQL_DROP_TABLES="${MSSQL_DROP_TABLES:-}"
MSSQL_GLOBAL_WHERE_CLAUSE="${MSSQL_GLOBAL_WHERE_CLAUSE:-}"

usage() {
    cat <<EOF
Usage: $0 -S server -d database -U username -P password [-o output_file] [-t tables] [-T timeout]
Environment variables supported:
  MSSQL_DROP_TABLES          -> true/yes/1 to include DROP TABLE before CREATE
  MSSQL_GLOBAL_WHERE_CLAUSE  -> optional WHERE clause applied to all data SELECTs (e.g. "IsActive = 1")
EOF
    exit 1
}

if [ $# -gt 0 ]; then
    while getopts "S:d:U:P:o:t:T:h" opt; do
        case $opt in
            S) SERVER_RAW="$OPTARG" ;;
            d) DATABASE_RAW="$OPTARG" ;;
            U) USERNAME="$OPTARG" ;;
            P) PASSWORD="$OPTARG" ;;
            o) OUTPUT_FILE="$OPTARG" ;;
            t) TABLES="$OPTARG" ;;
            T) QUERY_TIMEOUT="$OPTARG" ;;
            h) usage ;;
            *) usage ;;
        esac
    done
fi

if [ -z "$SERVER_RAW" ] || [ -z "$DATABASE_RAW" ] || [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    echo "Error: missing required parameters (server/database/username/password)."
    usage
fi

trim() { echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
SERVER_CLEAN=$(trim "$SERVER_RAW")
SERVER_CLEAN="${SERVER_CLEAN%,}"
SERVER_CLEAN=$(echo "$SERVER_CLEAN" | sed 's/[[:space:]]*,[[:space:]]*/,/g')

DATABASE=$(trim "$DATABASE_RAW")
DATABASE="${DATABASE%,}"

if [[ "$SERVER_CLEAN" == *,* ]]; then
    HOST_PART="${SERVER_CLEAN%%,*}"
    REST="${SERVER_CLEAN#*,}"
    PORT_PART="${REST%%,*}"
    HOST_PART=$(trim "$HOST_PART")
    PORT_PART=$(trim "$PORT_PART")
    if [[ -n "$PORT_PART" ]]; then
        SQLCMD_SERVER="${HOST_PART},${PORT_PART}"
    else
        SQLCMD_SERVER="$HOST_PART"
    fi
else
    SQLCMD_SERVER="$SERVER_CLEAN"
fi

echo "Connecting to SQL Server $SQLCMD_SERVER, database $DATABASE..."

parse_bool() {
    local v="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "$v" in
        1|true|yes) echo "true" ;;
        *) echo "false" ;;
    esac
}
DROP_TABLES_FLAG=$(parse_bool "$MSSQL_DROP_TABLES")

GLOBAL_WHERE_RAW="$(echo "${MSSQL_GLOBAL_WHERE_CLAUSE:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
GLOBAL_WHERE=""
if [ -n "$GLOBAL_WHERE_RAW" ]; then
    if echo "$GLOBAL_WHERE_RAW" | grep -qiE '^[[:space:]]*where[[:space:]]+'; then
        GLOBAL_WHERE="$GLOBAL_WHERE_RAW"
    else
        GLOBAL_WHERE="WHERE $GLOBAL_WHERE_RAW"
    fi
    echo "Global WHERE clause active: $GLOBAL_WHERE"
else
    echo "No global WHERE clause set."
fi

SQLCMD_BASE=( -S "$SQLCMD_SERVER" -U "$USERNAME" -P "$PASSWORD" -h -1 -w 32767 -y 8000 -t "$QUERY_TIMEOUT" )

execute_query() {
    local db="$1"; local q="$2"
    local tf
    tf=$(mktemp)
    printf "%s\n" "$q" > "$tf"
    sqlcmd "${SQLCMD_BASE[@]}" -d "$db" -i "$tf"
    local rc=$?
    rm -f "$tf"
    return $rc
}

execute_query_to_file() {
    local db="$1"; local q="$2"; local out="$3"
    local tf
    tf=$(mktemp)
    printf "%s\n" "$q" > "$tf"
    sqlcmd "${SQLCMD_BASE[@]}" -d "$db" -i "$tf" -o "$out"
    local rc=$?
    rm -f "$tf"
    return $rc
}

health_check() {
    echo "Performing health check..."

    if master_version_out=$(sqlcmd "${SQLCMD_BASE[@]}" -d master -Q "SELECT @@VERSION" 2>&1); then
        echo "Server version (master):"
        echo "$master_version_out" | sed -n '1,3p' | sed '/rows affected/Id'
    else
        echo "Warning: cannot query master for version (may be a contained user or permissions)."
    fi

    if ! dbname_out=$(sqlcmd "${SQLCMD_BASE[@]}" -d "$DATABASE" -Q "SET NOCOUNT ON; SELECT DB_NAME()" 2>&1); then
        echo "ERROR: failed to connect to target database '$DATABASE'. sqlcmd output:"
        echo "---- dbname_out ----"
        echo "$dbname_out"
        echo "---------------------"
        return 1
    fi

    dbname_line=$(echo "$dbname_out" | sed -n '1p' | sed '/rows affected/Id' | tr -d '[:space:]')
    if [ -z "$dbname_line" ] || [ "$dbname_line" = "NULL" ]; then
        if ! test_tables_out=$(sqlcmd "${SQLCMD_BASE[@]}" -d "$DATABASE" -Q "SET NOCOUNT ON; SELECT TOP 1 1 FROM INFORMATION_SCHEMA.TABLES" 2>&1); then
            echo "ERROR: target DB '$DATABASE' appears inaccessible. sqlcmd output for table check:"
            echo "---- test_tables_out ----"
            echo "$test_tables_out"
            echo "-------------------------"
            return 1
        fi
    fi

    echo "* Database '$DATABASE' is accessible."
    return 0
}

if ! health_check; then
    echo "Health check failed. Check SERVER/DATABASE/CREDENTIALS and MSSQL_SERVER format (host[,port])."
    echo "Note: in Azure SQL the username usually has the format user@servername (use this format in MSSQL_USER if applicable)."
    exit 1
fi

get_server_major_version() {
    local ver_out
    ver_out=$(sqlcmd "${SQLCMD_BASE[@]}" -d master -Q "SET NOCOUNT ON; SELECT CONVERT(INT, LEFT(CONVERT(varchar, SERVERPROPERTY('ProductVersion')), CHARINDEX('.', CONVERT(varchar, SERVERPROPERTY('ProductVersion')))-1));" 2>/dev/null || true)
    ver_out=$(echo "$ver_out" | sed -n '1p' | sed 's/[^0-9]*//g')
    if [ -z "$ver_out" ]; then
        ver_out=$(sqlcmd "${SQLCMD_BASE[@]}" -d "$DATABASE" -Q "SET NOCOUNT ON; SELECT CONVERT(INT, LEFT(CONVERT(varchar, SERVERPROPERTY('ProductVersion')), CHARINDEX('.', CONVERT(varchar, SERVERPROPERTY('ProductVersion')))-1));" 2>/dev/null || true)
        ver_out=$(echo "$ver_out" | sed -n '1p' | sed 's/[^0-9]*//g')
    fi
    echo "${ver_out:-}"
}

SERVER_MAJOR=$(get_server_major_version || true)
USE_MODERN_DROP=false
if [ "$(parse_bool "$MSSQL_DROP_TABLES")" = "true" ] && [ -n "$SERVER_MAJOR" ] && [ "$SERVER_MAJOR" -ge 13 ]; then
    USE_MODERN_DROP=true
fi

echo "-- SQL Server Backup generated on $(date)" > "$OUTPUT_FILE"
echo "-- Server: $SQLCMD_SERVER, Database: $DATABASE" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

generate_create_table_sql() {
    cat <<'TSQL'
SET NOCOUNT ON;
DECLARE @SchemaName SYSNAME = 'SCHEMA_REPLACE';
DECLARE @TableName SYSNAME  = 'TABLE_REPLACE';
DECLARE @Result NVARCHAR(MAX) = '';

SET @Result = 'CREATE TABLE ' + QUOTENAME(@TableName) + ' (' + CHAR(13) + CHAR(10);

SELECT @Result = @Result +
    '    ' + QUOTENAME(c.name) + ' ' +
    CASE
        WHEN t.name IN ('varchar','char','nvarchar','nchar') AND c.max_length <> -1
            THEN t.name + '(' + CAST(
                    CASE WHEN t.name IN ('nvarchar','nchar') THEN c.max_length/2 ELSE c.max_length END
                 AS VARCHAR(10)) + ')'
        WHEN t.name IN ('varchar','char','nvarchar','nchar') AND c.max_length = -1
            THEN t.name + '(MAX)'
        WHEN t.name IN ('decimal','numeric')
            THEN t.name + '(' + CAST(c.precision AS VARCHAR(10)) + ',' + CAST(c.scale AS VARCHAR(10)) + ')'
        ELSE t.name
    END +
    CASE WHEN c.is_nullable = 0 THEN ' NOT NULL' ELSE ' NULL' END +
    CASE WHEN c.is_identity = 1 THEN ' IDENTITY(' + CAST(ISNULL(IDENT_SEED(QUOTENAME(@TableName)),0) AS VARCHAR(10)) + ',' + CAST(ISNULL(IDENT_INCR(QUOTENAME(@TableName)),0) AS VARCHAR(10)) + ')' ELSE '' END +
    CASE WHEN c.default_object_id <> 0 THEN ' DEFAULT (' + OBJECT_DEFINITION(c.default_object_id) + ')' ELSE '' END + ',' + CHAR(13) + CHAR(10)
FROM sys.columns c
JOIN sys.types t ON c.user_type_id = t.user_type_id
WHERE object_id = OBJECT_ID(QUOTENAME(@TableName))
ORDER BY c.column_id;

SET @Result = LEFT(@Result, LEN(@Result) - 3) + CHAR(13) + CHAR(10) + ');' + CHAR(13) + CHAR(10);

;WITH pk AS (
  SELECT kc.name AS pk_name, c.name AS col_name, c.column_id
  FROM sys.key_constraints kc
  JOIN sys.index_columns ic ON kc.parent_object_id = ic.object_id AND kc.unique_index_id = ic.index_id
  JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
  JOIN sys.tables t ON t.object_id = kc.parent_object_id
  JOIN sys.schemas s ON t.schema_id = s.schema_id
  WHERE s.name = @SchemaName AND t.name = @TableName AND kc.type = 'PK'
)
SELECT @Result = @Result + 'ALTER TABLE ' + QUOTENAME(@TableName) +
       ' ADD CONSTRAINT ' + QUOTENAME(pk_name) + ' PRIMARY KEY (' +
       STRING_AGG(QUOTENAME(col_name), ', ') WITHIN GROUP (ORDER BY column_id) + ');' + CHAR(13) + CHAR(10)
FROM (SELECT DISTINCT pk_name, col_name, column_id FROM pk) as pkagg
GROUP BY pk_name;

SELECT @Result AS Script;
TSQL
}

if [ -z "$TABLES" ]; then
    TABLE_LIST=$(execute_query "$DATABASE" "SET NOCOUNT ON; SELECT TABLE_SCHEMA + '.' + TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE='BASE TABLE' ORDER BY TABLE_SCHEMA, TABLE_NAME;" | sed '/rows affected/Id' | sed '/^$/d')
else
    IFS=',' read -ra arr <<< "$TABLES"
    TABLE_LIST=""
    for t in "${arr[@]}"; do
        t=$(echo "$t" | xargs)
        if [[ "$t" != *"."* ]]; then t="dbo.$t"; fi
        TABLE_LIST+="$t"$'\n'
    done
fi

echo "$TABLE_LIST" | while read -r tline || [ -n "$tline" ]; do
    tline=$(echo "$tline" | xargs)
    [ -z "$tline" ] && continue

    schema=$(echo "$tline" | cut -d'.' -f1)
    tablename=$(echo "$tline" | cut -d'.' -f2)

    echo "" >> "$OUTPUT_FILE"
    echo "-- =================================================================" >> "$OUTPUT_FILE"
    echo "-- Table: $tablename" >> "$OUTPUT_FILE"
    echo "-- =================================================================" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"

    if [ "$(parse_bool "$MSSQL_DROP_TABLES")" = "true" ]; then
        if [ "$USE_MODERN_DROP" = "true" ]; then
            echo "-- Drop table if exists (modern syntax)" >> "$OUTPUT_FILE"
            echo "DROP TABLE IF EXISTS [[$tablename];" >> "$OUTPUT_FILE"
        else
            echo "-- Drop table if exists (legacy check)" >> "$OUTPUT_FILE"
            echo "IF OBJECT_ID(N'[$tablename]', 'U') IS NOT NULL" >> "$OUTPUT_FILE"
            echo "    DROP TABLE [$tablename];" >> "$OUTPUT_FILE"
        fi
        echo "" >> "$OUTPUT_FILE"
    fi

    echo "  - Extracting structure for $tablename..."
    create_tpl=$(generate_create_table_sql)
    create_sql="${create_tpl//SCHEMA_REPLACE/$schema}"
    create_sql="${create_sql//TABLE_REPLACE/$tablename}"
    tmp_create=$(mktemp)
    execute_query_to_file "$DATABASE" "$create_sql" "$tmp_create" || true

    echo "-- Table structure" >> "$OUTPUT_FILE"
    sed '/rows affected/Id; /^$/d' "$tmp_create" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
    rm -f "$tmp_create"

    has_identity=$(execute_query "$DATABASE" "SET NOCOUNT ON; SELECT CASE WHEN EXISTS(SELECT 1 FROM sys.columns c JOIN sys.tables t ON c.object_id=t.object_id JOIN sys.schemas s ON t.schema_id=s.schema_id WHERE s.name='$schema' AND t.name='$tablename' AND c.is_identity=1) THEN 'YES' ELSE 'NO' END;" | sed '/rows affected/Id' | tr -d '[:space:]' || true)
    if [[ "$has_identity" == "YES" ]]; then
        echo "-- Enable identity inserts" >> "$OUTPUT_FILE"
        echo "SET IDENTITY_INSERT [$tablename] ON;" >> "$OUTPUT_FILE"
        echo "" >> "$OUTPUT_FILE"
    fi

    column_names=$(execute_query "$DATABASE" "SET NOCOUNT ON; SELECT STRING_AGG(QUOTENAME(COLUMN_NAME), ',') WITHIN GROUP (ORDER BY ORDINAL_POSITION) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='$schema' AND TABLE_NAME='$tablename';" | sed '/rows affected/Id' | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -z "$column_names" ]; then
        echo "-- NOTE: no columns found for $tablename" >> "$OUTPUT_FILE"
        continue
    fi

    IFS=$'\n' read -d '' -r -a column_array < <(execute_query "$DATABASE" "SET NOCOUNT ON; SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='$schema' AND TABLE_NAME='$tablename' ORDER BY ORDINAL_POSITION;" | sed '/rows affected/Id' | sed '/^$/d' && printf '\0')

    WHERE_LITERAL="N''"
    if [ -n "$GLOBAL_WHERE" ]; then
        esc=$(printf "%s" "$GLOBAL_WHERE" | sed "s/'/''/g")
        WHERE_LITERAL="N'$esc'"
    fi

    tmp_data_sql=$(mktemp)
    cat > "$tmp_data_sql" <<TSQL
SET NOCOUNT ON;
DECLARE @Schema SYSNAME = N'$schema';
DECLARE @Table SYSNAME = N'$tablename';
DECLARE @cols NVARCHAR(MAX) = (
  SELECT STRING_AGG(QUOTENAME(COLUMN_NAME), ',') WITHIN GROUP (ORDER BY ORDINAL_POSITION)
  FROM INFORMATION_SCHEMA.COLUMNS
  WHERE TABLE_SCHEMA = @Schema AND TABLE_NAME = @Table
);

DECLARE @sql NVARCHAR(MAX) = N'SELECT ''INSERT INTO ' + QUOTENAME(@Schema) + '.' + QUOTENAME(@Table) + ' (' + @cols + ') VALUES ('' + ';

SELECT @sql = ISNULL(@sql,'') + STRING_AGG(
  'CASE WHEN ' + QUOTENAME(COLUMN_NAME) + ' IS NULL THEN ''NULL'' ' +
  'WHEN DATA_TYPE IN (''binary'',''varbinary'',''image'') THEN ''0x'' + SUBSTRING(sys.fn_varbintohexstr(' + QUOTENAME(COLUMN_NAME) + '),3,LEN(sys.fn_varbintohexstr(' + QUOTENAME(COLUMN_NAME) + ')) - 2) ' +
  'WHEN DATA_TYPE IN (''char'',''varchar'',''text'',''nchar'',''nvarchar'',''ntext'',''xml'',''uniqueidentifier'',''datetime'',''date'',''datetime2'',''datetimeoffset'',''time'') THEN ''N'''' + REPLACE(CAST(' + QUOTENAME(COLUMN_NAME) + ' AS NVARCHAR(MAX)),'''''''','''''''''') + ''''''''' ' +
  'ELSE ''CAST('''' + CAST(' + QUOTENAME(COLUMN_NAME) + ' AS NVARCHAR(MAX)) + '''' AS ' + DATA_TYPE + ')'' END + '','' ,'
, '') WITHIN GROUP (ORDER BY ORDINAL_POSITION)
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = @Schema AND TABLE_NAME = @Table;

-- finish SELECT construction and optionally append WHERE clause provided via script
SET @sql = LEFT(@sql, LEN(@sql) - LEN(''',''')) + ' + '')'' FROM ' + QUOTENAME(@Schema) + '.' + QUOTENAME(@Table) + ';';

IF LEN(${WHERE_LITERAL}) > 2 -- N'' is length 2; if greater, we have content
BEGIN
  -- remove leading N' and trailing ' to concat actual text, but easiest is to add ' WHERE ' + <literal without the N>
  -- we'll use @wc to hold the where text (without the leading N'' marker)
  DECLARE @wc NVARCHAR(MAX) = ${WHERE_LITERAL};
  IF LEFT(@wc,1) = N' ' BEGIN SET @wc = LTRIM(@wc); END
  -- If @wc already starts with 'WHERE ' or 'where ' we keep as-is (to be safe we check case-insensitive)
  IF UPPER(LEFT(LTRIM(@wc),6)) = N'WHERE ' 
    SET @sql = LEFT(@sql, LEN(@sql) - 1) + ' ' + LTRIM(@wc) + ';';
  ELSE
    SET @sql = LEFT(@sql, LEN(@sql) - 1) + ' WHERE ' + LTRIM(@wc) + ';';
END

EXEC sp_executesql @sql;
TSQL

    tmp_data_out=$(mktemp)
    sqlcmd "${SQLCMD_BASE[@]}" -d "$DATABASE" -i "$tmp_data_sql" -o "$tmp_data_out" || true
    rm -f "$tmp_data_sql"

    if grep -q "INSERT INTO" "$tmp_data_out"; then
        sed '/rows affected/Id; /^$/d' "$tmp_data_out" >> "$OUTPUT_FILE"
        echo "" >> "$OUTPUT_FILE"
        rm -f "$tmp_data_out"
    else
        inf_bin=$(execute_query "$DATABASE" "SET NOCOUNT ON; SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='$schema' AND TABLE_NAME='$tablename' AND DATA_TYPE IN ('binary','varbinary','image');" | sed '/rows affected/Id' | tr -d '[:space:]' || true)
        inf_bin=${inf_bin:-0}
        if [ "$inf_bin" -gt 0 ]; then
            echo "-- NOTE: data export skipped for $tablename due to binary columns" >> "$OUTPUT_FILE"
            rm -f "$tmp_data_out" || true
        else
            csv_sql="SET NOCOUNT ON; SELECT "
            first=1
            for col in "${column_array[@]}"; do
                piece="CASE WHEN ${col} IS NULL THEN 'NULL' ELSE '''' + REPLACE(CAST(${col} AS NVARCHAR(MAX)), '''', '''''') + '''' END"
                if [ $first -eq 1 ]; then
                    csv_sql+="$piece"
                    first=0
                else
                    csv_sql+=" + '|' + $piece"
                fi
            done

            csv_sql+=" FROM [$tablename]"
            if [ -n "$GLOBAL_WHERE" ]; then
                csv_sql+=" $GLOBAL_WHERE"
            fi
            csv_sql+=";"

            tmp_csv_out=$(mktemp)
            sqlcmd "${SQLCMD_BASE[@]}" -d "$DATABASE" -Q "$csv_sql" -o "$tmp_csv_out" || true

            if ! grep -q "." "$tmp_csv_out"; then
                echo "-- NOTE: fallback CSV produced no output for $tablename" >> "$OUTPUT_FILE"
                sed -n '1,60p' "$tmp_data_out" || true
                sed -n '1,60p' "$tmp_csv_out" || true
                rm -f "$tmp_data_out" "$tmp_csv_out" || true
            else
                while IFS= read -r line || [ -n "$line" ]; do
                    IFS='|' read -r -a fields <<< "$line"
                    vals=()
                    for f in "${fields[@]}"; do
                        if [ "$f" = "<NULL>" ]; then
                            vals+=( "NULL" )
                        else
                            f_trim=$(echo "$f" | sed "s/^[[:space:]]*//;s/[[:space:]]*$//")
                            vals+=( "$f_trim" )
                        fi
                    done
                    IFS=','; joined="${vals[*]}"; unset IFS
                    echo "INSERT INTO [$tablename] ($column_names) VALUES ($joined);" >> "$OUTPUT_FILE"
                done < "$tmp_csv_out"
                echo "" >> "$OUTPUT_FILE"
                rm -f "$tmp_data_out" "$tmp_csv_out" || true
            fi
        fi
    fi

    if [[ "${has_identity:-}" == "YES" ]]; then
        echo "-- Disable identity inserts" >> "$OUTPUT_FILE"
        echo "SET IDENTITY_INSERT [$tablename] OFF;" >> "$OUTPUT_FILE"
        echo "" >> "$OUTPUT_FILE"
    fi

done

cat >> "$OUTPUT_FILE" <<EOF
-- Set options for proper backup import
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

EOF

echo "Backup completed. Output saved to: $OUTPUT_FILE"
