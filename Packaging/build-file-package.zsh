#!/bin/zsh
#
# Build a macOS Installer component package from explicit file and directory-tree mappings.
#
# Each --map argument defines one regular source file, its absolute installation path,
# and its installed permission mode. Each --tree recursively maps a source directory.
# The builder never executes package content and never follows source symlinks.

setopt ERR_EXIT NO_UNSET PIPE_FAIL

typeset -gr PKGBUILD_BINARY="/usr/bin/pkgbuild"
typeset -gr PKGUTIL_BINARY="/usr/sbin/pkgutil"
typeset -gr MKTEMP_BINARY="/usr/bin/mktemp"
typeset -gr INSTALL_BINARY="/usr/bin/install"
typeset -gr XATTR_BINARY="/usr/bin/xattr"
typeset -gr CHMOD_BINARY="/bin/chmod"

typeset -g STAGING_DIRECTORY=""
typeset -ga SOURCE_FILES=()
typeset -ga DESTINATION_PATHS=()
typeset -ga FILE_MODES=()
typeset -ga TREE_SOURCE_DIRECTORIES=()
typeset -ga TREE_DESTINATION_DIRECTORIES=()
typeset -ga TREE_FILE_MODES=()
typeset -ga TREE_DIRECTORY_MODES=()
typeset -ga EXPECTED_PAYLOAD_PATHS=()

function usage ()
{
	# PURPOSE: Print the command-line contract.
	# PARMS: None
	# RETURN: Always 0.

	local output_stream="${1:-1}"

	/bin/cat >&${output_stream} <<'USAGE'
Usage:
  build-file-package.zsh \
    --identifier REVERSE_DNS_ID \
    --version NUMERIC_VERSION \
    --output OUTPUT.pkg \
    [--sign "Developer ID Installer: Organization (TEAMID)"] \
    [--map SOURCE_FILE ABSOLUTE_DESTINATION MODE ...] \
    [--tree SOURCE_DIRECTORY ABSOLUTE_DESTINATION FILE_MODE DIRECTORY_MODE ...]

Options:
  --identifier ID        Stable lowercase reverse-DNS package identifier.
  --version VERSION      One to four dot-separated numeric components.
  --output PATH          New .pkg output path; existing paths are never replaced.
  --sign IDENTITY        Optional Installer signing identity passed to pkgbuild.
  --map SOURCE DEST MODE Add a regular file mapping. MODE is owner-readable
                         400-777, with an optional leading zero. Repeatable.
  --tree SOURCE DEST FILE_MODE DIRECTORY_MODE
                         Recursively map a directory. FILE_MODE is 400-777;
                         DIRECTORY_MODE is owner-readable/searchable 500-777.
                         Repeatable. At least one --map or --tree is required.
  --help                 Show this help.

Example:
  build-file-package.zsh \
    --identifier com.example.jamf.branding-assets \
    --version 1.0.0 \
    --output Packaging/dist/BrandingAssets-1.0.0.pkg \
    --map ./SwiftDialog-Banner.png \
      "/Library/Application Support/JamfProScripts/BrandingAssets/SwiftDialog-Banner.png" \
      0644
USAGE
	return 0
}

function fail ()
{
	# PURPOSE: Report a fatal validation or build error.
	# PARMS: $1 - Error message.
	# RETURN: Always 1.

	print -u2 -r -- "ERROR: ${1}"
	return 1
}

function require_option_arguments ()
{
	# PURPOSE: Ensure an option has the required number of following arguments.
	# PARMS: $1 - Option; $2 - required count; $3 - available count.
	# RETURN: 0 when enough arguments remain; otherwise 1.

	local option_name="$1"
	local required_count="$2"
	local available_count="$3"

	(( available_count >= required_count )) || fail "${option_name} requires ${required_count} argument(s)."
}

