#!/bin/zsh
#
# AppDelete
# Purpose: Allow end users to delete apps / folders using Swift Dialog
#
# Written: 8/3/2022
# Last updated: 04/01/2026
#
# 1.0 - Initial Release
# 1.1 - Major code cleanup & documentation
#		Structured code to be more inline / consistent across all apps
# 1.2 - Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore...
# 2.0 - Bumped Swift Dialog min version to 2.5.0
#		NEW: Added option to allow folders to be deleted (ALLOWED_FOLDERS)
#		Put shadows in the banner text
# 		Reordered sections to better show what can be modified
# 2.1 - Added option to sort array (case insensitive) after the application scan & folders added 
# 2.2 - Code cleanup
#       Added feature to read in defaults file
#       removed unnecessary variables.
#       Fixed typos
# 2.3 - Add logic in the delete_files section to not continue processing if name is blank
#		Fixed issue with reading in the defaults file and setting the variables.
# 2.4	Changed JAMF 'policy -trigger' to 'JAMF policy -event'
#       Optimized "Common" section for better performance
#       Fixed variable names in the defaults file section
# 2.5 - Updated SD Version requirements to 3.1.0
#       Added ability to set subtitle, color, and padding from defaults file
# 2.6 - Secured the deletion boundary against local selection-file tampering and path traversal
#       Keep dialog configuration root-only and hold selections in process memory
#       Validate opaque dialog item IDs against exact /Applications targets before deletion
# 2.7 - Enforce protected applications through a validated, case-normalized exact-match policy
#       Recheck protection immediately before deletion and prevent ALLOWED_FOLDERS app bypasses
# 2.8 - Document and fail closed on external Jamf policy dependencies
#       Rename the branding-assets event and make its local asset directory configurable
# 2.9 - Track and report successful and failed deletions independently
#       Preserve a nonzero session result after any requested deletion fails
# 3.0 - Generate and parse Swift Dialog JSON with Apple's structured jq processor
#       Enforce a bounded, flat, duplicate-free opaque-ID/Boolean response schema
######################################################################################################
#
# Global "Common" variables
#
######################################################################################################

SCRIPT_NAME="AppDelete"
APPLICATIONS_DIR="/Applications"
TEMP_DIR="/var/tmp"
APPDELETE_IS_SOURCED=0
[[ "${ZSH_EVAL_CONTEXT}" == *:file ]] && APPDELETE_IS_SOURCED=1

if [[ ${APPDELETE_IS_SOURCED} -eq 0 && ${EUID} -ne 0 ]]; then
	print -u2 -- "ERROR: ${SCRIPT_NAME} must run as root through Jamf Pro or sudo."
	exit 1
fi

if [[ ${APPDELETE_IS_SOURCED} -eq 0 ]]; then
	LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
	USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )
	FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
	MACOS_NAME=$(sw_vers -productName)
	MACOS_VERSION=$(sw_vers -productVersion)
	MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
	MAC_CPU=$(sysctl -n machdep.cpu.brand_string)
	SD_DIALOG_GREETING=$((){print Good ${argv[2+($1>11)+($1>18)]}} ${(%):-%D{%H}} morning afternoon evening)
else
	LOGGED_IN_USER=""
	USER_DIR=""
	FREE_DISK_SPACE=0
	MACOS_NAME=""
	MACOS_VERSION=""
	MAC_RAM=""
	MAC_CPU=""
	SD_DIALOG_GREETING=""
fi

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="3.1.0"
[[ ${APPDELETE_IS_SOURCED} -eq 0 && -x "${SW_DIALOG}" ]] && SD_VERSION=$( "${SW_DIALOG}" --version) || SD_VERSION="0.0.0"

# The JSON configuration file is created with mode 0600 during runtime.
# Selection state is intentionally never written to disk.

JSON_OPTIONS=""

###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################

function initialize_branding_configuration ()
{
	# PURPOSE: Validate the branding directory and resolve the configured banner to a local path.
	# PARMS: BRANDING_ASSETS_DIR, SD_BANNER_IMAGE
	# RETURN: 0 with normalized configuration; otherwise 1.

	local configured_directory="${BRANDING_ASSETS_DIR}"
	local configured_image="${SD_BANNER_IMAGE}"
	local path_with_boundaries

	if [[ -z "${configured_directory}" || "${configured_directory}" != /* ||
		  "${configured_directory}" == *[[:cntrl:]]* ]]; then
		return 1
	fi

	while [[ "${configured_directory}" != "/" && "${configured_directory}" == */ ]]; do
		configured_directory="${configured_directory%/}"
	done

	path_with_boundaries="/${configured_directory#/}/"
	if [[ "${path_with_boundaries}" == *'/../'* || "${path_with_boundaries}" == *'/./'* ||
		  "${path_with_boundaries}" == *'//'* ]]; then
		return 1
	fi

	if [[ -z "${configured_image}" || "${configured_image}" == *[[:cntrl:]]* ]]; then
		return 1
	fi

	if [[ "${configured_image}" == /* ]]; then
		path_with_boundaries="/${configured_image#/}/"
		if [[ "${path_with_boundaries}" == *'/../'* || "${path_with_boundaries}" == *'/./'* ||
			  "${path_with_boundaries}" == *'//'* ]]; then
			return 1
		fi
	else
		# Relative banner values are filenames, not paths; the directory has its own setting.
		[[ "${configured_image}" == */* || "${configured_image}" == "." || "${configured_image}" == ".." ]] && return 1
		configured_image="${configured_directory%/}/${configured_image}"
	fi

	case "${configured_image:l}" in
		*.jpg | *.jpeg | *.png | *.heic ) ;;
		* ) return 1 ;;
	esac

	BRANDING_ASSETS_DIR="${configured_directory}"
	SD_BANNER_IMAGE="${configured_image}"
	return 0
}

# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_DIR="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
if [[ ${APPDELETE_IS_SOURCED} -eq 0 && -f "$DEFAULTS_DIR" ]]; then
    echo "Found Defaults Files.  Reading in Info"
	SUPPORT_DIR=$(/usr/bin/defaults read "$DEFAULTS_DIR" SupportFiles 2>/dev/null)
	BRANDING_ASSETS_DIR=$(/usr/bin/defaults read "$DEFAULTS_DIR" BrandingAssetsDirectory 2>/dev/null)
	SD_BANNER_IMAGE=$(/usr/bin/defaults read "$DEFAULTS_DIR" BannerImage 2>/dev/null)
	BANNER_TEXT_PADDING=$(/usr/bin/defaults read "$DEFAULTS_DIR" BannerPadding 2>/dev/null)
	BANNER_SUBTITLE=$(/usr/bin/defaults read "$DEFAULTS_DIR" BannerSubtitle 2>/dev/null)
	BANNER_TEXT_COLOR=$(/usr/bin/defaults read "$DEFAULTS_DIR" TitleFontColor 2>/dev/null)
fi
[[ -z "$SUPPORT_DIR" ]] && SUPPORT_DIR="/Library/Application Support/GiantEagle"
[[ -z "$BRANDING_ASSETS_DIR" ]] && BRANDING_ASSETS_DIR="${SUPPORT_DIR}"
[[ -z "$SD_BANNER_IMAGE" ]] && SD_BANNER_IMAGE="GE_SD_BannerImage.png"
[[ -z "$BANNER_TEXT_PADDING" ]] && BANNER_TEXT_PADDING=10 #10 spaces to accommodate for icon offset
[[ -z "$BANNER_SUBTITLE" ]] && BANNER_SUBTITLE=""
[[ -z "$BANNER_TEXT_COLOR" ]] && BANNER_TEXT_COLOR="white"

if ! initialize_branding_configuration; then
	print -u2 -- "ERROR: BrandingAssetsDirectory must be an absolute local directory and BannerImage must be a local JPG, JPEG, PNG, or HEIC filename/path."
	[[ ${APPDELETE_IS_SOURCED} -eq 1 ]] && return 1
	exit 1
fi

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="Delete Applications"
OVERLAY_ICON="/System/Applications/App Store.app"
SD_ICON_FILE="SF=trash.fill, color=black, weight=light"

# Jamf custom events used to install runtime dependencies

JAMF_BINARY="/usr/local/bin/jamf"
REMOVE_BINARY="/bin/rm"
JSON_PROCESSOR_BINARY="/usr/bin/jq"
MAX_DIALOG_RESPONSE_BYTES=1048576
BRANDING_ASSETS_INSTALL_POLICY="install_BrandingAssets"
DIALOG_INSTALL_POLICY="install_SwiftDialog"

# Exact application names in this array are protected with case-insensitive, literal matching.
# Use the Finder display name without the final .app bundle suffix; do not include paths.
NOT_ALLOWED_APPS=(
    "Company Portal" 
	"Falcon"
    "Jamf Connect"
	"Self Service"
	"Self Service+"
    "ZScaler")

# This list of items is for folders that are allowed to be deleted.  Some applications install themselves into a subfolder underneath /Applications, so you can hardcode which folders are allowed.
# Include just the folder names in this array (ie. Utilities), not the entire path
ALLOWED_FOLDERS=(
	"Zscaler Copy"
	"Utilities copy"
	"Cisco copy")

##################################################
#
# Passed in variables
# 
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"   

####################################################################################################
#
# Global Functions
#
####################################################################################################

function create_secure_temp_file ()
{
	# PURPOSE: Create the Swift Dialog JSON file without granting local users write access.
	# PARMS: TEMP_DIR, SCRIPT_NAME
	# RETURN: 0 when the file is created with mode 0600; otherwise 1.

	local previous_umask
	local create_status

	previous_umask=$(umask)
	umask 077
	JSON_OPTIONS=$(/usr/bin/mktemp "${TEMP_DIR}/${SCRIPT_NAME}.XXXXX")
	create_status=$?
	umask "${previous_umask}"

	if [[ ${create_status} -ne 0 || -z "${JSON_OPTIONS}" || ! -f "${JSON_OPTIONS}" ]]; then
		JSON_OPTIONS=""
		return 1
	fi

	if ! /bin/chmod 600 "${JSON_OPTIONS}"; then
		/bin/rm -f -- "${JSON_OPTIONS}"
		JSON_OPTIONS=""
		return 1
	fi

	return 0
}

function cleanup_temp_files ()
{
	# PURPOSE: Remove AppDelete-owned temporary files on every exit path.
	# PARMS: JSON_OPTIONS
	# RETURN: None

	[[ -n "${JSON_OPTIONS}" && -f "${JSON_OPTIONS}" ]] && /bin/rm -f -- "${JSON_OPTIONS}"
	JSON_OPTIONS=""
}

