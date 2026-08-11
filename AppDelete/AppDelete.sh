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

# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_DIR="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
if [[ ${APPDELETE_IS_SOURCED} -eq 0 && -f "$DEFAULTS_DIR" ]]; then
    echo "Found Defaults Files.  Reading in Info"
    SUPPORT_DIR=$(defaults read "$DEFAULTS_DIR" SupportFiles)
    SD_BANNER_IMAGE=$(defaults read "$DEFAULTS_DIR" BannerImage)
    BANNER_TEXT_PADDING=$(defaults read "$DEFAULTS_DIR" BannerPadding)
    BANNER_SUBTITLE=$(defaults read "$DEFAULTS_DIR" BannerSubtitle)
    BANNER_TEXT_COLOR=$(defaults read "$DEFAULTS_DIR" TitleFontColor)
else
    SUPPORT_DIR="/Library/Application Support/GiantEagle"
    SD_BANNER_IMAGE="GE_SD_BannerImage.png"
    BANNER_TEXT_PADDING=10 #10 spaces to accommodate for icon offset
    BANNER_SUBTITLE=""
fi
[[ -e $SUPPORT_DIR/$SD_BANNER_IMAGE ]] && SD_BANNER_IMAGE="$SUPPORT_DIR/$SD_BANNER_IMAGE"
[[ -z "$BANNER_TEXT_COLOR" ]] && BANNER_TEXT_COLOR="white"

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="Delete Applications"
OVERLAY_ICON="/System/Applications/App Store.app"
SD_ICON_FILE="SF=trash.fill, color=black, weight=light"

# Trigger installs for Images & icons

SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"

# The follow array lists the apps that the users are not allowed to remove.  If the apps show up in the list, they do not appear in the list of apps that can be deleted
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
    # Check to make sure that Swift Dialog is installed and functioning correctly
    # Will install process if missing or corrupted
    #
    # RETURN: None

    logMe "Ensuring that swiftDialog version is installed..."
    if [[ ! -x "${SW_DIALOG}" ]]; then
        logMe "Swift Dialog is missing or corrupted - Installing from JAMF"
        install_swift_dialog
        SD_VERSION=$( ${SW_DIALOG} --version)        
    fi

    if ! is-at-least "${MIN_SD_REQUIRED_VERSION}" "${SD_VERSION}"; then
        logMe "Swift Dialog is outdated - Installing version '${MIN_SD_REQUIRED_VERSION}' from JAMF..."
        install_swift_dialog
    else    
        logMe "Swift Dialog is currently running: ${SD_VERSION}"
    fi
}

function install_swift_dialog ()
{
    # Install Swift dialog From JAMF
    # PARMS Expected: DIALOG_INSTALL_POLICY - policy trigger from JAMF
    #
    # RETURN: None

	/usr/local/bin/jamf policy -event ${DIALOG_INSTALL_POLICY}
}

function check_support_files ()
{
    [[ ! -e "${SD_BANNER_IMAGE}" ]] && [[ "${SD_BANNER_IMAGE}" =~ \.(jpg|png|heic)$ ]] && /usr/local/bin/jamf policy -event ${SUPPORT_FILE_INSTALL_POLICY}
}

