# shellcheck shell=bash
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
# Anything else is recorded in FILTER_UNKNOWN_SECTIONS so callers can warn rather
# than half-honour a section whose semantics these helpers don't model.
#
# Beyond the direct name-matching clauses, the helpers below also derive *indirect*
# exclusions: pgcopydb never creates an object whose parent was filtered out, so a
# sequence owned by an excluded table, a view built on one, an FK pointing at one,
# and everything an excluded extension owns are all legitimately absent from the
# target. Comparing them would be a guaranteed false alarm.
# =============================================================================

# Scope-relevant filter state. Initialised here so sourcing is safe under
# `set -u` before parse_filters_ini runs (or when no filters.ini is loaded).
FILTER_EXCLUDE_SCHEMAS=(); FILTER_EXCLUDE_TABLES=()
FILTER_INCLUDE_ONLY_TABLES=(); FILTER_INCLUDE_ONLY_SCHEMAS=()
FILTER_EXCLUDE_EXTENSIONS=()
FILTER_UNKNOWN_SECTIONS=()

# Parse scope-relevant sections from filters.ini into the global arrays above.
parse_filters_ini() {
    local ini_file="$1"
    FILTER_EXCLUDE_SCHEMAS=(); FILTER_EXCLUDE_TABLES=()
    FILTER_INCLUDE_ONLY_TABLES=(); FILTER_INCLUDE_ONLY_SCHEMAS=()
    FILTER_EXCLUDE_EXTENSIONS=()
    FILTER_UNKNOWN_SECTIONS=()
    local section="" line
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"   # ltrim
        line="${line%"${line##*[![:space:]]}"}"   # rtrim
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            _note_section "$section"
            continue
        fi
        case "$section" in
            exclude-schema)      FILTER_EXCLUDE_SCHEMAS+=("$line")      ;;
            exclude-table)       FILTER_EXCLUDE_TABLES+=("$line")       ;;
            include-only-table)  FILTER_INCLUDE_ONLY_TABLES+=("$line")  ;;
            include-only-schema) FILTER_INCLUDE_ONLY_SCHEMAS+=("$line") ;;
            exclude-extension)   FILTER_EXCLUDE_EXTENSIONS+=("$line")   ;;
        esac
    done < "$ini_file"
}