function create_log_directory ()
{
    # Ensure that the log directory and the log files exist. If they
    # do not then create them and set the permissions.
    #
    # RETURN: None

	# If the log directory doesnt exist - create it and set the permissions (using zsh paramter expansion to get directory)
	LOG_DIR=${LOG_FILE%/*}
	[[ ! -d "${LOG_DIR}" ]] && /bin/mkdir -p "${LOG_DIR}"
	/bin/chmod 755 "${LOG_DIR}"

	# If the log file does not exist - create it and set the permissions
	[[ ! -f "${LOG_FILE}" ]] && /usr/bin/touch "${LOG_FILE}"
	/bin/chmod 644 "${LOG_FILE}"
}

function logMe () 
{
    # Basic two pronged logging function that will log like this:
    #
    # 20231204 12:00:00: Some message here
    #
    # This function logs both to STDOUT/STDERR and a file
    # The log file is set by the $LOG_FILE variable.
    #
    # RETURN: None
    echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}" | tee -a "${LOG_FILE}"
}

function check_swift_dialog_install ()
{
	# PURPOSE: Ensure Swift Dialog exists and satisfies the configured minimum version.
	# PARMS: SW_DIALOG, SD_VERSION, MIN_SD_REQUIRED_VERSION
	# RETURN: 0 when the dependency is ready; otherwise 1.

	local installation_reason=""

	logMe "Ensuring that Swift Dialog is installed..."
	if [[ ! -x "${SW_DIALOG}" ]]; then
		installation_reason="missing or not executable"
	elif ! is-at-least "${MIN_SD_REQUIRED_VERSION}" "${SD_VERSION}"; then
		installation_reason="older than required version ${MIN_SD_REQUIRED_VERSION}"
	fi

	if [[ -n "${installation_reason}" ]]; then
		logMe "Swift Dialog is ${installation_reason}; invoking Jamf event '${DIALOG_INSTALL_POLICY}'."
		install_swift_dialog || return 1
	fi

	if [[ ! -x "${SW_DIALOG}" ]]; then
		logMe "ERROR: Swift Dialog is unavailable after Jamf event '${DIALOG_INSTALL_POLICY}'."
		return 1
	fi

	SD_VERSION=$("${SW_DIALOG}" --version 2>/dev/null) || {
		logMe "ERROR: Unable to determine the installed Swift Dialog version."
		return 1
	}

	if ! is-at-least "${MIN_SD_REQUIRED_VERSION}" "${SD_VERSION}"; then
		logMe "ERROR: Swift Dialog ${SD_VERSION} does not satisfy required version ${MIN_SD_REQUIRED_VERSION}."
		return 1
	fi

	logMe "Swift Dialog is ready: ${SD_VERSION}"
	return 0
}

function install_swift_dialog ()
{
	# PURPOSE: Invoke the administrator-defined Jamf policy that installs Swift Dialog.
	# PARMS: JAMF_BINARY, DIALOG_INSTALL_POLICY
	# RETURN: The Jamf policy command status.

	if [[ ! -x "${JAMF_BINARY}" ]]; then
		logMe "ERROR: Jamf binary is unavailable at ${JAMF_BINARY}."
		return 1
	fi

	if ! "${JAMF_BINARY}" policy -event "${DIALOG_INSTALL_POLICY}"; then
		logMe "ERROR: Jamf event '${DIALOG_INSTALL_POLICY}' failed."
		return 1
	fi

	return 0
}

function check_branding_assets ()
{
	# PURPOSE: Ensure the configured local banner exists, installing branding assets when needed.
	# PARMS: SD_BANNER_IMAGE, JAMF_BINARY, BRANDING_ASSETS_INSTALL_POLICY
	# RETURN: 0 when the banner is a readable file; otherwise 1.

	if [[ -f "${SD_BANNER_IMAGE}" && -r "${SD_BANNER_IMAGE}" ]]; then
		return 0
	fi

	if [[ ! -x "${JAMF_BINARY}" ]]; then
		logMe "ERROR: Jamf binary is unavailable at ${JAMF_BINARY}; cannot install branding assets."
		return 1
	fi

	logMe "Branding banner is missing; invoking Jamf event '${BRANDING_ASSETS_INSTALL_POLICY}'."
	if ! "${JAMF_BINARY}" policy -event "${BRANDING_ASSETS_INSTALL_POLICY}"; then
		logMe "ERROR: Jamf event '${BRANDING_ASSETS_INSTALL_POLICY}' failed."
		return 1
	fi

	if [[ ! -f "${SD_BANNER_IMAGE}" || ! -r "${SD_BANNER_IMAGE}" ]]; then
		logMe "ERROR: Branding banner is still unavailable after '${BRANDING_ASSETS_INSTALL_POLICY}': ${SD_BANNER_IMAGE}"
		return 1
	fi

	logMe "Branding banner is ready: ${SD_BANNER_IMAGE}"
	return 0
}

function check_json_processor ()
{
	# PURPOSE: Verify the required Apple jq binary supports strict streaming JSON parsing.
	# PARMS: JSON_PROCESSOR_BINARY
	# RETURN: 0 when the processor passes a functional probe; otherwise 1.

	local probe_output
	local jq_filter='if length == 2 and (.[0] | length) == 1 and (.[0][0] | type) == "string" and (.[1] | type) == "boolean" then [.[0][0], (.[1] | tostring)] | @tsv elif length == 1 then empty else error("expected a flat object of boolean fields") end'

	if [[ ! -x "${JSON_PROCESSOR_BINARY}" ]]; then
		logMe "ERROR: Required JSON processor is unavailable at ${JSON_PROCESSOR_BINARY}."
		return 1
	fi

	probe_output=$(/usr/bin/printf '%s' '{"probe":true,"probe":false}' |
		"${JSON_PROCESSOR_BINARY}" --stream -er "${jq_filter}" 2>/dev/null) || {
		logMe "ERROR: JSON processor failed its structured-parser probe: ${JSON_PROCESSOR_BINARY}"
		return 1
	}

	if [[ "${probe_output}" != $'probe\ttrue\nprobe\tfalse' ]]; then
		logMe "ERROR: JSON processor did not preserve duplicate fields during its parser probe."
		return 1
	fi

	return 0
}

function cleanup_and_exit ()
{
	# PURPOSE: Exit without allowing a prior deletion failure to be downgraded to success.
	# PARMS: Optional exit status; defaults to 0.
	# RETURN: Does not return.

	resolve_session_exit_status "${1:-0}"
	local exit_status="${REPLY}"
	exit "${exit_status}"
}

function resolve_session_exit_status ()
{
	# PURPOSE: Combine a requested exit status with the cumulative deletion-session result.
	# PARMS: $1 - Requested exit status.
	# RETURN: 0 with the effective numeric status in REPLY.

	local requested_status="${1:-0}"

	if (( requested_status == 0 && ${SESSION_HAD_DELETION_FAILURE:-0} != 0 )); then
		REPLY=1
	else
		REPLY="${requested_status}"
	fi
	return 0
}

function create_infobox_message()
{
    # PURPOSE: Construct the infobox dialog msg
    # PARMS: None
    # RETURN: None

	SD_INFO_BOX_MSG="## System Info ##<br>"
	SD_INFO_BOX_MSG+="${MAC_CPU}<br>"
	SD_INFO_BOX_MSG+="{serialnumber}<br>"
	SD_INFO_BOX_MSG+="${MAC_RAM} RAM<br>"
	SD_INFO_BOX_MSG+="${FREE_DISK_SPACE}GB Available<br>"
	SD_INFO_BOX_MSG+="{osname} {osversion}<br>"
}

####################################################################################################
#
# Functions
#
####################################################################################################

function is_valid_item_name ()
{
	# PURPOSE: Require one non-special filesystem component for every displayed item.
	# PARMS: $1 - Application or folder name without a parent path.
	# RETURN: 0 when the value is a safe basename; otherwise 1.

	local item_name="$1"

	[[ -n "${item_name}" && "${item_name}" != "." && "${item_name}" != ".." && "${item_name}" != */* ]]
}

