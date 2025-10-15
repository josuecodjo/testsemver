#!/usr/bin/env bash

#
#  This file is part of semver.sh.
#
#  semver.sh is free software: you can redistribute it and/or modify
#  it under the terms of the GNU Lesser General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  semver.sh is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU Lesser General Public License for more details.
#
#  You should have received a copy of the GNU Lesser General Public License
#  along with semver.sh.  If not, see <https://www.gnu.org/licenses/>.
#

set -eo pipefail

__SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly __SCRIPT_NAME

#=============================================================================
# Private Constants

readonly __RELEASE_TYPES=("ga" "la" "stable")

#=============================================================================
# Private Variables

__arg_command=""
__opt_base_version="0.1.0"
__opt_branch="${__opt_branch:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")}"
__opt_increment_source="commit-sequence"
__opt_json=false
__opt_pr_number=""
__opt_project_name=""
__opt_remote=""
__opt_quiet=false
__opt_release_type="stable"
__opt_skip_breaking_changes_from=()

#=============================================================================
# Private Methods

#-----------------------------------------------------------------------------
# Usage
#-----------------------------------------------------------------------------

__usage_print() {
    cat <<EOF
Usage: ${__SCRIPT_NAME} [COMMAND] [OPTIONS]

Commands:
  show-version                 Display the semantic version for the specified
                               branch or the current branch if none is
                               provided.
  create-release-branch        Create a new release branch using the calculated
                               semantic version.
  create-hotfix-branch         Create a new hotfix branch for patching a stable
                               version.
  finish-release-branch        Finalize a release branch by tagging and marking
                               it as stable.
  finish-hotfix-branch         Finalize a hotfix branch by tagging and marking
                               it as stable.
  create-changelog             Create a changelog for release stable branch

Options:
  General Options:
    --project-name <name>      Project name to prefix branches and tags.
                               Defaults to an empty string.
    --base-version <version>   Base version to use if no tags are found.
                               Defaults to "0.1.0".
    --remote <name>            Remote repository to interact with.
                               Defaults to auto-detection
                               ('origin' or the first available).
    --json                     Output information in JSON format.
    -q, --quiet                Suppress detailed output showing the branches
                               and tags being created.
    -h, --help                 Display this help message and exit.

  show-version Options:
    (inherits General Options)
    --branch <branch>          Branch to calculate the semantic version for.
                               Defaults to the current branch.
    --increment-source <source>
                               Source for determining version increments:
                                - commit-sequence (default)
                                - pr-number
    --pr-number <number>       Pull request number for version calculation.
                               Required if --increment-source="pr-number".
    --skip-breaking-changes-from <author>
                               Ignore breaking changes from a specific author
                               (e.g., dependabot[bot]).
                               Repeat the option to specify multiple authors.

  create-release-branch Options:
    (inherits General Options)
    --skip-breaking-changes-from <author>
                               Ignore breaking changes from a specific author
                               (e.g., dependabot[bot]).
                               Repeat the option to specify multiple authors.

  create-hotfix-branch Options:
    (inherits General Options)
    --branch <branch>          Specify the branch of the stable version to
                               patch (e.g., release/v1.2.0).

  finish-release-branch Options:
    (inherits General Options)
    --branch <branch>          Specify the release branch to finalize (e.g.,
                               release/v1.2.0).
    --release-type <type>      Type of release for the version:
                                - stable: a stable release (default)
                                - ga: general availability
                                - la: limited availability

  finish-hotfix-branch Options:
    (inherits General Options)
    --branch <branch>          Specify the hotfix branch to finalize (e.g.,
                               hotfix/1.2.1).
    --release-type <type>      Type of release for the version:
                                - stable: a stable release (default)
                                - ga: general availability
                                - la: limited availability

EOF
}

#-----------------------------------------------------------------------------
# Logging Utilities
#-----------------------------------------------------------------------------

__error_log() {
    local __param_message="${1}"

    printf "\033[0;31mERROR\033[0m: %b\n" "${__param_message}" >&2
    exit 1
}

#-----------------------------------------------------------------------------
# Git Utilities
#-----------------------------------------------------------------------------