# Record a section header that is outside the six filters.ini documents, once.
# exclude-event-trigger counts as known: no check compares event triggers, so it
# needs no scoping, but it is not unsupported either.
_note_section() {
    local s="$1" seen
    case "$s" in
        exclude-schema|exclude-table|exclude-extension|exclude-event-trigger \
        |include-only-table|include-only-schema) return ;;
    esac
    if [ ${#FILTER_UNKNOWN_SECTIONS[@]} -gt 0 ]; then
        for seen in "${FILTER_UNKNOWN_SECTIONS[@]}"; do
            [ "$seen" = "$s" ] && return
        done
    fi
    FILTER_UNKNOWN_SECTIONS+=("$s")
}

# Comma-list of filters.ini sections these helpers do not model, or "".
filter_unknown_sections() {
    [ ${#FILTER_UNKNOWN_SECTIONS[@]} -eq 0 ] && { echo ""; return; }
    local out="" s
    for s in "${FILTER_UNKNOWN_SECTIONS[@]}"; do out="${out:+$out, }$s"; done
    echo "$out"
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

# ── Dependency scoping ────────────────────────────────────────────────────────
# Every helper below returns "" when the filter gives it nothing to exclude, so an
# empty filters.ini leaves the built SQL byte-identical to a filter-unaware version.
# They are deliberately narrow: each removes only objects whose *parent* was
# filtered out, never an object that was in scope and genuinely failed to migrate.

# _ext_member_exists <catalog> <oid-expr> — EXISTS() true when the object belongs to
# an [exclude-extension] entry. pgcopydb drops such an extension together with
# everything it owns, so those objects never existed on the target.
# Caller must check FILTER_EXCLUDE_EXTENSIONS is non-empty first.
_ext_member_exists() {
    echo "EXISTS (SELECT 1 FROM pg_depend xd JOIN pg_extension xe ON xe.oid = xd.refobjid WHERE xd.classid = '${1}'::regclass AND xd.objid = ${2} AND xd.deptype = 'e' AND xe.extname IN ($(_sql_list "${FILTER_EXCLUDE_EXTENSIONS[@]}")))"
}

# _oos_relation_pred <schema-col> <rel-col> <oid-col> — parenthesised predicate that
# is TRUE for a relation the migration would not have copied, for any reason: its
# schema is out of scope, it is listed in [exclude-table], or it belongs to an
# excluded extension. "" when nothing at all is out of scope — the dependency
# clauses built on top then collapse to "" too.
_oos_relation_pred() {
    local scol="$1" rcol="$2" ocol="$3" mode out=""
    mode=$(filter_scope_mode)
    case "$mode" in
        include-table)  out="(${scol} || '.' || ${rcol}) NOT IN ($(_sql_list "${FILTER_INCLUDE_ONLY_TABLES[@]}"))" ;;
        include-schema) out="${scol} NOT IN ($(_sql_list "${FILTER_INCLUDE_ONLY_SCHEMAS[@]}"))" ;;
        exclude-schema) out="${scol} IN ($(_sql_list "${FILTER_EXCLUDE_SCHEMAS[@]}"))" ;;
    esac
    # include-only-table already enumerates the whole scope, so [exclude-table] must
    # not narrow it further (pgcopydb rejects that combination outright).
    if [ "$mode" != "include-table" ] && [ ${#FILTER_EXCLUDE_TABLES[@]} -gt 0 ]; then
        out="${out:+$out OR }(${scol} || '.' || ${rcol}) IN ($(_sql_list "${FILTER_EXCLUDE_TABLES[@]}"))"
    fi
    if [ ${#FILTER_EXCLUDE_EXTENSIONS[@]} -gt 0 ]; then
        out="${out:+$out OR }$(_ext_member_exists pg_class "$ocol")"
    fi
    [ -z "$out" ] && { echo ""; return; }
    echo "($out)"
}

# extension_rel_clause <schema-col> <rel-col> — drops relations (tables, indexes,
# views, sequences) owned by an excluded extension. Keyed on names so it works
# against pg_class, information_schema.columns, pg_indexes, pg_views, pg_sequences.
extension_rel_clause() {
    [ ${#FILTER_EXCLUDE_EXTENSIONS[@]} -eq 0 ] && { echo ""; return; }
    echo "AND (${1}, ${2}) NOT IN (SELECT xn.nspname, xc.relname FROM pg_class xc JOIN pg_namespace xn ON xn.oid = xc.relnamespace WHERE $(_ext_member_exists pg_class xc.oid))"
}

# extension_oid_clause <catalog> <oid-col> — same idea for non-relation objects that
# expose an oid: routines (pg_proc) and constraints (pg_constraint).
extension_oid_clause() {
    [ ${#FILTER_EXCLUDE_EXTENSIONS[@]} -eq 0 ] && { echo ""; return; }
    echo "AND NOT $(_ext_member_exists "$1" "$2")"
}

# fk_target_clause <confrelid-col> — drops a foreign key whose *referenced* table is
# out of scope. The FK's own table can be perfectly in scope: pgcopydb still cannot
# create the constraint, so the target legitimately lacks it.
fk_target_clause() {
    local pred
    pred=$(_oos_relation_pred "fkn.nspname" "fkt.relname" "fkt.oid")
    [ -z "$pred" ] && { echo ""; return; }
    echo "AND NOT EXISTS (SELECT 1 FROM pg_class fkt JOIN pg_namespace fkn ON fkn.oid = fkt.relnamespace WHERE fkt.oid = ${1} AND ${pred})"
}

# sequence_owner_clause <schema-col> <rel-col> — drops sequences owned by an
# out-of-scope table. serial/identity columns create a sequence with an internal
# ('a'/'i') dependency on the table, so excluding the table excludes the sequence.
# Standalone sequences have no such dependency and are never removed by this clause.
sequence_owner_clause() {
    local pred
    pred=$(_oos_relation_pred "sqtn.nspname" "sqt.relname" "sqt.oid")
    [ -z "$pred" ] && { echo ""; return; }
    echo "AND (${1}, ${2}) NOT IN (SELECT sqn.nspname, sq.relname FROM pg_class sq JOIN pg_namespace sqn ON sqn.oid = sq.relnamespace JOIN pg_depend sqd ON sqd.classid = 'pg_class'::regclass AND sqd.objid = sq.oid AND sqd.refclassid = 'pg_class'::regclass AND sqd.deptype IN ('a','i') JOIN pg_class sqt ON sqt.oid = sqd.refobjid JOIN pg_namespace sqtn ON sqtn.oid = sqt.relnamespace WHERE sq.relkind = 'S' AND ${pred})"
}

# view_dep_clause <schema-col> <rel-col> — drops views that (transitively) read an
# out-of-scope relation. Recursive because a view on an excluded table takes the
# view built on *that* view down with it. Also needed by the columns check:
# information_schema.columns reports view columns too, so without this a
# dependency-excluded view reappears there as "missing columns".
view_dep_clause() {
    local pred
    pred=$(_oos_relation_pred "vn.nspname" "vc.relname" "vc.oid")
    [ -z "$pred" ] && { echo ""; return; }
    echo "AND (${1}, ${2}) NOT IN (WITH RECURSIVE oos_rel(oid) AS (SELECT vc.oid FROM pg_class vc JOIN pg_namespace vn ON vn.oid = vc.relnamespace WHERE ${pred} UNION SELECT vr.ev_class FROM pg_rewrite vr JOIN pg_depend vd ON vd.classid = 'pg_rewrite'::regclass AND vd.objid = vr.oid AND vd.refclassid = 'pg_class'::regclass JOIN oos_rel ON oos_rel.oid = vd.refobjid WHERE vr.ev_class <> vd.refobjid) SELECT vn2.nspname, vc2.relname FROM pg_class vc2 JOIN pg_namespace vn2 ON vn2.oid = vc2.relnamespace WHERE vc2.oid IN (SELECT oid FROM oos_rel) AND vc2.relkind IN ('v','m'))"
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