function initialize_protected_app_policy ()
{
	# PURPOSE: Validate and normalize the configured protected-application names.
	# PARMS: NOT_ALLOWED_APPS
	# RETURN: 0 with PROTECTED_APP_NAMES ready for exact matching; otherwise 1.

	local configured_name
	local normalized_name

	PROTECTED_APP_NAMES=()
	PROTECTED_POLICY_READY=0

	for configured_name in "${NOT_ALLOWED_APPS[@]}"; do
		if ! is_valid_item_name "${configured_name}"; then
			logMe "ERROR: Invalid NOT_ALLOWED_APPS entry; expected an application name without a path: ${configured_name}"
			PROTECTED_APP_NAMES=()
			return 1
		fi

		normalized_name="${configured_name:l}"
		PROTECTED_APP_NAMES[$normalized_name]=1
	done

	PROTECTED_POLICY_READY=1
	return 0
}

function is_protected_app_name ()
{
	# PURPOSE: Check an application name against the normalized exact-match policy.
	# PARMS: $1 - Application name without its final .app suffix.
	# RETURN: 0 for a protected or invalid application; otherwise 1.

	local app_name="$1"
	local normalized_name

	# An unavailable policy must fail closed rather than expose protected applications.
	[[ ${PROTECTED_POLICY_READY:-0} -eq 1 ]] || return 0
	is_valid_item_name "${app_name}" || return 0

	normalized_name="${app_name:l}"
	(( ${+PROTECTED_APP_NAMES[$normalized_name]} ))
}

function is_allowed_folder_name ()
{
	# PURPOSE: Check whether a safe folder basename is explicitly configured for deletion.
	# PARMS: $1 - Folder name without a parent path.
	# RETURN: 0 for an exact configured folder name; otherwise 1.

	local folder_name="$1"
	local allowed_name

	is_valid_item_name "${folder_name}" || return 1
	# Application bundles must pass the application policy and cannot be reintroduced as folders.
	[[ "${folder_name:l}" == *.app ]] && return 1
	for allowed_name in "${ALLOWED_FOLDERS[@]}"; do
		[[ "${folder_name}" == "${allowed_name}" ]] && return 0
	done

	return 1
}

function build_file_list_array ()
{
	# PURPOSE: Build exact application and configured-folder targets under APPLICATIONS_DIR.
	# PARMS: APPLICATIONS_DIR, NOT_ALLOWED_APPS, ALLOWED_FOLDERS
	# RETURN: 0 when the applications directory was scanned; otherwise 1.

	local app_path
	local app_bundle_name
	local app_name
	local folder_name
	local folder_path
	local candidate_path
	local -a candidate_paths
	local -A seen_paths

	FILES_LIST=()
	CANDIDATE_TYPES=()
	if ! initialize_protected_app_policy; then
		logMe "ERROR: Refusing to continue with an invalid protected-application policy."
		return 1
	fi

	if [[ ! -d "${APPLICATIONS_DIR}" || -L "${APPLICATIONS_DIR}" ]]; then
		logMe "ERROR: Applications directory is missing or is a symbolic link: ${APPLICATIONS_DIR}"
		return 1
	fi

	while IFS= read -r -d '' app_path; do
		[[ -L "${app_path}" ]] && continue
		app_bundle_name="${app_path:t}"
		app_name="${app_bundle_name%.app}"

		is_valid_item_name "${app_name}" || continue
		is_protected_app_name "${app_name}" && continue
		[[ -f "${app_path}/Contents/Info.plist" ]] || continue

		candidate_paths+=("${app_path}")
		CANDIDATE_TYPES[$app_path]="application"
	done < <(/usr/bin/find "${APPLICATIONS_DIR}" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print0)

	for folder_name in "${ALLOWED_FOLDERS[@]}"; do
		if ! is_allowed_folder_name "${folder_name}"; then
			logMe "ERROR: Ignoring unsafe or application-bundle ALLOWED_FOLDERS entry: ${folder_name}"
			continue
		fi

		folder_path="${APPLICATIONS_DIR}/${folder_name}"
		[[ -d "${folder_path}" && ! -L "${folder_path}" ]] || continue
		candidate_paths+=("${folder_path}")
		CANDIDATE_TYPES[$folder_path]="folder"
	done

	# Preserve exact paths and remove duplicates before sorting for display.
	for candidate_path in "${(@oi)candidate_paths}"; do
		(( ${+seen_paths[$candidate_path]} )) && continue
		seen_paths[$candidate_path]=1
		FILES_LIST+=("${candidate_path}")
	done

	return 0
}

