#!/usr/bin/env bats
# tests/unit/config_registry.bats — the config registry (cgw_config_registry in
# _config.sh) is the single list of CGW_* settings. These tests hold every
# other place a setting is written down to it: the defaults _config.sh
# applies, cgw.conf.example, the docs/configuration.md options table, the
# .cgw.conf generator in configure.sh, and inline ${CGW_X:-default}
# fallbacks in scripts and hooks.
# Runs: bats tests/unit/config_registry.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'

# Settings documented for the agent's CI procedure (skill/references/
# ci-verification.md) -- never read by a script, so not in the registry.
AGENT_ONLY_RE='^CGW_CI_'

setup() {
  create_test_repo
  mkdir -p "${TEST_REPO_DIR}/scripts/git"
}

teardown() {
  cleanup_test_repo
}

# _in_config <statements> — run statements after sourcing _config.sh in a clean
# environment inside the test repo.
_in_config() {
  (cd "${TEST_REPO_DIR}" && env -i PATH="${PATH}" HOME="${HOME}" bash -c "
    SCRIPT_DIR='${TEST_REPO_DIR}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_config.sh'
    $1")
}

_registry() { _in_config cgw_config_registry; }

@test "registry rows are well-formed and defaults match their kind" {
  local name default kind empty scope bad="" seen=" "
  while IFS='|' read -r name default kind empty scope; do
    [[ "${name}" =~ ^CGW_[A-Z0-9_]+$ ]] || bad+="bad name: ${name}"$'\n'
    [[ "${seen}" != *" ${name} "* ]] || bad+="duplicate: ${name}"$'\n'
    seen+="${name} "
    [[ "${empty}" == keep || "${empty}" == fill ]] || bad+="${name}: empty=${empty}"$'\n'
    [[ "${scope}" == conf || "${scope}" == env ]] || bad+="${name}: scope=${scope}"$'\n'
    case "${kind}" in
      str | computed) ;;
      bool) [[ "${default}" == 0 || "${default}" == 1 ]] || bad+="${name}: bool default ${default}"$'\n' ;;
      int) [[ "${default}" =~ ^[0-9]+$ ]] || bad+="${name}: int default ${default}"$'\n' ;;
      enum:*) [[ "/${kind#enum:}/" == *"/${default}/"* ]] || bad+="${name}: ${default} not in ${kind}"$'\n' ;;
      *) bad+="${name}: kind=${kind}"$'\n' ;;
    esac
  done < <(_registry)
  [ -z "${bad}" ] || { printf '%s' "${bad}"; false; }
}

@test "a clean environment resolves every setting to its registry default" {
  local name default kind empty scope got bad=""
  while IFS='|' read -r name default kind empty scope; do
    [[ "${kind}" == computed ]] && continue
    got="$(_in_config "printf '%s' \"\${${name}}\"")"
    [ "${got}" == "${default}" ] || bad+="${name}: got [${got}], registry [${default}]"$'\n'
  done < <(_registry)
  [ -z "${bad}" ] || { printf '%s' "${bad}"; false; }
}

@test "an explicitly empty value is kept or replaced as the registry says" {
  local name default kind empty scope got bad=""
  while IFS='|' read -r name default kind empty scope; do
    [[ "${kind}" == computed || "${kind}" == int ]] && continue
    got="$(cd "${TEST_REPO_DIR}" && env -i PATH="${PATH}" HOME="${HOME}" "${name}=" bash -c "
      SCRIPT_DIR='${TEST_REPO_DIR}/scripts/git'
      source '${CGW_PROJECT_ROOT}/scripts/git/_config.sh' 2>/dev/null
      printf '%s' \"\${${name}}\"")"
    if [[ "${empty}" == keep ]]; then
      [ -z "${got}" ] || bad+="${name} (keep): empty became [${got}]"$'\n'
    else
      [ "${got}" == "${default}" ] || bad+="${name} (fill): empty became [${got}], want [${default}]"$'\n'
    fi
  done < <(_registry)
  [ -z "${bad}" ] || { printf '%s' "${bad}"; false; }
}