__git_branch_exists() {
    local __param_branch="${1}"

    # Check if the branch exists locally or remotely
    git show-ref --verify --quiet "refs/heads/${__param_branch}" ||
        git ls-remote --quiet --exit-code "${__opt_remote}" "refs/heads/${__param_branch}" &>/dev/null
}

__git_branch_fetch_if_missing() {
    local __param_branch="${1}"

    # Return immediately if the branch already exists locally
    if git rev-parse --verify --quiet "${__param_branch}" &>/dev/null; then
        return 0
    fi

    # If not local, find the branch on a remote
    git fetch "${__opt_remote}" "${__param_branch}:${__param_branch}" --quiet || {
        __error_log "branch '${__param_branch}' not found on remote '${__opt_remote}'"
    }
}

__git_get_default_remote() {
    if git remote | grep -q "^origin$"; then
        echo "origin"
    else
        git remote | head -n 1
    fi
}

__git_is_repo_valid() {
    git rev-parse --is-inside-work-tree &>/dev/null &&
        git rev-parse --verify HEAD &>/dev/null
}

__git_tag_exists() {
    local __param_tag="${1}"

    # Check if the tag exists locally or remotely
    git tag --list | grep -q "^${__param_tag}$" ||
        git ls-remote --quiet --exit-code --tags "${__opt_remote}" "refs/tags/${__param_tag}" &>/dev/null
}

#-----------------------------------------------------------------------------
# Command-Line Argument Parsing and Validation
#-----------------------------------------------------------------------------