function construct_display_list ()
{
	# PURPOSE: Build dialog JSON with jq and bind opaque item IDs to exact approved targets.
	# PARMS: FILES_LIST, CANDIDATE_TYPES, JSON_OPTIONS, JSON_PROCESSOR_BINARY
	# RETURN: 0 when at least one approved item is written; otherwise 1.

	local target_path
	local target_type
	local display_name
	local icon_path
	local item_id
	local -i item_index=0
	local -i record_index
	local -a record_labels
	local -a record_ids
	local -a record_icons
	local jq_filter='split("\u0000") | if .[-1] == "" then .[:-1] else error("incomplete dialog record") end | if (length % 3) != 0 then error("invalid dialog record width") else . end | {checkboxstyle: {style: "switch", size: "regular"}, checkbox: [range(0; length; 3) as $index | {label: .[$index], name: .[$index + 1], checked: false, disabled: false, icon: .[$index + 2]}]}'

	APPROVED_TARGETS=()
	APPROVED_LABELS=()
	APPROVED_TYPES=()

	[[ -n "${JSON_OPTIONS}" && -f "${JSON_OPTIONS}" && -x "${JSON_PROCESSOR_BINARY}" ]] || return 1

	for target_path in "${FILES_LIST[@]}"; do
		target_type="${CANDIDATE_TYPES[$target_path]-}"
		case "${target_type}" in
			application)
				display_name="${target_path:t}"
				display_name="${display_name%.app}"
				icon_path="${target_path}"
				;;
			folder)
				display_name="${target_path:t}"
				icon_path="${ICON_FILES}/ApplicationsFolderIcon.icns"
				;;
			*)
				continue
				;;
		esac

		(( item_index++ ))
		printf -v item_id 'appdelete_%04d' "${item_index}"
		APPROVED_TARGETS[$item_id]="${target_path}"
		APPROVED_LABELS[$item_id]="${display_name}"
		APPROVED_TYPES[$item_id]="${target_type}"
		record_labels+=("${display_name}")
		record_ids+=("${item_id}")
		record_icons+=("${icon_path}")
	done

	(( item_index > 0 )) || return 1
	if ! {
		for (( record_index = 1; record_index <= item_index; record_index++ )); do
			/usr/bin/printf '%s\0%s\0%s\0' "${record_labels[record_index]}" "${record_ids[record_index]}" "${record_icons[record_index]}" || return 1
		done
	} | "${JSON_PROCESSOR_BINARY}" -Rse "${jq_filter}" > "${JSON_OPTIONS}"; then
		return 1
	fi

	/bin/chmod 600 "${JSON_OPTIONS}" || return 1
	return 0
}

function choose_files_to_delete ()
{
	# PURPOSE: Display approved targets and capture selected opaque item IDs in memory.
	# PARMS: APPROVED_TARGETS, JSON_OPTIONS
	# RETURN: None; exits safely on cancellation or invalid dialog output.

	local dialog_output
	local dialog_status

	MainDialogBody=(
		--message "$SD_DIALOG_GREETING $SD_FIRST_NAME. Please choose the application(s) and/or folder(s) that you want to remove from your system.  Applications can be installed again from Self Service."
		--messageposition top
		--bannertitle "${SD_WINDOW_TITLE}"
		--subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1, offset=${BANNER_TEXT_PADDING}, color=${BANNER_TEXT_COLOR:l}"
		--icon "${SD_ICON_FILE}"
		--overlayicon "${OVERLAY_ICON}"
		--bannerimage "${SD_BANNER_IMAGE}"
		--helpmessage "Choose which applications you want to remove. <br>They can be installed again from Self Service."
		--width 920
		--height 750
		--moveable
		--ontop
		--buttonstyle center
		--infobox "${SD_INFO_BOX_MSG}"
		--jsonfile "${JSON_OPTIONS}"
		--quitkey 0
		--button1text "Next"
		--button2text "Cancel"
		--json
    )

	dialog_output=$("${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null)
	dialog_status=$?

	case "${dialog_status}" in
		0)
			if ! parse_dialog_selection "${dialog_output}"; then
				logMe "ERROR: Refusing to continue because Swift Dialog returned an invalid selection payload."
				cleanup_and_exit 1
			fi
			;;
		2|10)
			cleanup_and_exit 0
			;;
		*)
			logMe "ERROR: Swift Dialog exited unexpectedly with status ${dialog_status}."
			cleanup_and_exit 1
			;;
	esac
}

