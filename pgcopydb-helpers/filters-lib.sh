# =============================================================================
# filters-lib.sh — shared filters.ini parser & SQL-scope helpers
# =============================================================================
# Sourced by verify-migration.sh and preflight-check.sh so both interpret
# ~/filters.ini identically. Not executable on its own — `source` it:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/filters-lib.sh"
#
# The migration only copies the subset of objects allowed by ~/filters.ini.
# Without this awareness, intentionally-excluded objects show up as "missing in target" 
# — false-positive noise. These helpers turn the active filter into 
# SQL WHERE fragments so every catalog query can be scoped to exactly 
# what the migration migrates.
#
# Supported sections: exclude-schema, exclude-table, include-only-schema,
# include-only-table, exclude-extension. (exclude-event-trigger is recognised by
# pgcopydb but not relevant to these scripts' checks, so it is ignored here.)
# =============================================================================

# Scope-relevant filter state. Initialised here so sourcing is safe under
# `set -u` before parse_filters_ini runs (or when no filters.ini is loaded).
FILTER_EXCLUDE_SCHEMAS=(); FILTER_EXCLUDE_TABLES=()
FILTER_INCLUDE_ONLY_TABLES=(); FILTER_INCLUDE_ONLY_SCHEMAS=()
FILTER_EXCLUDE_EXTENSIONS=()

# Parse scope-relevant sections from filters.ini into the global arrays above.
parse_filters_ini() {
    local ini_file="$1"
    FILTER_EXCLUDE_SCHEMAS=(); FILTER_EXCLUDE_TABLES=()
    FILTER_INCLUDE_ONLY_TABLES=(); FILTER_INCLUDE_ONLY_SCHEMAS=()
    FILTER_EXCLUDE_EXTENSIONS=()
    local section="" line
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"   # ltrim
        line="${line%"${line##*[![:space:]]}"}"   # rtrim
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then section="${BASH_REMATCH[1]}"; continue; fi
        case "$section" in
            exclude-schema)      FILTER_EXCLUDE_SCHEMAS+=("$line")      ;;
            exclude-table)       FILTER_EXCLUDE_TABLES+=("$line")       ;;
            include-only-table)  FILTER_INCLUDE_ONLY_TABLES+=("$line")  ;;
            include-only-schema) FILTER_INCLUDE_ONLY_SCHEMAS+=("$line") ;;
            exclude-extension)   FILTER_EXCLUDE_EXTENSIONS+=("$line")   ;;
        esac
    done < "$ini_file"
}

# Returns the effective filter mode: include-table | include-schema | exclude-schema | all
filter_scope_mode() {
    [ ${#FILTER_INCLUDE_ONLY_TABLES[@]} -gt 0 ]  && { echo "include-table";  return; }
    [ ${#FILTER_INCLUDE_ONLY_SCHEMAS[@]} -gt 0 ] && { echo "include-schema"; return; }
    [ ${#FILTER_EXCLUDE_SCHEMAS[@]} -gt 0 ]      && { echo "exclude-schema"; return; }
    echo "all"
}

# Formats values as a SQL-safe single-quoted comma list: 'a','b','c'
_sql_list() {
    local result="" v sq="'"
    for v in "$@"; do
        v="${v//$sq/$sq$sq}"
        result="${result:+$result,}'${v}'"
    done
    echo "$result"
}

# Build SQL-quoted list of unique schema names extracted from "schema.table" entries
_it_schema_sql_list() {
    local result="" sq="'"
    while IFS= read -r s; do
        s="${s//$sq/$sq$sq}"
        result="${result:+$result,}'${s}'"
    done < <(printf '%s\n' "$@" | cut -d. -f1 | sort -u)
    echo "$result"
}

# schema_clause <schema-column-expr> — "AND <col> IN/NOT IN (...)" or "" for all mode.
# Applied to every object type so excluded/included schemas scope the whole comparison.
schema_clause() {
    local col="$1" mode list
    mode=$(filter_scope_mode)
    case "$mode" in
        include-table)  list=$(_it_schema_sql_list "${FILTER_INCLUDE_ONLY_TABLES[@]}"); echo "AND ${col} IN (${list})" ;;
        include-schema) list=$(_sql_list "${FILTER_INCLUDE_ONLY_SCHEMAS[@]}");          echo "AND ${col} IN (${list})" ;;
        exclude-schema) list=$(_sql_list "${FILTER_EXCLUDE_SCHEMAS[@]}");               echo "AND ${col} NOT IN (${list})" ;;
        all)            echo "" ;;
    esac
}

# table_clause <schema-col> <rel-col> — restricts table-keyed checks to the
# in-scope table set. " AND (<schema>.<rel>) IN/NOT IN (...)" or "".
table_clause() {
    local scol="$1" rcol="$2" mode
    mode=$(filter_scope_mode)
    if [ "$mode" = "include-table" ]; then
        echo " AND (${scol} || '.' || ${rcol}) IN ($(_sql_list "${FILTER_INCLUDE_ONLY_TABLES[@]}"))"
    elif [ ${#FILTER_EXCLUDE_TABLES[@]} -gt 0 ]; then
        echo " AND (${scol} || '.' || ${rcol}) NOT IN ($(_sql_list "${FILTER_EXCLUDE_TABLES[@]}"))"
    else
        echo ""
    fi
}

# extension_clause <extname-col> — excludes [exclude-extension] entries, or "".
extension_clause() {
    local col="$1"
    [ ${#FILTER_EXCLUDE_EXTENSIONS[@]} -eq 0 ] && { echo ""; return; }
    echo "AND ${col} NOT IN ($(_sql_list "${FILTER_EXCLUDE_EXTENSIONS[@]}"))"
}

# Human-readable one-line summary of the active scope
filter_scope_describe() {
    case "$(filter_scope_mode)" in
        include-table)  echo "include-only-table (${#FILTER_INCLUDE_ONLY_TABLES[@]} table(s))" ;;
        include-schema) echo "include-only-schema (${#FILTER_INCLUDE_ONLY_SCHEMAS[@]} schema(s))" ;;
        exclude-schema) echo "exclude-schema (${#FILTER_EXCLUDE_SCHEMAS[@]} schema(s))$([ ${#FILTER_EXCLUDE_TABLES[@]} -gt 0 ] && echo " + exclude-table (${#FILTER_EXCLUDE_TABLES[@]})")" ;;
        all)            [ ${#FILTER_EXCLUDE_TABLES[@]} -gt 0 ] && { echo "exclude-table (${#FILTER_EXCLUDE_TABLES[@]} table(s))"; return; }; echo "none" ;;
    esac
}

# Lists disallowed section combinations present in filters.ini (pgcopydb rejects these), or ""
filter_conflicts() {
    local c=()
    [ ${#FILTER_INCLUDE_ONLY_TABLES[@]} -gt 0 ]  && [ ${#FILTER_EXCLUDE_SCHEMAS[@]} -gt 0 ] && c+=("include-only-table + exclude-schema")
    [ ${#FILTER_INCLUDE_ONLY_TABLES[@]} -gt 0 ]  && [ ${#FILTER_EXCLUDE_TABLES[@]} -gt 0 ]  && c+=("include-only-table + exclude-table")
    [ ${#FILTER_INCLUDE_ONLY_SCHEMAS[@]} -gt 0 ] && [ ${#FILTER_EXCLUDE_SCHEMAS[@]} -gt 0 ] && c+=("include-only-schema + exclude-schema")
    local IFS="; "; echo "${c[*]:-}"
}