@test "every persistent (conf) setting appears in cgw.conf.example" {
  local name default kind empty scope missing=""
  while IFS='|' read -r name default kind empty scope; do
    [[ "${scope}" == conf ]] || continue
    grep -qE "^(# )?${name}=" "${CGW_PROJECT_ROOT}/cgw.conf.example" || missing+="${name} "
  done < <(_registry)
  [ -z "${missing}" ] || { echo "missing from cgw.conf.example: ${missing}"; false; }
}

@test "every setting is in the docs options table with the registry default" {
  local doc="${CGW_PROJECT_ROOT}/docs/configuration.md"
  local name default kind empty scope row cell bad=""
  while IFS='|' read -r name default kind empty scope; do
    row="$(grep -F "| \`${name}\` |" "${doc}" | head -1)"
    if [[ -z "${row}" ]]; then
      bad+="${name}: not in docs/configuration.md"$'\n'
      continue
    fi
    [[ "${kind}" == computed ]] && continue
    # Default column: "| `name` | `value` | ..." -> value ("" for ``)
    cell="${row#*\` | }"
    cell="${cell%% | *}"
    cell="${cell#\`}"
    cell="${cell%\`}"
    [ "${cell}" == "${default}" ] || bad+="${name}: docs default [${cell}], registry [${default}]"$'\n'
  done < <(_registry)
  [ -z "${bad}" ] || { printf '%s' "${bad}"; false; }
}

@test "every CGW_* setting written in the example, docs table or generator is registered" {
  local names bad="" n
  names=" $(_registry | cut -d'|' -f1 | tr '\n' ' ') "
  {
    grep -oE '^(# )?CGW_[A-Z0-9_]+=' "${CGW_PROJECT_ROOT}/cgw.conf.example" | sed -E 's/^# //; s/=$//'
    grep -oE '^\| `CGW_[A-Z0-9_]+`' "${CGW_PROJECT_ROOT}/docs/configuration.md" | tr -d '|` '
    grep -oE 'echo "(# )?CGW_[A-Z0-9_]+=' "${CGW_PROJECT_ROOT}/scripts/git/configure.sh" | sed -E 's/^echo "(# )?//; s/=$//'
  } | sort -u >"${TEST_REPO_DIR}/written.txt"
  while read -r n; do
    [[ "${n}" =~ ${AGENT_ONLY_RE} ]] && continue
    [[ "${names}" == *" ${n} "* ]] || bad+="${n} "
  done <"${TEST_REPO_DIR}/written.txt"
  [ -z "${bad}" ] || { echo "not in cgw_config_registry: ${bad}"; false; }
}

@test "inline \${CGW_X:-default} fallbacks agree with the registry" {
  local name default kind empty scope bad="" f v
  declare -A reg_default=() reg_kind=()
  while IFS='|' read -r name default kind empty scope; do
    reg_default["${name}"]="${default}"
    reg_kind["${name}"]="${kind}"
  done < <(_registry)
  while IFS=$'\t' read -r f name v; do
    [[ -z "${v}" ]] && continue # ${CGW_X:-} is a set -u guard, not a default
    [[ -n "${reg_kind[${name}]+x}" ]] || continue
    [[ "${reg_kind[${name}]}" == computed ]] && continue
    [ "${v}" == "${reg_default[${name}]}" ] || bad+="${f}: \${${name}:-${v}} vs registry [${reg_default[${name}]}]"$'\n'
  done < <(grep -oE '\$\{CGW_[A-Z0-9_]+:-[^}]*\}' \
    "${CGW_PROJECT_ROOT}"/scripts/git/*.sh "${CGW_PROJECT_ROOT}"/hooks/pre-* 2>/dev/null |
    grep -v '/_config.sh:' |
    sed -E 's/^([^:]+):\$\{(CGW_[A-Z0-9_]+):-(.*)\}$/\1\t\2\t\3/')
  [ -z "${bad}" ] || { printf '%s' "${bad}"; false; }
}