function parse_dialog_selection ()
{
	# PURPOSE: Parse a bounded Swift Dialog response as a strict flat Boolean JSON object.
	# PARMS: $1 - JSON response containing opaque appdelete_NNNN boolean fields.
	# RETURN: 0 with selected IDs in SELECTED_ITEM_IDS; otherwise 1.

	local dialog_output="$1"
	local parsed_output
	local item_id
	local selected_value
	local extra_value
	local jq_filter='if length == 2 and (.[0] | length) == 1 and (.[0][0] | type) == "string" and (.[1] | type) == "boolean" then [.[0][0], (.[1] | tostring)] | @tsv elif length == 1 then empty else error("expected a flat object of boolean fields") end'
	local -a parsed_selected_ids
	local -A seen_items
	local -i response_size=0
	local -i parsed_count=0

	SELECTED_ITEM_IDS=()
	[[ -n "${dialog_output}" && ${#APPROVED_TARGETS} -gt 0 && -x "${JSON_PROCESSOR_BINARY}" ]] || return 1

	response_size=$(/usr/bin/printf '%s' "${dialog_output}" | /usr/bin/wc -c) || return 1
	(( response_size > 0 && response_size <= MAX_DIALOG_RESPONSE_BYTES )) || return 1

	# Slurping is safe after the size bound and proves there is exactly one top-level object.
	/usr/bin/printf '%s' "${dialog_output}" |
		"${JSON_PROCESSOR_BINARY}" -se 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 || return 1

	# Streaming preserves duplicate keys, unlike ordinary object decoding.
	parsed_output=$(/usr/bin/printf '%s' "${dialog_output}" |
		"${JSON_PROCESSOR_BINARY}" --stream -er "${jq_filter}" 2>/dev/null) || return 1
	[[ -n "${parsed_output}" ]] || return 1

	while IFS=$'\t' read -r item_id selected_value extra_value; do
		[[ -n "${item_id}" && -z "${extra_value}" ]] || return 1
		[[ "${selected_value}" == "true" || "${selected_value}" == "false" ]] || return 1

		(( ${+APPROVED_TARGETS[$item_id]} )) || return 1
		(( ${+seen_items[$item_id]} )) && return 1
		seen_items[$item_id]=1
		(( parsed_count++ ))

		[[ "${selected_value}" == "true" ]] && parsed_selected_ids+=("${item_id}")
	done <<< "${parsed_output}"

	[[ ${parsed_count} -eq ${#APPROVED_TARGETS} ]] || return 1
	SELECTED_ITEM_IDS=("${parsed_selected_ids[@]}")
	return 0
}

function validate_approved_target ()
{
	# PURPOSE: Revalidate one opaque ID and prove its target is an approved direct child.
	# PARMS: $1 - Opaque item ID from APPROVED_TARGETS.
	# RETURN: 0 for a currently valid target; otherwise 1.

	local item_id="$1"
	local target_path
	local target_type
	local display_name
	local expected_target

	(( ${+APPROVED_TARGETS[$item_id]} )) || return 1
	(( ${+APPROVED_LABELS[$item_id]} )) || return 1
	(( ${+APPROVED_TYPES[$item_id]} )) || return 1

	target_path="${APPROVED_TARGETS[$item_id]}"
	target_type="${APPROVED_TYPES[$item_id]}"
	display_name="${APPROVED_LABELS[$item_id]}"

	is_valid_item_name "${display_name}" || return 1
	[[ -d "${APPLICATIONS_DIR}" && ! -L "${APPLICATIONS_DIR}" ]] || return 1
	[[ "${target_path:h}" == "${APPLICATIONS_DIR}" ]] || return 1
	[[ ! -L "${target_path}" && -d "${target_path}" ]] || return 1

	case "${target_type}" in
		application)
			is_protected_app_name "${display_name}" && return 1
			expected_target="${APPLICATIONS_DIR}/${display_name}.app"
			[[ "${target_path}" == "${expected_target}" ]] || return 1
			[[ -f "${target_path}/Contents/Info.plist" ]] || return 1
			;;
		folder)
			is_allowed_folder_name "${display_name}" || return 1
			expected_target="${APPLICATIONS_DIR}/${display_name}"
			[[ "${target_path}" == "${expected_target}" ]] || return 1
			;;
		*)
			return 1
			;;
	esac

	return 0
}

function prepare_confirmation ()
{
	# PURPOSE: Freeze one validated in-memory selection for confirmation and deletion.
	# PARMS: SELECTED_ITEM_IDS and approved target maps.
	# RETURN: 0 when every selected target is valid; otherwise 1.

	local item_id
	local target_type
	local display_name

	CONFIRMED_ITEM_IDS=()
	messagebody=""

	for item_id in "${SELECTED_ITEM_IDS[@]}"; do
		if ! validate_approved_target "${item_id}"; then
			logMe "ERROR: Refusing unapproved or changed deletion target ID: ${item_id}"
			CONFIRMED_ITEM_IDS=()
			messagebody=""
			return 1
		fi

		CONFIRMED_ITEM_IDS+=("${item_id}")
		target_type="${APPROVED_TYPES[$item_id]}"
		display_name="${APPROVED_LABELS[$item_id]}"
		if [[ "${target_type}" == "folder" ]]; then
			messagebody+="- Folder: ${display_name}  \n"
		else
			messagebody+="- ${display_name}  \n"
		fi
	done

	return 0
}

function show_final_delete_prompt ()
{
	# PURPOSE: Confirm the frozen selection and delete only that in-memory snapshot.
	# PARMS: messagebody, CONFIRMED_ITEM_IDS
	# RETURN: The deletion result; exits safely on cancellation or dialog error.

	MainDialogBody=(
		--message "Are you sure you want to delete these applications?\n\n${messagebody}"
		--icon "${SD_ICON_FILE}"
		--overlayicon warning
		--height 500
		--bannerimage "${SD_BANNER_IMAGE}"
		--titlefont shadow=1
		--bannertitle "${SD_WINDOW_TITLE}"
		--button1text "Delete"
		--button2text "Cancel"
		--buttonstyle center
	)

	# Show the dialog screen and allow the user to choose

	"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
	buttonpress=$?

	# Evaluate the choice. Any unrecognized dialog status fails closed.

	case "${buttonpress}" in
		0)
			delete_files
			return $?
			;;
		2|10)
			cleanup_and_exit 0
			;;
		*)
			logMe "ERROR: Confirmation dialog exited unexpectedly with status ${buttonpress}."
			cleanup_and_exit 1
			;;
	esac
}