__command_line_parse() {
    local __opts
    if ! __opts="$(getopt --options qh --longoptions base-version:,branch:,tag:,increment-source:,help,json,pr-number:,project-name:,quiet,release-type:,remote:,skip-breaking-changes-from: -n "${__SCRIPT_NAME}" -- "${@}")"; then
        __error_log "failed parsing options"
    fi

    eval set -- "${__opts}"

    while true; do
        case "${1}" in
        "--base-version")
            __opt_base_version="${2}"
            shift 2
            ;;
        "--branch")
            __opt_branch="${2}"
            shift 2
            ;;
        "-h" | "--help")
            __usage_print
            exit 0
            ;;
        "--increment-source")
            __opt_increment_source="${2}"
            shift 2
            ;;
        "--json")
            __opt_json=true
            shift
            ;;
        "--pr-number")
            __opt_pr_number="${2}"
            shift 2
            ;;
        "--project-name")
            __opt_project_name="${2}"
            shift 2
            ;;
        "-q" | "--quiet")
            __opt_quiet=true
            shift
            ;;
        "--release-type")
            __opt_release_type="${2}"
            shift 2
            ;;
        "--remote")
            __opt_remote="${2}"
            shift 2
            ;;
        "--skip-breaking-changes-from")
            __opt_skip_breaking_changes_from+=("${2}")
            shift 2
            ;;
        --)
            break
            ;;
        *)
            __error_log "internal error"
            ;;
        esac
    done

    if [[ $# -lt 2 ]]; then
        __error_log "missing arguments"
    fi

    if [[ $# -gt 2 ]]; then
        __error_log "too many arguments"
    fi

    __arg_command="${2}"
}

__command_line_validate() {
    # Set the default remote if the user has not provided one
    if [[ -z "${__opt_remote}" ]]; then
        __opt_remote="$(__git_get_default_remote)"
    fi

    # Validate that the configured remote (either user-provided or auto-detected) exists
    if ! git remote | grep -q "^${__opt_remote}$"; then
        __error_log "remote '${__opt_remote}' does not exist"
    fi

    # Determine branch prefix from project name if provided
    local __branch_prefix="${__branch_prefix:-${__opt_project_name:+${__opt_project_name}/}}"

    # Validate base version format
    if ! [[ "${__opt_base_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        __error_log "invalid base version: '${__opt_base_version}'"
    fi

    # Ensure the specified branch is present locally, as it's a prerequisite for all subsequent commands
    __git_branch_fetch_if_missing "${__opt_branch}"

    # Command-specific validation
    case "${__arg_command}" in
    "show-version" | "create-release-branch")
        # No additional checks
        ;;
    "create-hotfix-branch")
        # Validate branch format for hotfix branch creation
        if [[ ! "${__opt_branch}" =~ ^${__branch_prefix}release/v[0-9]+\.[0-9]+\.[0-9]+$ && ! "${__opt_branch}" =~ ^${__branch_prefix}hotfix/v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            __error_log "branch must be a release or hotfix branch (e.g., '${__branch_prefix}release/v*' or '${__branch_prefix}hotfix/v*')"
        fi
        ;;
    "finish-release-branch")
        # Validate branch format for release branch finishing
        if [[ ! "${__opt_branch}" =~ ^${__branch_prefix}release/v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            __error_log "branch must be a release branch (e.g., '${__branch_prefix}release/v*')"
        fi
        ;;
    "create-changelog")
        # Validate branch format for release branch finishing
        if [[ ! "${__opt_branch}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-stable$ ]]; then
            __error_log "branch must be a release tag (e.g., 'v*')"
        fi
        ;;
    "finish-hotfix-branch")
        # Validate branch format for hotfix branch finishing
        if [[ ! "${__opt_branch}" =~ ^${__branch_prefix}hotfix/v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            __error_log "branch must be a hotfix branch (e.g., '${__branch_prefix}hotfix/v*')"
        fi
        ;;
    *)
        __error_log "invalid command"
        ;;
    esac

    # Ensure the development branch exists locally, fetching if necessary
    local __develop_branch="${__branch_prefix}develop"
    __git_branch_fetch_if_missing "${__develop_branch}"

    # Validate increment source
    case "${__opt_increment_source}" in
    "commit-sequence")
        # No additional checks
        ;;
    "pr-number")
        # PR number must be specified
        if [[ -z "${__opt_pr_number}" ]]; then
            __error_log "PR number must be specified when using 'pr-number' as the increment source"
        fi
        ;;
    *)
        __error_log "invalid increment source: '${__opt_increment_source}'"
        ;;
    esac

    # Validate the release type
    local __release_type
    for __release_type in "${__RELEASE_TYPES[@]}"; do
        if [[ "${__opt_release_type}" == "${__release_type}" ]]; then
            break
        fi
    done

    if [[ "${__opt_release_type}" != "${__release_type}" ]]; then
        __error_log "invalid release type: '${__opt_release_type}'"
    fi
}

#-----------------------------------------------------------------------------
# Semantic Versioning (SemVer) Calculation
#-----------------------------------------------------------------------------

__marker_tag_get_closest() {
    local __param_branch="${1}"
    local __param_develop_branch="${2}"
    local __param_start_marker_tag_format="${3}"

    local __marker_tag=""

    if [[ "${__param_branch}" == "${__param_develop_branch}" ]]; then
        # Handle the development branch
        local __commit_hash __current_tag
        __commit_hash="$(git rev-parse "${__param_branch}")"
        __current_tag="$(git describe --tags --exact-match --match "${__param_start_marker_tag_format}" "${__commit_hash}" 2>/dev/null)"

        if [[ -n "${__current_tag}" ]]; then
            # If on a marker tag, find the previous one
            __marker_tag="$(git tag --list "${__param_start_marker_tag_format}" | sort -V | awk -v tag="${__current_tag}" '
                    $0 == tag { exit }
                    { prev = $0 }
                    END { print prev }
                ')"
        else
            # Find the closest marker tag merged into the branch
            __marker_tag="$(git tag --merged "${__param_branch}" --list "${__param_start_marker_tag_format}" | sort -V | tail -n 1)"
        fi
    else
        # For other branches (release, hotfix, etc.), find the closest merged marker tag
        __marker_tag="$(git tag --merged "${__param_branch}" --list "${__param_start_marker_tag_format/\*/${__param_branch##*v}}")"
    fi

    echo "${__marker_tag}"
}

__semver_calculate() {
    # Define pre-release type and start marker format based on the branch type
    local __pre_release __start_marker_tag_format
    case "${__opt_branch}" in
    develop | */develop)
        __pre_release="dev"
        __start_marker_tag_format="v*-release-start-marker"
        ;;
    release/v* | */release/v*)
        __pre_release="rc"
        __start_marker_tag_format="v*-release-start-marker"
        ;;
    hotfix/v* | */hotfix/v*)
        __pre_release="rc"
        __start_marker_tag_format="v*-hotfix-start-marker"
        ;;
    *)
        __error_log "unsupported branch type: '${__opt_branch}'"
        ;;
    esac

    # Override pre-release type if the source of increment is from a PR number
    [[ "${__opt_increment_source}" == "pr-number" ]] && __pre_release="pr"

    # Prefix the start marker format with project name if provided
    __start_marker_tag_format="${__opt_project_name:+${__opt_project_name}-}${__start_marker_tag_format}"

    # Define the development branch name, considering project name
    local __develop_branch="${__opt_project_name:+${__opt_project_name}/}develop"

    # Retrieve the closest marker tag to determine the starting point for version calculation
    local __marker_tag
    __marker_tag="$(__marker_tag_get_closest "${__opt_branch}" "${__develop_branch}" "${__start_marker_tag_format}")"

    # Initialize commit range and version based on the closest marker tag
    local __commit_range __version
    if [[ -n "${__marker_tag}" ]]; then
        __commit_range="$(git rev-list --reverse "${__marker_tag}..${__opt_branch}")"
        __version="$(echo "${__marker_tag}" | sed -E 's/^[a-zA-Z0-9_-]*-?v([0-9]+\.[0-9]+\.[0-9]+)-(release|hotfix)-start-marker$/\1/')"
    else
        __commit_range="$(git rev-list --reverse "${__opt_branch}")"
        __version="${__opt_base_version}"
    fi

    # Parse version into major, minor, and patch components
    local __version_major __version_minor __version_patch
    IFS='.' read -r __version_major __version_minor __version_patch <<<"${__version}"

    # Check for breaking changes in commit range
    local __breaking_change=false
    if [[ -n "${__commit_range}" ]]; then
        while IFS= read -r __commit; do
            local __commit_message
            __commit_message="$(git log --format=%B -n 1 "${__commit}")"
            if echo "${__commit_message}" | grep -qE '^(.*!.*|.*BREAKING CHANGE.*)$'; then
                if [[ "${__opt_branch}" != "${__develop_branch}" ]]; then
                    __error_log "breaking changes are not allowed on release or hotfix branches"
                fi

                local __commit_author
                __commit_author="$(git show -s --format="%an" "${__commit}")"

                local __skip_commit=false
                for __author in "${__opt_skip_breaking_changes_from[@]}"; do
                    if [[ "${__author}" == "${__commit_author}" ]]; then
                        __skip_commit=true
                        break
                    fi
                done

                if [[ "${__skip_commit}" == false ]]; then
                    __breaking_change=true
                    break # Exit the loop after detecting the breaking change
                fi
            fi
        done <<<"${__commit_range}"
    fi

    # Increment version only for develop branch, based on breaking changes
    if [[ "${__opt_branch}" == "${__develop_branch}" ]]; then
        if [[ "${__breaking_change}" == "true" ]]; then
            __version_major="$((__version_major + 1))"
            __version_minor="0"
            __version_patch="0"
        elif [[ -n "${__marker_tag}" || "${__version}" != "${__opt_base_version}" ]]; then
            __version_minor="$((__version_minor + 1))"
        fi
    fi

    # Calculate the version increment based on commits or PR number
    local __version_increment="0"
    if [[ "${__opt_increment_source}" == "pr-number" ]]; then
        __version_increment="${__opt_pr_number}"
    else
        if [[ -n "${__marker_tag}" ]]; then
            __version_increment="$(git rev-list --count "${__marker_tag}..${__opt_branch}")"
            if [[ "${__opt_branch}" == "${__develop_branch}" ]]; then
                __version_increment="$((__version_increment - 1))"
            fi
        else
            __version_increment="$(($(git rev-list --count "${__opt_branch}") - 1))"
        fi
    fi

    # Output the calculated Semantic Version
    local __semver="${__version_major}.${__version_minor}.${__version_patch}-${__pre_release}.${__version_increment}"
    if ${__opt_json}; then
        cat <<EOF
{
  "semver": "${__semver}",
  "components": {
    "major": ${__version_major},
    "minor": ${__version_minor},
    "patch": ${__version_patch},
    "pre_release": "${__pre_release}",
    "increment": ${__version_increment}
  }
}
EOF
    else
        echo "${__semver}"
    fi
}

#-----------------------------------------------------------------------------
# Command Callbacks
#-----------------------------------------------------------------------------

__command_show_version() {
    __semver_calculate
}

__command_create_release_branch() {
    # Save the original value of __opt_json in __opt_json_saved
    local __opt_json_saved="${__opt_json}"

    # Define the base branch (develop) from which to create the release branch
    __opt_branch="${__opt_project_name:+${__opt_project_name}/}develop"
    __opt_json=false

    # Calculate the next semantic version and strip any pre-release or build metadata
    local __version
    __version="$(__semver_calculate)"
    __version="${__version%%-*}"

    # Restore the original value of __opt_json from __opt_json_saved
    __opt_json="${__opt_json_saved}"

    # Define release branch and marker tag
    __release_branch="release/v${__version}"
    __marker_tag="v${__version}-release-start-marker"

    # Check if the release branch already exists to avoid duplicates
    if __git_branch_exists "${__release_branch}"; then
        __error_log "release branch '${__release_branch}' already exists"
    fi

    # Create the release branch and push it to the remote repository
    git branch "${__release_branch}" "${__opt_branch}"
    git push "${__opt_remote}" "${__release_branch}"

    # Check if the release start marker tag already exists
    if __git_tag_exists "${__marker_tag}"; then
        __error_log "marker tag '${__marker_tag}' already exists"
    fi

    # Create and push the release start marker tag
    git tag -a "${__marker_tag}" -m "release start marker for version '${__version}'" "${__release_branch}"
    git push "${__opt_remote}" "${__marker_tag}"

    # Verbose output to display the created branch and tag
    if ! ${__opt_quiet}; then
        if ${__opt_json}; then
            cat <<EOF
{
  "branch": "${__release_branch}",
  "tag": "${__marker_tag}"
}
EOF
        else
            echo "branch: ${__release_branch}"
            echo "tag: ${__marker_tag}"
        fi
    fi
}

__command_create_hotfix_branch() {
    # Extract version from the branch name (assumes version is in the format v<version>)
    local __version="${__opt_branch##*v}"

    # Check if a stable tag exists for the given version and release type
    local __stable_tag_exists=false
    local __release_type

    # Loop through each possible release type to check for a stable tag
    for __release_type in "${__RELEASE_TYPES[@]}"; do
        local __stable_tag="v${__version}-${__release_type}"

        # If a stable tag is found, set the flag to true and exit the loop
        if __git_tag_exists "${__stable_tag}"; then
            __stable_tag_exists=true
            break
        fi
    done

    # Log an error if no stable tag exists for the given version
    if ! ${__stable_tag_exists}; then
        __error_log "stable tag for version '${__version}' does not exist"
    fi

    # Increment the patch version for the hotfix (e.g., v1.2.3 becomes v1.2.4)
    IFS='.' read -r __version_major __version_minor __version_patch <<<"${__version}"
    __version="${__version_major}.${__version_minor}.$((__version_patch + 1))"

    # Define the hotfix branch name and marker tag format
    __hotfix_branch="hotfix/v${__version}"
    __marker_tag="v${__version}-hotfix-start-marker"

    # Check if the hotfix branch already exists to avoid duplicates
    if __git_branch_exists "${__hotfix_branch}"; then
        __error_log "hotfix branch '${__hotfix_branch}' already exists"
    fi

    # Create the hotfix branch and push it to the remote repository
    git branch "${__hotfix_branch}" "${__opt_branch}"
    git push "${__opt_remote}" "${__hotfix_branch}"

    # Check if the hotfix start marker tag already exists
    if __git_tag_exists "${__marker_tag}"; then
        __error_log "marker tag '${__marker_tag}' already exists"
    fi

    # Create and push the hotfix start marker tag
    git tag -a "${__marker_tag}" -m "hotfix start marker for version '${__version}'" "${__hotfix_branch}"
    git push "${__opt_remote}" "${__marker_tag}"

    # Verbose output to display the created branch and tag
    if ! ${__opt_quiet}; then
        if ${__opt_json}; then
            cat <<EOF
{
  "branch": "${__hotfix_branch}",
  "tag": "${__marker_tag}"
}
EOF
        else
            echo "branch: ${__hotfix_branch}"
            echo "tag: ${__marker_tag}"
        fi
    fi
}

__command_finish_release_branch() {
    # Extract version from the branch name (assumes version is in the format v<version>)
    local __version="${__opt_branch##*v}"
    local __stable_tag="v${__version}-${__opt_release_type}"

    # Check if the stable tag already exists to avoid duplicates
    if __git_tag_exists "${__stable_tag}"; then
        __error_log "stable tag '${__stable_tag}' already exists"
    fi

    # Create the annotated stable tag and push it to the remote repository
    git tag -a "${__stable_tag}" -m "stable version ${__version} (${__opt_release_type})" "${__opt_branch}"
    git push "${__opt_remote}" "${__stable_tag}"

    # Verbose output to display the created stable tag
    if ! ${__opt_quiet}; then
        if ${__opt_json}; then
            cat <<EOF
{
  "tag": "${__stable_tag}"
}
EOF
        else
            echo "tag: ${__stable_tag}"
        fi
    fi
}

__command_changelog_from_tag_to_tag() {
    local __stable_tag="${__opt_branch}"
    local __develop_branch="develop"

    # Fail fast if tag does not exist
    if ! git rev-parse -q --verify "refs/tags/${__stable_tag}" >/dev/null; then
        __error_log "Tag '${__stable_tag}' does not exist"
    fi

    # Extract version numbers: major, minor, patch
    local __version="${__stable_tag#v}"
    __version="${__version%%-*}"
    IFS='.' read -r __major __minor __patch <<<"$__version"

    local __is_hotfix=false
    [[ "${__patch}" != "0" ]] && __is_hotfix=true

    # Determine start marker
    local __start_marker
    local __first_commit
    __first_commit="$(git rev-list --max-parents=0 "${__develop_branch}" | tail -n 1)"

    if [[ "$__is_hotfix" == true ]]; then
        # Hotfix: find closest hotfix start marker
        local __release_tag="$(__marker_tag_get_closest "hotfix/v${__major}.${__minor}.${__patch}" "${__develop_branch}" "v*-hotfix-start-marker")"
        if git rev-parse -q --verify "refs/tags/${__release_tag}" >/dev/null; then
            __start_marker="${__release_tag}"
        else
            echo "Error: cannot find hotfix start marker" >&2
            exit 1
        fi
    else
        # Release: previous release-start-marker or first commit
        local __prev_release
        __prev_release="$(git tag --list "v*-release-start-marker" | sort -V | awk -v tag="v${__version}-release-start-marker" '
            $0 == tag { exit } 
            { prev = $0 } 
            END { print prev }
        ')"
        __start_marker="${__prev_release:-$__first_commit}"
    fi

    # Compute range, include start commit if it's the first commit
    local __range
    if [[ "${__start_marker}" == "${__first_commit}" ]]; then
        __range="${__start_marker} ${__stable_tag}"
    else
        __range="${__start_marker}..${__stable_tag}"
    fi

    echo "range is: $__range"
    # Compute changelog
    local __log_output
    __log_output="$(git log ${__range} --pretty=format:"* [%h] %ad — %s (%an)" --date=short)"

    # Output
    echo "Changelog between $__start_marker → $__stable_tag: release $__stable_tag"
    echo "=========================================================================="
    echo "$__log_output"
}


__command_finish_hotfix_branch() {
    # Reuse the logic from the finish release branch function
    __command_finish_release_branch
}

#=============================================================================
# Main Function

main() {
    # Parse command-line options
    __command_line_parse "${@}"

    # Check if the script is executed within a valid Git repository
    if ! __git_is_repo_valid; then
        __error_log "current directory is not a valid Git repository or the HEAD reference is missing"
    fi

    # Validate the parsed options and arguments
    __command_line_validate

    # Execute the command based on the user's input
    case "${__arg_command}" in
    show-version)
        __command_show_version
        ;;
    create-release-branch)
        __command_create_release_branch
        ;;
    create-hotfix-branch)
        __command_create_hotfix_branch
        ;;
    finish-release-branch)
        __command_finish_release_branch
        ;;
    finish-hotfix-branch)
        __command_finish_hotfix_branch
        ;;
    create-changelog)
        __command_changelog_from_tag_to_tag
        ;;
    esac
}

# Execute the main function with provided arguments
main "${@}"