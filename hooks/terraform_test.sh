#!/usr/bin/env bash
set -eo pipefail

# globals variables
# shellcheck disable=SC2155 # No way to assign to readonly variable in separate lines
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

function main {
  common::initialize "$SCRIPT_DIR"
  common::parse_cmdline "$@"
  common::export_provided_env_vars "${ENV_VARS[@]}"
  common::parse_and_export_env_vars

  # Pass custom args to the terraform_test function
  terraform_test "${ARGS[@]}"
}

function terraform_test {
  # Allow a test regex filter as the first argument
  local filter="${1}"
  # Allow a module name regex filter as the second argument
  local default_module_filter=".*"
  local module_filter="${2:-$default_module_filter}"

  # The module name must contain the tests directory
  if [[ "$module_filter" != '.*' ]]; then
    module_filter="\/$module_filter\/tests"
  fi

  # Read all the test file names into an array, allowing for spaces and other non-variable safe characters
  declare -A testdirs=()
  while IFS= read -r -d $'\0'; do
    # Match against the filter, which defaults to `.*`
    if [[ "$REPLY" =~ $filter ]] && [[ "$REPLY" =~ $module_filter ]]; then
      testdirs["$(dirname "$REPLY")"]=1
    fi
  done < <(find . -type f \( -name "*.tftest.hcl" -o -name "*.tftest.json" \) -not -path "*/.terraform/*" -print0)

  # Iterate over the matched files and compose the `-filter` arguments to `terraform test`.
  local commands=()
  local module_dir
  local test_args
  local cmd
  local init_dirs=()
  for testdir in "${!testdirs[@]}"; do
    if [[ -z "$testdir" ]]; then
      continue
    fi

    # Strip trailing 'tests/' from the path using a bash variable regex substitution and assign to module_dir
    module_dir="${testdir/%\//}"       # Strip slash if it exists
    module_dir="${module_dir/%tests/}" # Strip tests path

    # If the filter is `.*` or `.` then run all the tests in the module
    if [[ "$filter" == ".*" ]] || [[ "$filter" == "." ]]; then
      commands+=("terraform -chdir='$module_dir' test")
      init_dirs+=("$module_dir")
      continue
    fi

    # Otherwise, run only the tests in the module that match the filters
    test_args=()
    while IFS= read -r -d $'\0'; do
      if [[ "$REPLY" =~ $filter ]] && [[ "$REPLY" =~ $module_filter ]]; then
        test_args+=("-filter='tests/$(basename "$REPLY")'")
      fi
    done < <(find . -type f \( -name "*.tftest.hcl" -o -name "*.tftest.json" \) -not -path "*/.terraform/*" -print0)

    cmd="terraform -chdir='$module_dir' test ${test_args[*]}"
    commands+=("$cmd")
    init_dirs+=("$module_dir")
  done

  # Iterate over all the dirs to initialize and run terraform init
  for init_dir in "${init_dirs[@]}"; do
    /usr/bin/env bash -c "terraform -chdir='$init_dir' init -input=false -no-color >/dev/null"
  done

  # Iterate over all the commands, running them in serial, exiting with the first failure
  for cmd in "${commands[@]}"; do
    # Run the tests in a subshell which will bubble up the exit code
    /usr/bin/env bash -c "$cmd"
  done
}

[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"