function deletion_item_description ()
{
	# PURPOSE: Produce a stable human-readable description for one approved item ID.
	# PARMS: $1 - Opaque item ID.
	# RETURN: 0 with the description in REPLY; otherwise 1 with a safe fallback in REPLY.

	local item_id="$1"
	local display_name
	local target_type

	if (( ! ${+APPROVED_LABELS[$item_id]} || ! ${+APPROVED_TYPES[$item_id]} )); then
		REPLY="Selection ${item_id}"
		return 1
	fi

	display_name="${APPROVED_LABELS[$item_id]}"
	target_type="${APPROVED_TYPES[$item_id]}"
	case "${target_type}" in
		application) REPLY="Application: ${display_name}" ;;
		folder) REPLY="Folder: ${display_name}" ;;
		*)
			REPLY="Selection ${item_id}"
			return 1
			;;
	esac

	return 0
}

function reset_deletion_results ()
{
	# PURPOSE: Clear result state before processing one confirmed deletion batch.
	# PARMS: None
	# RETURN: Always 0.

	SUCCESSFUL_DELETION_IDS=()
	FAILED_DELETION_IDS=()
	DELETION_FAILURE_REASONS=()
	DELETION_RESULT_MESSAGE=""
	return 0
}

function record_deletion_success ()
{
	# PURPOSE: Record and log one target only after its removal is verified.
	# PARMS: $1 - Opaque item ID.
	# RETURN: Always 0.

	local item_id="$1"
	local description

	SUCCESSFUL_DELETION_IDS+=("${item_id}")
	deletion_item_description "${item_id}"
	description="${REPLY}"
	logMe "Removed ${description}"
	return 0
}

function record_deletion_failure ()
{
	# PURPOSE: Record and log one target that was not safely deleted.
	# PARMS: $1 - Opaque item ID; $2 - Failure reason.
	# RETURN: Always 0.

	local item_id="$1"
	local failure_reason="$2"
	local description

	FAILED_DELETION_IDS+=("${item_id}")
	DELETION_FAILURE_REASONS[$item_id]="${failure_reason}"
	SESSION_HAD_DELETION_FAILURE=1
	deletion_item_description "${item_id}"
	description="${REPLY}"
	logMe "ERROR: Did not remove ${description}: ${failure_reason}"
	return 0
}