function cleanup_and_exit ()
{
	# PURPOSE: Exit with the requested status. The EXIT trap removes temporary files.
	# PARMS: Optional exit status; defaults to 0.
	# RETURN: Does not return.

	local exit_status=${1:-0}
	exit "${exit_status}"
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

function is_protected_app_name ()
{
	# PURPOSE: Check whether an application name exactly matches the protected list.
	# PARMS: $1 - Application name without the .app suffix.
	# RETURN: 0 for a protected application; otherwise 1.

	local app_name="$1"
	local protected_name

	for protected_name in "${NOT_ALLOWED_APPS[@]}"; do
		[[ "${app_name:l}" == "${protected_name:l}" ]] && return 0
	done

	return 1
}

function is_allowed_folder_name ()
{
	# PURPOSE: Check whether a safe folder basename is explicitly configured for deletion.
	# PARMS: $1 - Folder name without a parent path.
	# RETURN: 0 for an exact configured folder name; otherwise 1.

	local folder_name="$1"
	local allowed_name

	is_valid_item_name "${folder_name}" || return 1
	for allowed_name in "${ALLOWED_FOLDERS[@]}"; do
		[[ "${folder_name}" == "${allowed_name}" ]] && return 0
	done

	return 1
}

function json_escape ()
{
	# PURPOSE: Escape a filesystem label for safe use as a JSON string value.
	# PARMS: $1 - Unescaped string.
	# RETURN: 0 and the escaped value in REPLY.

	local input="$1"
	local output=""
	local character
	local unicode_escape
	local -i index
	local -i codepoint

	for (( index = 1; index <= ${#input}; index++ )); do
		character="${input[index]}"
		case "${character}" in
			'"') output+='\"' ;;
			'\') output+='\\' ;;
			$'\b') output+='\b' ;;
			$'\f') output+='\f' ;;
			$'\n') output+='\n' ;;
			$'\r') output+='\r' ;;
			$'\t') output+='\t' ;;
			[[:cntrl:]])
				codepoint=$(printf '%d' "'${character}")
				printf -v unicode_escape '\\u%04x' "${codepoint}"
				output+="${unicode_escape}"
				;;
			*) output+="${character}" ;;
		esac
	done

	REPLY="${output}"
	return 0
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
		if ! is_valid_item_name "${folder_name}"; then
			logMe "ERROR: Ignoring unsafe ALLOWED_FOLDERS entry: ${folder_name}"
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
	# PURPOSE: Build valid dialog JSON and bind opaque item IDs to exact approved targets.
	# PARMS: FILES_LIST, CANDIDATE_TYPES, JSON_OPTIONS
	# RETURN: 0 when at least one approved item is written; otherwise 1.

	local target_path
	local target_type
	local display_name
	local icon_path
	local escaped_label
	local escaped_icon
	local item_id
	local separator=""
	local -i item_index=0

	APPROVED_TARGETS=()
	APPROVED_LABELS=()
	APPROVED_TYPES=()

	[[ -n "${JSON_OPTIONS}" && -f "${JSON_OPTIONS}" ]] || return 1

	{
		print -r -- '{'
		print -r -- '  "checkboxstyle": {'
		print -r -- '    "style": "switch",'
		print -r -- '    "size": "regular"'
		print -r -- '  },'
		print -r -- '  "checkbox": ['

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

			json_escape "${display_name}"
			escaped_label="${REPLY}"
			json_escape "${icon_path}"
			escaped_icon="${REPLY}"

			print -rn -- "${separator}    {\"label\": \"${escaped_label}\", \"name\": \"${item_id}\", \"checked\": false, \"disabled\": false, \"icon\": \"${escaped_icon}\"}"
			separator=$',\n'
		done

		print
		print -r -- '  ]'
		print -r -- '}'
	} > "${JSON_OPTIONS}"

	/bin/chmod 600 "${JSON_OPTIONS}" || return 1
	(( item_index > 0 ))
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
	# PURPOSE: Parse the fixed-format Swift Dialog JSON response without trusting labels or paths.
	# PARMS: $1 - JSON response containing opaque appdelete_NNNN boolean fields.
	# RETURN: 0 with selected IDs in SELECTED_ITEM_IDS; otherwise 1.

	local dialog_output="$1"
	local line
	local compact_line
	local item_id
	local selected_value
	local selection_pattern='^[[:space:]]*"(appdelete_[0-9]+)"[[:space:]]*:[[:space:]]*(true|false)[[:space:]]*,?[[:space:]]*$'
	local -A seen_items
	local -i parsed_count=0

	SELECTED_ITEM_IDS=()
	[[ -n "${dialog_output}" && ${#APPROVED_TARGETS} -gt 0 ]] || return 1

	while IFS= read -r line; do
		compact_line="${line//[[:space:]]/}"
		[[ -z "${compact_line}" || "${compact_line}" == "{" || "${compact_line}" == "}" ]] && continue

		if [[ "${line}" =~ ${selection_pattern} ]]; then
			item_id="${match[1]}"
			selected_value="${match[2]}"
		else
			return 1
		fi

		(( ${+APPROVED_TARGETS[$item_id]} )) || return 1
		(( ${+seen_items[$item_id]} )) && return 1
		seen_items[$item_id]=1
		(( parsed_count++ ))

		[[ "${selected_value}" == "true" ]] && SELECTED_ITEM_IDS+=("${item_id}")
	done <<< "${dialog_output}"

	[[ ${parsed_count} -eq ${#APPROVED_TARGETS} ]]
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
	# RETURN: None; exits safely on cancellation, validation failure, or dialog error.

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
			if ! delete_files; then
				logMe "ERROR: One or more targets failed validation or could not be deleted."
				cleanup_and_exit 1
			fi
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

function delete_files () 
{
	# PURPOSE: Revalidate and delete the exact in-memory targets shown at confirmation.
	# PARMS: CONFIRMED_ITEM_IDS and approved target maps.
	# RETURN: 0 when all targets are valid and deleted; otherwise 1.

	local item_id
	local target_path
	local target_type
	local display_name

	# Validate the entire batch before deleting anything so malformed state fails closed.
	for item_id in "${CONFIRMED_ITEM_IDS[@]}"; do
		if ! validate_approved_target "${item_id}"; then
			logMe "ERROR: Refusing unapproved or changed deletion target ID: ${item_id}"
			return 1
		fi
	done

	for item_id in "${CONFIRMED_ITEM_IDS[@]}"; do
		target_path="${APPROVED_TARGETS[$item_id]}"
		target_type="${APPROVED_TYPES[$item_id]}"
		display_name="${APPROVED_LABELS[$item_id]}"

		if ! /bin/rm -rf -- "${target_path}"; then
			logMe "ERROR: Failed to remove ${target_type}: ${display_name}"
			return 1
		fi

		if [[ -e "${target_path}" || -L "${target_path}" ]]; then
			logMe "ERROR: Target still exists after deletion: ${display_name}"
			return 1
		fi

		if [[ "${target_type}" == "application" ]]; then
			logMe "Removed application: ${display_name}"
		else
			logMe "Removed Folder: ${display_name}"
		fi
	done

	return 0
}

function show_completed_prompt ()
{
	MainDialogBody=(
		--message "The following application(s) have been deleted.<br><br>${messagebody}\n\nIf you need to delete more files, you can choose \"Run Again\" below."
		--ontop 
		--icon "${SD_ICON_FILE}"
		--bannerimage "${SD_BANNER_IMAGE}"
		--bannertitle "${SD_WINDOW_TITLE}"
		--subtitle "${BANNER_SUBTITLE}"
        --titlefont "shadow=1, offset=${BANNER_TEXT_PADDING}, color=${BANNER_TEXT_COLOR:l}"
		--overlayicon "SF=checkmark.circle.fill,color=auto,weight=light,bgcolor=none"
		--width 920
		--quitkey 0
		--buttonstyle center
		--button1text "OK"
		--button2text "Run Again"
	)

	# Show the dialog screen and allow the user to choose

	"${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null
	buttonpress=$?

	[[ ${buttonpress} -eq 0 || ${buttonpress} -eq 10 ]] && cleanup_and_exit
}

#############################
#
# Start of Main Script
#
#############################

typeset -ga FILES_LIST
typeset -ga SELECTED_ITEM_IDS
typeset -ga CONFIRMED_ITEM_IDS
typeset -gA CANDIDATE_TYPES
typeset -gA APPROVED_TARGETS
typeset -gA APPROVED_LABELS
typeset -gA APPROVED_TYPES
typeset -g messagebody

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

check_swift_dialog_install
check_support_files
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