function validate_package_identifier ()
{
	# PURPOSE: Validate a stable lowercase reverse-DNS package identifier.
	# PARMS: $1 - Identifier.
	# RETURN: 0 when every dot-separated segment is safe; otherwise 1.

	local identifier="$1"
	local segment
	local segment_pattern='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
	local -a segments

	[[ -n "${identifier}" && "${identifier}" != *[[:cntrl:]]* ]] || return 1
	segments=("${(@s:.:)identifier}")
	(( ${#segments} >= 2 )) || return 1
	for segment in "${segments[@]}"; do
		[[ "${segment}" =~ ${segment_pattern} ]] || return 1
	done
	return 0
}

function validate_package_version ()
{
	# PURPOSE: Validate a predictable Installer package version.
	# PARMS: $1 - Version.
	# RETURN: 0 for one to four numeric components; otherwise 1.

	local version="$1"
	local version_pattern='^[0-9]+(\.[0-9]+){0,3}$'

	[[ "${version}" =~ ${version_pattern} ]]
}

function validate_file_mode ()
{
	# PURPOSE: Validate ordinary permission bits without setuid, setgid, or sticky bits.
	# PARMS: $1 - Mode.
	# RETURN: 0 for owner-readable 400-777 with an optional leading zero; otherwise 1.

	local mode="$1"
	local mode_pattern='^0?[4-7][0-7]{2}$'

	[[ "${mode}" =~ ${mode_pattern} ]]
}

function validate_directory_mode ()
{
	# PURPOSE: Validate directory permissions that allow pkgbuild to read and traverse.
	# PARMS: $1 - Mode.
	# RETURN: 0 for 500-577 or 700-777 with an optional leading zero; otherwise 1.

	local mode="$1"
	local mode_pattern='^0?[57][0-7]{2}$'

	[[ "${mode}" =~ ${mode_pattern} ]]
}

function validate_absolute_install_path ()
{
	# PURPOSE: Validate one absolute, traversal-free installation path.
	# PARMS: $1 - Destination file or directory path.
	# RETURN: 0 when the path is absolute, non-root, and unambiguous; otherwise 1.

	local destination_path="$1"
	local path_with_boundaries

	[[ -n "${destination_path}" && "${destination_path}" == /* ]] || return 1
	[[ "${destination_path}" != "/" && "${destination_path}" != *[[:cntrl:]]* ]] || return 1
	path_with_boundaries="/${destination_path#/}/"
	[[ "${path_with_boundaries}" != *'/../'* ]] || return 1
	[[ "${path_with_boundaries}" != *'/./'* ]] || return 1
	[[ "${path_with_boundaries}" != *'//'* ]]
}

function is_ignored_tree_relative_path ()
{
	# PURPOSE: Identify Finder metadata that must not enter an implicit tree payload.
	# PARMS: $1 - Relative path below a tree source.
	# RETURN: 0 when any path component is exactly .DS_Store; otherwise 1.

	local relative_path="$1"
	local path_with_boundaries="/${relative_path#/}/"

	[[ "${path_with_boundaries}" == *'/.DS_Store/'* ]]
}

function parse_arguments ()
{
	# PURPOSE: Parse the explicit package-build command line.
	# PARMS: Command-line arguments.
	# RETURN: 0 with configuration in REPLY fields and mapping arrays; otherwise 1.

	typeset -g PACKAGE_IDENTIFIER=""
	typeset -g PACKAGE_VERSION=""
	typeset -g OUTPUT_PACKAGE=""
	typeset -g SIGNING_IDENTITY=""
	local -i identifier_seen=0
	local -i version_seen=0
	local -i output_seen=0
	local -i signing_identity_seen=0

	while (( $# > 0 )); do
		case "$1" in
			--identifier)
				require_option_arguments "$1" 1 $(( $# - 1 )) || return 1
				(( identifier_seen == 0 )) || fail "--identifier may be specified only once." || return 1
				identifier_seen=1
				PACKAGE_IDENTIFIER="$2"
				shift 2
				;;
			--version)
				require_option_arguments "$1" 1 $(( $# - 1 )) || return 1
				(( version_seen == 0 )) || fail "--version may be specified only once." || return 1
				version_seen=1
				PACKAGE_VERSION="$2"
				shift 2
				;;
			--output)
				require_option_arguments "$1" 1 $(( $# - 1 )) || return 1
				(( output_seen == 0 )) || fail "--output may be specified only once." || return 1
				output_seen=1
				OUTPUT_PACKAGE="$2"
				shift 2
				;;
			--sign)
				require_option_arguments "$1" 1 $(( $# - 1 )) || return 1
				(( signing_identity_seen == 0 )) || fail "--sign may be specified only once." || return 1
				[[ -n "$2" ]] || fail "--sign requires a non-empty Installer identity." || return 1
				signing_identity_seen=1
				SIGNING_IDENTITY="$2"
				shift 2
				;;
			--map)
				require_option_arguments "$1" 3 $(( $# - 1 )) || return 1
				SOURCE_FILES+=("$2")
				DESTINATION_PATHS+=("$3")
				FILE_MODES+=("$4")
				shift 4
				;;
			--tree)
				require_option_arguments "$1" 4 $(( $# - 1 )) || return 1
				TREE_SOURCE_DIRECTORIES+=("$2")
				TREE_DESTINATION_DIRECTORIES+=("$3")
				TREE_FILE_MODES+=("$4")
				TREE_DIRECTORY_MODES+=("$5")
				shift 5
				;;
			--help|-h)
				usage 1
				exit 0
				;;
			*)
				fail "Unknown argument: $1"
				return 1
				;;
		esac
	done

	return 0
}

function validate_configuration ()
{
	# PURPOSE: Validate tools, package metadata, output, and every source/destination mapping.
	# PARMS: Parsed global configuration.
	# RETURN: 0 after normalizing sources, modes, and output; otherwise 1.

	local source_file
	local destination_path
	local mapping_index
	local other_index
	local first_destination
	local second_destination
	local output_parent
	local tree_index
	local tree_source_directory
	local tree_destination_directory
	local tree_entry
	local tree_relative_path
	local first_tree_destination
	local second_tree_destination
	local normalized_tree_relative_path
	local -a tree_entries
	local -A seen_tree_relative_paths

	[[ -x "${PKGBUILD_BINARY}" ]] || fail "pkgbuild is unavailable at ${PKGBUILD_BINARY}." || return 1
	[[ -x "${PKGUTIL_BINARY}" ]] || fail "pkgutil is unavailable at ${PKGUTIL_BINARY}." || return 1
	validate_package_identifier "${PACKAGE_IDENTIFIER}" || fail "Invalid package identifier: ${PACKAGE_IDENTIFIER:-<empty>}" || return 1
	validate_package_version "${PACKAGE_VERSION}" || fail "Invalid package version: ${PACKAGE_VERSION:-<empty>}" || return 1
	(( ${#SOURCE_FILES} + ${#TREE_SOURCE_DIRECTORIES} > 0 )) || fail "At least one --map or --tree is required." || return 1
	[[ -n "${OUTPUT_PACKAGE}" && "${OUTPUT_PACKAGE}" == *.pkg && "${OUTPUT_PACKAGE:t}" != ".pkg" && "${OUTPUT_PACKAGE}" != *[[:cntrl:]]* ]] || {
		fail "Output must be a non-empty .pkg path without control characters."
		return 1
	}
	[[ -z "${SIGNING_IDENTITY}" || "${SIGNING_IDENTITY}" != *[[:cntrl:]]* ]] || fail "Signing identity contains control characters." || return 1

	for (( mapping_index = 1; mapping_index <= ${#SOURCE_FILES}; mapping_index++ )); do
		source_file="${SOURCE_FILES[${mapping_index}]}"
		destination_path="${DESTINATION_PATHS[${mapping_index}]}"

		[[ -n "${source_file}" && "${source_file}" != *[[:cntrl:]]* ]] || fail "Source path ${mapping_index} is empty or contains control characters." || return 1
		[[ -f "${source_file}" && ! -L "${source_file}" && -r "${source_file}" ]] || fail "Source must be a readable, non-symlinked regular file: ${source_file}" || return 1
		validate_absolute_install_path "${destination_path}" || fail "Invalid destination path: ${destination_path:-<empty>}" || return 1
		validate_file_mode "${FILE_MODES[${mapping_index}]}" || fail "Invalid file mode for ${destination_path}: ${FILE_MODES[${mapping_index}]}" || return 1

		SOURCE_FILES[${mapping_index}]="${source_file:A}"
		if (( ${#FILE_MODES[${mapping_index}]} == 4 )); then
			FILE_MODES[${mapping_index}]="${FILE_MODES[${mapping_index}]#0}"
		fi
	done

	for (( tree_index = 1; tree_index <= ${#TREE_SOURCE_DIRECTORIES}; tree_index++ )); do
		tree_source_directory="${TREE_SOURCE_DIRECTORIES[${tree_index}]}"
		tree_destination_directory="${TREE_DESTINATION_DIRECTORIES[${tree_index}]}"

		[[ -n "${tree_source_directory}" && "${tree_source_directory}" != *[[:cntrl:]]* ]] || fail "Tree source path ${tree_index} is empty or contains control characters." || return 1
		[[ -d "${tree_source_directory}" && ! -L "${tree_source_directory}" && -r "${tree_source_directory}" && -x "${tree_source_directory}" ]] || fail "Tree source must be a readable, searchable, non-symlinked directory: ${tree_source_directory}" || return 1
		validate_absolute_install_path "${tree_destination_directory}" || fail "Invalid tree destination: ${tree_destination_directory:-<empty>}" || return 1
		validate_file_mode "${TREE_FILE_MODES[${tree_index}]}" || fail "Invalid tree file mode for ${tree_destination_directory}: ${TREE_FILE_MODES[${tree_index}]}" || return 1
		validate_directory_mode "${TREE_DIRECTORY_MODES[${tree_index}]}" || fail "Invalid tree directory mode for ${tree_destination_directory}: ${TREE_DIRECTORY_MODES[${tree_index}]}" || return 1

		TREE_SOURCE_DIRECTORIES[${tree_index}]="${tree_source_directory:A}"
		if (( ${#TREE_FILE_MODES[${tree_index}]} == 4 )); then
			TREE_FILE_MODES[${tree_index}]="${TREE_FILE_MODES[${tree_index}]#0}"
		fi
		if (( ${#TREE_DIRECTORY_MODES[${tree_index}]} == 4 )); then
			TREE_DIRECTORY_MODES[${tree_index}]="${TREE_DIRECTORY_MODES[${tree_index}]#0}"
		fi

		tree_entries=("${TREE_SOURCE_DIRECTORIES[${tree_index}]}"/**/*(DN))
		seen_tree_relative_paths=()
		for tree_entry in "${tree_entries[@]}"; do
			tree_relative_path="${tree_entry#${TREE_SOURCE_DIRECTORIES[${tree_index}]}/}"
			[[ -n "${tree_relative_path}" && "${tree_relative_path}" != *[[:cntrl:]]* ]] || fail "Tree entry contains an unsupported control character: ${tree_entry}" || return 1
			normalized_tree_relative_path="${tree_relative_path:l}"
			if (( ${+seen_tree_relative_paths[${normalized_tree_relative_path}]} )); then
				fail "Tree contains a case-insensitive path collision: ${seen_tree_relative_paths[${normalized_tree_relative_path}]} and ${tree_relative_path}"
				return 1
			fi
			seen_tree_relative_paths[${normalized_tree_relative_path}]="${tree_relative_path}"
			[[ ! -L "${tree_entry}" ]] || fail "Tree sources must not contain symbolic links: ${tree_entry}" || return 1
			if [[ -d "${tree_entry}" ]]; then
				[[ -r "${tree_entry}" && -x "${tree_entry}" ]] || fail "Tree directory is not readable and searchable: ${tree_entry}" || return 1
			elif [[ -f "${tree_entry}" ]]; then
				[[ -r "${tree_entry}" ]] || fail "Tree file is not readable: ${tree_entry}" || return 1
			else
				fail "Tree sources may contain only regular files and directories: ${tree_entry}"
				return 1
			fi
		done
	done

	# Compare case-insensitively because most managed Macs use case-insensitive APFS.
	for (( mapping_index = 1; mapping_index <= ${#DESTINATION_PATHS}; mapping_index++ )); do
		for (( other_index = mapping_index + 1; other_index <= ${#DESTINATION_PATHS}; other_index++ )); do
			first_destination="${DESTINATION_PATHS[${mapping_index}]:l}"
			second_destination="${DESTINATION_PATHS[${other_index}]:l}"
			[[ "${first_destination}" != "${second_destination}" ]] || fail "Duplicate case-insensitive destination: ${DESTINATION_PATHS[${other_index}]}" || return 1
			if [[ "${second_destination}" == "${first_destination}/"* ||
				  "${first_destination}" == "${second_destination}/"* ]]; then
				fail "File mappings have a parent/child destination collision: ${DESTINATION_PATHS[${mapping_index}]} and ${DESTINATION_PATHS[${other_index}]}"
				return 1
			fi
		done
	done

	# Tree roots cannot overlap because their uniform modes and content ownership would be ambiguous.
	for (( tree_index = 1; tree_index <= ${#TREE_DESTINATION_DIRECTORIES}; tree_index++ )); do
		for (( other_index = tree_index + 1; other_index <= ${#TREE_DESTINATION_DIRECTORIES}; other_index++ )); do
			first_tree_destination="${TREE_DESTINATION_DIRECTORIES[${tree_index}]:l}"
			second_tree_destination="${TREE_DESTINATION_DIRECTORIES[${other_index}]:l}"
			if [[ "${first_tree_destination}" == "${second_tree_destination}" ||
				  "${first_tree_destination}" == "${second_tree_destination}/"* ||
				  "${second_tree_destination}" == "${first_tree_destination}/"* ]]; then
				fail "Tree destinations overlap: ${TREE_DESTINATION_DIRECTORIES[${tree_index}]} and ${TREE_DESTINATION_DIRECTORIES[${other_index}]}"
				return 1
			fi
		done
	done

	# Explicit files and directory trees must remain disjoint at the installation boundary.
	for destination_path in "${DESTINATION_PATHS[@]}"; do
		for tree_destination_directory in "${TREE_DESTINATION_DIRECTORIES[@]}"; do
			first_destination="${destination_path:l}"
			first_tree_destination="${tree_destination_directory:l}"
			if [[ "${first_destination}" == "${first_tree_destination}" ||
				  "${first_destination}" == "${first_tree_destination}/"* ||
				  "${first_tree_destination}" == "${first_destination}/"* ]]; then
				fail "File and tree destinations overlap: ${destination_path} and ${tree_destination_directory}"
				return 1
			fi
		done
	done

	output_parent="${OUTPUT_PACKAGE:h}"
	/bin/mkdir -p "${output_parent}" || fail "Unable to create output directory: ${output_parent}" || return 1
	OUTPUT_PACKAGE="${OUTPUT_PACKAGE:A}"
	[[ ! -e "${OUTPUT_PACKAGE}" && ! -L "${OUTPUT_PACKAGE}" ]] || fail "Output already exists and will not be replaced: ${OUTPUT_PACKAGE}" || return 1

	return 0
}

function is_owned_staging_directory ()
{
	# PURPOSE: Constrain recursive cleanup to the exact directory created by this process.
	# PARMS: $1 - Candidate directory; $2 - normalized temporary parent.
	# RETURN: 0 only for the expected direct-child staging name; otherwise 1.

	local candidate_directory="$1"
	local temporary_parent="$2"

	[[ -n "${candidate_directory}" && "${candidate_directory:h}" == "${temporary_parent}" ]] || return 1
	[[ "${candidate_directory:t}" == BuildFilePackage.[[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]] ]]
}

function cleanup_staging_directory ()
{
	# PURPOSE: Remove only this builder's validated temporary staging directory.
	# PARMS: STAGING_DIRECTORY, TEMPORARY_PARENT
	# RETURN: 0 when no owned staging directory remains; otherwise 1.

	[[ -z "${STAGING_DIRECTORY}" ]] && return 0
	if ! is_owned_staging_directory "${STAGING_DIRECTORY}" "${TEMPORARY_PARENT}"; then
		fail "Refusing to remove unexpected staging directory: ${STAGING_DIRECTORY}"
		return 1
	fi
	[[ ! -e "${STAGING_DIRECTORY}" ]] && return 0
	[[ -d "${STAGING_DIRECTORY}" && ! -L "${STAGING_DIRECTORY}" ]] || fail "Staging path is not a removable directory: ${STAGING_DIRECTORY}" || return 1
	# Tree payloads may intentionally use read-only directory modes. Restore owner
	# write access only inside the validated staging root before recursive removal.
	/bin/chmod -R u+rwX "${STAGING_DIRECTORY}" || return 1
	/bin/rm -rf -- "${STAGING_DIRECTORY}"
}

function handle_exit ()
{
	# PURPOSE: Clean temporary build state while preserving the original result.
	# PARMS: $1 - Original process status.
	# RETURN: Does not return.

	local original_status="${1:-1}"
	local cleanup_status
	setopt LOCAL_OPTIONS NO_ERR_EXIT

	trap - EXIT HUP INT TERM
	cleanup_staging_directory
	cleanup_status=$?
	(( original_status == 0 && cleanup_status != 0 )) && original_status=1
	exit "${original_status}"
}

function handle_signal ()
{
	# PURPOSE: Convert a catchable signal to its conventional shell status.
	# PARMS: $1 - 128 plus signal number.
	# RETURN: Does not return; EXIT performs constrained cleanup.

	local signal_status="${1:-1}"

	trap - HUP INT TERM
	exit "${signal_status}"
}

function create_staged_payload ()
{
	# PURPOSE: Copy every validated file and tree mapping into an isolated destination root.
	# PARMS: Mapping arrays, STAGING_DIRECTORY.
	# RETURN: 0 when the complete payload is staged; otherwise 1.

	local mapping_index
	local payload_path
	local previous_umask
	local tree_index
	local tree_entry
	local tree_relative_path
	local tree_payload_root
	local staged_directory
	local -a tree_entries
	local -a staged_tree_directories

	previous_umask=$(umask)
	umask 022
	/bin/mkdir -p "${STAGING_DIRECTORY}/root"
	EXPECTED_PAYLOAD_PATHS=()

	for (( mapping_index = 1; mapping_index <= ${#SOURCE_FILES}; mapping_index++ )); do
		payload_path="${STAGING_DIRECTORY}/root${DESTINATION_PATHS[${mapping_index}]}"
		/bin/mkdir -p "${payload_path:h}"
		# Clear metadata before applying the requested final mode.
		"${INSTALL_BINARY}" -m 0600 "${SOURCE_FILES[${mapping_index}]}" "${payload_path}"
		"${XATTR_BINARY}" -c "${payload_path}"
		"${CHMOD_BINARY}" "${FILE_MODES[${mapping_index}]}" "${payload_path}"
		EXPECTED_PAYLOAD_PATHS+=("${DESTINATION_PATHS[${mapping_index}]}")
	done

	for (( tree_index = 1; tree_index <= ${#TREE_SOURCE_DIRECTORIES}; tree_index++ )); do
		tree_payload_root="${STAGING_DIRECTORY}/root${TREE_DESTINATION_DIRECTORIES[${tree_index}]}"
		/bin/mkdir -p "${tree_payload_root}"
		staged_tree_directories=("${tree_payload_root}")
		EXPECTED_PAYLOAD_PATHS+=("${TREE_DESTINATION_DIRECTORIES[${tree_index}]}")

		tree_entries=("${TREE_SOURCE_DIRECTORIES[${tree_index}]}"/**/*(DN))
		for tree_entry in "${tree_entries[@]}"; do
			tree_relative_path="${tree_entry#${TREE_SOURCE_DIRECTORIES[${tree_index}]}/}"
			[[ -n "${tree_relative_path}" && "${tree_relative_path}" != *[[:cntrl:]]* ]] || fail "Tree changed to contain an unsupported path: ${tree_entry}" || return 1
			[[ ! -L "${tree_entry}" ]] || fail "Tree changed to contain a symbolic link: ${tree_entry}" || return 1
			is_ignored_tree_relative_path "${tree_relative_path}" && continue

			payload_path="${tree_payload_root}/${tree_relative_path}"
			if [[ -d "${tree_entry}" ]]; then
				/bin/mkdir -p "${payload_path}"
				staged_tree_directories+=("${payload_path}")
				EXPECTED_PAYLOAD_PATHS+=("${TREE_DESTINATION_DIRECTORIES[${tree_index}]}/${tree_relative_path}")
			elif [[ -f "${tree_entry}" && -r "${tree_entry}" ]]; then
				/bin/mkdir -p "${payload_path:h}"
				"${INSTALL_BINARY}" -m 0600 "${tree_entry}" "${payload_path}"
				"${XATTR_BINARY}" -c "${payload_path}"
				"${CHMOD_BINARY}" "${TREE_FILE_MODES[${tree_index}]}" "${payload_path}"
				EXPECTED_PAYLOAD_PATHS+=("${TREE_DESTINATION_DIRECTORIES[${tree_index}]}/${tree_relative_path}")
			else
				fail "Tree changed to contain an unreadable or special file: ${tree_entry}"
				return 1
			fi
		done

		# Apply directory modes after population so read-only destination trees remain buildable.
		for staged_directory in "${staged_tree_directories[@]}"; do
			"${CHMOD_BINARY}" "${TREE_DIRECTORY_MODES[${tree_index}]}" "${staged_directory}"
		done
	done
	umask "${previous_umask}"
	return 0
}

function verify_built_package ()
{
	# PURPOSE: Verify that pkgbuild emitted a package containing every mapped destination.
	# PARMS: $1 - Built package path.
	# RETURN: 0 when the package and optional signature pass verification; otherwise 1.

	local package_path="$1"
	local destination_path
	local expected_payload_path
	local payload_entry
	local payload_listing
	local found_entry

	[[ -f "${package_path}" && ! -L "${package_path}" ]] || fail "pkgbuild did not create a regular package." || return 1
	payload_listing=$("${PKGUTIL_BINARY}" --payload-files "${package_path}") || fail "Unable to inspect built package payload." || return 1

	for destination_path in "${EXPECTED_PAYLOAD_PATHS[@]}"; do
		expected_payload_path="${destination_path#/}"
		found_entry=0
		for payload_entry in "${(f)payload_listing}"; do
			if [[ "${payload_entry#./}" == "${expected_payload_path}" ]]; then
				found_entry=1
				break
			fi
		done
		(( found_entry == 1 )) || fail "Built package is missing payload path: ${destination_path}" || return 1
	done

	if [[ -n "${SIGNING_IDENTITY}" ]]; then
		"${PKGUTIL_BINARY}" --check-signature "${package_path}" >/dev/null || fail "Built package signature verification failed." || return 1
	fi
	return 0
}

function build_package ()
{
	# PURPOSE: Build, inspect, and atomically publish the validated component package.
	# PARMS: Parsed global configuration and staging directory.
	# RETURN: 0 when the final package is published; otherwise 1.

	local staged_package="${STAGING_DIRECTORY}/output.pkg"
	local -a pkgbuild_arguments

	create_staged_payload
	pkgbuild_arguments=(
		--root "${STAGING_DIRECTORY}/root"
		--install-location "/"
		--identifier "${PACKAGE_IDENTIFIER}"
		--version "${PACKAGE_VERSION}"
		--ownership recommended
	)
	[[ -n "${SIGNING_IDENTITY}" ]] && pkgbuild_arguments+=(--sign "${SIGNING_IDENTITY}")

	"${PKGBUILD_BINARY}" "${pkgbuild_arguments[@]}" "${staged_package}"
	verify_built_package "${staged_package}"
	/bin/mv -n "${staged_package}" "${OUTPUT_PACKAGE}"
	[[ ! -e "${staged_package}" && -f "${OUTPUT_PACKAGE}" && ! -L "${OUTPUT_PACKAGE}" ]] || fail "Output appeared during the build and was not replaced: ${OUTPUT_PACKAGE}" || return 1
	print -r -- "Built package: ${OUTPUT_PACKAGE}"
	return 0
}

parse_arguments "$@" || {
	usage 2
	exit 2
}
validate_configuration || exit 2

TEMPORARY_PARENT="${OUTPUT_PACKAGE:h}"
[[ -n "${TEMPORARY_PARENT}" && "${TEMPORARY_PARENT}" == /* && -d "${TEMPORARY_PARENT}" ]] || {
	fail "The normalized output directory is unavailable: ${TEMPORARY_PARENT}"
	exit 1
}

# Install lifecycle traps before creating temporary state.
trap 'handle_exit $?' EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

STAGING_DIRECTORY=$("${MKTEMP_BINARY}" -d "${TEMPORARY_PARENT}/BuildFilePackage.XXXXXX") || {
	fail "Unable to create package staging directory."
	exit 1
}

build_package