function build_deletion_result_message ()
{
	# PURPOSE: Build an accurate per-item completion summary from verified deletion results.
	# PARMS: SUCCESSFUL_DELETION_IDS, FAILED_DELETION_IDS, DELETION_FAILURE_REASONS
	# RETURN: 0 with DELETION_RESULT_MESSAGE populated.

	local item_id
	local description
	local failure_reason

	DELETION_RESULT_MESSAGE=""
	if (( ${#SUCCESSFUL_DELETION_IDS} > 0 )); then
		DELETION_RESULT_MESSAGE+="## Deleted"$'\n\n'
		for item_id in "${SUCCESSFUL_DELETION_IDS[@]}"; do
			deletion_item_description "${item_id}"
			description="${REPLY}"
			DELETION_RESULT_MESSAGE+="- ${description}"$'\n'
		done
	fi

	if (( ${#FAILED_DELETION_IDS} > 0 )); then
		[[ -n "${DELETION_RESULT_MESSAGE}" ]] && DELETION_RESULT_MESSAGE+=$'\n'
		DELETION_RESULT_MESSAGE+="## Not deleted"$'\n\n'
		for item_id in "${FAILED_DELETION_IDS[@]}"; do
			deletion_item_description "${item_id}"
			description="${REPLY}"
			failure_reason="${DELETION_FAILURE_REASONS[$item_id]-Unknown deletion error.}"
			DELETION_RESULT_MESSAGE+="- ${description}: ${failure_reason}"$'\n'
		done
	fi

	[[ -z "${DELETION_RESULT_MESSAGE}" ]] && DELETION_RESULT_MESSAGE="No items were selected for deletion."
	return 0
}

function delete_files () 
{
	# PURPOSE: Revalidate, delete, and record outcomes for the exact confirmed targets.
	# PARMS: CONFIRMED_ITEM_IDS and approved target maps.
	# RETURN: 0 when every requested target is verified absent; otherwise 1.

	local item_id
	local result_item_id
	local target_path
	local invalid_item_id=""
	local failure_reason
	local -i remove_status=0

	reset_deletion_results

	# Validate the entire batch before deleting anything so malformed state fails closed.
	for item_id in "${CONFIRMED_ITEM_IDS[@]}"; do
		if ! validate_approved_target "${item_id}"; then
			invalid_item_id="${item_id}"
			break
		fi
	done

	if [[ -n "${invalid_item_id}" ]]; then
		for result_item_id in "${CONFIRMED_ITEM_IDS[@]}"; do
			if [[ "${result_item_id}" == "${invalid_item_id}" ]]; then
				failure_reason="Safety validation failed for this target; the batch was not attempted."
			else
				failure_reason="Deletion was not attempted because another target failed safety validation."
			fi
			record_deletion_failure "${result_item_id}" "${failure_reason}"
		done
		build_deletion_result_message
		return 1
	fi

	for item_id in "${CONFIRMED_ITEM_IDS[@]}"; do
		# Revalidate immediately before each privileged removal to narrow replacement races.
		if ! validate_approved_target "${item_id}"; then
			record_deletion_failure "${item_id}" "Safety validation failed immediately before removal."
			continue
		fi

		target_path="${APPROVED_TARGETS[$item_id]}"
		"${REMOVE_BINARY}" -rf -- "${target_path}"
		remove_status=$?

		if [[ -e "${target_path}" || -L "${target_path}" ]]; then
			if (( remove_status == 0 )); then
				failure_reason="The removal command returned success, but the target still exists."
			else
				failure_reason="The removal command exited with status ${remove_status}, and the target still exists."
			fi
			record_deletion_failure "${item_id}" "${failure_reason}"
		else
			record_deletion_success "${item_id}"
			if (( remove_status != 0 )); then
				logMe "WARNING: Removal command exited with status ${remove_status}, but verified that the target is absent."
			fi
		fi
	done

	build_deletion_result_message
	(( ${#FAILED_DELETION_IDS} == 0 ))
}

function configure_completion_dialog ()
{
	# PURPOSE: Configure the completion dialog from verified success and failure results.
	# PARMS: DELETION_RESULT_MESSAGE and deletion result arrays.
	# RETURN: Always 0 with MainDialogBody populated.

	local completion_summary
	local overlay_icon
	local secondary_button_text

	if (( ${#FAILED_DELETION_IDS} > 0 )); then
		if (( ${#SUCCESSFUL_DELETION_IDS} > 0 )); then
			completion_summary="Some selected items were deleted, but others could not be deleted."
		else
			completion_summary="The selected items could not be deleted."
		fi
		overlay_icon="SF=exclamationmark.triangle.fill,color=red,weight=light,bgcolor=none"
		secondary_button_text="Try Again"
	elif (( ${#SUCCESSFUL_DELETION_IDS} > 0 )); then
		completion_summary="All selected items were deleted successfully."
		overlay_icon="SF=checkmark.circle.fill,color=green,weight=light,bgcolor=none"
		secondary_button_text="Run Again"
	else
		completion_summary="No deletion was requested."
		overlay_icon="SF=info.circle.fill,color=blue,weight=light,bgcolor=none"
		secondary_button_text="Run Again"
	fi

	MainDialogBody=(
		--message "${completion_summary}"$'\n\n'"${DELETION_RESULT_MESSAGE}"
		--ontop
		--icon "${SD_ICON_FILE}"
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
		--subtitle "${BANNER_SUBTITLE}"
		--titlefont "shadow=1, offset=${BANNER_TEXT_PADDING}, color=${BANNER_TEXT_COLOR:l}"
		--overlayicon "${overlay_icon}"
		--width 920
		--quitkey 0
		--buttonstyle center
		--button1text "Close"
		--button2text "${secondary_button_text}"
	)
	return 0
}

function show_completed_prompt ()
{
	# PURPOSE: Display verified deletion results and preserve the cumulative session status.
	# PARMS: MainDialogBody, SESSION_HAD_DELETION_FAILURE
	# RETURN: 0 to run another selection cycle; otherwise exits through cleanup_and_exit.

	configure_completion_dialog

	# Show the dialog screen and allow the user to choose

	"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
	buttonpress=$?

	case "${buttonpress}" in
		0|10)
			cleanup_and_exit "${SESSION_HAD_DELETION_FAILURE}"
			;;
		2)
			return 0
			;;
		*)
			logMe "ERROR: Completion dialog exited unexpectedly with status ${buttonpress}."
			cleanup_and_exit 1
			;;
	esac
}

#############################
#
# Start of Main Script
#
#############################

typeset -ga FILES_LIST
typeset -ga SELECTED_ITEM_IDS
typeset -ga CONFIRMED_ITEM_IDS
typeset -ga SUCCESSFUL_DELETION_IDS
typeset -ga FAILED_DELETION_IDS
typeset -gA CANDIDATE_TYPES
typeset -gA APPROVED_TARGETS
typeset -gA APPROVED_LABELS
typeset -gA APPROVED_TYPES
typeset -gA PROTECTED_APP_NAMES
typeset -gA DELETION_FAILURE_REASONS
typeset -gi PROTECTED_POLICY_READY=0
typeset -gi SESSION_HAD_DELETION_FAILURE=0
typeset -g messagebody
typeset -g DELETION_RESULT_MESSAGE

# Loading this file for unit tests exposes functions without running the Jamf workflow.
[[ ${APPDELETE_IS_SOURCED} -eq 1 ]] && return 0

autoload 'is-at-least'

trap 'cleanup_temp_files' EXIT
trap 'exit 1' HUP INT TERM

create_log_directory
if ! create_secure_temp_file; then
	logMe "ERROR: Unable to create a secure Swift Dialog configuration file."
	cleanup_and_exit 1
fi

if ! check_json_processor; then
	logMe "ERROR: AppDelete cannot continue without Apple's structured JSON processor."
	cleanup_and_exit 1
fi
if ! check_swift_dialog_install; then
	logMe "ERROR: AppDelete cannot continue without a verified Swift Dialog installation."
	cleanup_and_exit 1
fi
if ! check_branding_assets; then
	logMe "ERROR: AppDelete cannot continue without the configured branding banner."
	cleanup_and_exit 1
fi
create_infobox_message

while true; do
	if ! build_file_list_array; then
		cleanup_and_exit 1
	fi
	if ! construct_display_list; then
		logMe "ERROR: No approved applications or folders are available for deletion."
		cleanup_and_exit 1
	fi
	choose_files_to_delete
	if ! prepare_confirmation; then
		cleanup_and_exit 1
	fi

	# Display a final warning with the files they chose.

	show_final_delete_prompt
	show_completed_prompt
done
