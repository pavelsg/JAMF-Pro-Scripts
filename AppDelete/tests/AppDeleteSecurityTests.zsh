#!/bin/zsh
#
# Regression tests for AppDelete's privileged deletion boundary.
# These tests use an isolated /private/tmp fixture and never access /Applications.

SCRIPT_DIR="${0:A:h}"
APPDELETE_SCRIPT="${SCRIPT_DIR:h}/AppDelete.sh"
TEST_ROOT=""
TESTS_PASSED=0
TESTS_FAILED=0
TEST_COUNTER=0
typeset -ga TEST_LOG_MESSAGES

function cleanup_test_root ()
{
	# PURPOSE: Remove only the private test fixture created by this test process.
	# PARMS: TEST_ROOT
	# RETURN: None

	cleanup_temp_files 2>/dev/null || true
	case "${TEST_ROOT}" in
		/private/tmp/AppDeleteSecurityTests.*)
			[[ -d "${TEST_ROOT}" ]] && /bin/rm -rf -- "${TEST_ROOT}"
			;;
	esac
}

function fail ()
{
	# PURPOSE: Report one assertion failure.
	# PARMS: $1 - Failure message.
	# RETURN: Always 1.

	print -u2 -- "    ${1}"
	return 1
}

function assert_success ()
{
	# PURPOSE: Assert that a command or function returns status 0.
	# PARMS: Command and arguments.
	# RETURN: 0 on success; otherwise 1.

	"$@" || fail "Expected success: $*"
}

function assert_failure ()
{
	# PURPOSE: Assert that a command or function returns a nonzero status.
	# PARMS: Command and arguments.
	# RETURN: 0 for an expected failure; otherwise 1.

	if "$@"; then
		fail "Expected failure: $*"
		return 1
	fi
	return 0
}

function assert_equal ()
{
	# PURPOSE: Assert equality between two strings.
	# PARMS: $1 - Expected value; $2 - Actual value; $3 - Context.
	# RETURN: 0 when equal; otherwise 1.

	local expected="$1"
	local actual="$2"
	local context="$3"

	[[ "${actual}" == "${expected}" ]] || fail "${context}: expected '${expected}', got '${actual}'"
}

function assert_exists ()
{
	# PURPOSE: Assert that a filesystem path exists, including symbolic links.
	# PARMS: $1 - Path.
	# RETURN: 0 when present; otherwise 1.

	[[ -e "$1" || -L "$1" ]] || fail "Expected path to exist: $1"
}

function assert_not_exists ()
{
	# PURPOSE: Assert that a filesystem path does not exist.
	# PARMS: $1 - Path.
	# RETURN: 0 when absent; otherwise 1.

	[[ ! -e "$1" && ! -L "$1" ]] || fail "Expected path to be absent: $1"
}

function reset_fixture ()
{
	# PURPOSE: Reset AppDelete globals and create an empty isolated Applications directory.
	# PARMS: None
	# RETURN: 0 on success; otherwise 1.

	local fixture_dir="${TEST_ROOT}/fixture-${TEST_COUNTER}"
	(( TEST_COUNTER++ ))

	APPLICATIONS_DIR="${fixture_dir}/Applications"
	TEMP_DIR="${fixture_dir}"
	LOG_FILE="${fixture_dir}/AppDelete.log"
	JSON_OPTIONS=""
	FILES_LIST=()
	SELECTED_ITEM_IDS=()
	CONFIRMED_ITEM_IDS=()
	CANDIDATE_TYPES=()
	APPROVED_TARGETS=()
	APPROVED_LABELS=()
	APPROVED_TYPES=()
	TEST_LOG_MESSAGES=()
	messagebody=""
	NOT_ALLOWED_APPS=("Company Portal" "Falcon" "Jamf Connect" "Self Service" "Self Service+" "ZScaler")
	ALLOWED_FOLDERS=()

	/bin/mkdir -p "${APPLICATIONS_DIR}"
}

function create_test_app ()
{
	# PURPOSE: Create a minimal application bundle in the isolated Applications directory.
	# PARMS: $1 - Application name without .app.
	# RETURN: 0 on success; otherwise 1.

	local app_path="${APPLICATIONS_DIR}/$1.app"
	/bin/mkdir -p "${app_path}/Contents" || return 1
	: > "${app_path}/Contents/Info.plist"
}

function create_test_folder ()
{
	# PURPOSE: Create an allowed-folder fixture with nested content.
	# PARMS: $1 - Folder name.
	# RETURN: 0 on success; otherwise 1.

	local folder_path="${APPLICATIONS_DIR}/$1"
	/bin/mkdir -p "${folder_path}/Nested" || return 1
	: > "${folder_path}/Nested/content.txt"
}

function prepare_dialog_configuration ()
{
	# PURPOSE: Build candidates and a secure dialog configuration for the current fixture.
	# PARMS: None
	# RETURN: 0 on success; otherwise 1.

	create_secure_temp_file || return 1
	build_file_list_array || return 1
	construct_display_list
}

function find_item_id_by_label ()
{
	# PURPOSE: Resolve one generated opaque ID by its test display label.
	# PARMS: $1 - Display label.
	# RETURN: 0 with the ID in REPLY; otherwise 1.

	local expected_label="$1"
	local item_id

	for item_id in "${(@k)APPROVED_LABELS}"; do
		if [[ "${APPROVED_LABELS[$item_id]}" == "${expected_label}" ]]; then
			REPLY="${item_id}"
			return 0
		fi
	done

	REPLY=""
	return 1
}

function dialog_output_for_selection ()
{
	# PURPOSE: Construct valid Swift Dialog JSON output for selected generated IDs.
	# PARMS: Zero or more selected item IDs.
	# RETURN: 0 with JSON in REPLY.

	local -A selected_ids
	local selected_id
	local item_id
	local separator=""
	local value
	local output=$'{\n'

	for selected_id in "$@"; do
		selected_ids[$selected_id]=1
	done

	for item_id in "${(@ok)APPROVED_TARGETS}"; do
		value="false"
		(( ${+selected_ids[$item_id]} )) && value="true"
		output+="${separator}  \"${item_id}\" : ${value}"
		separator=$',\n'
	done

	output+=$'\n}'
	REPLY="${output}"
	return 0
}

function run_test ()
{
	# PURPOSE: Run one test and update the suite totals.
	# PARMS: $1 - Test function name.
	# RETURN: Always 0 so the complete suite runs.

	local test_name="$1"

	if "${test_name}"; then
		print -- "PASS ${test_name}"
		(( TESTS_PASSED++ ))
	else
		print -u2 -- "FAIL ${test_name}"
		(( TESTS_FAILED++ ))
	fi

	return 0
}

function test_secure_temp_file_permissions ()
{
	# PURPOSE: Verify dialog configuration state is private to the invoking account.
	# PARMS: None
	# RETURN: 0 when mode 0600 is enforced; otherwise 1.

	reset_fixture || return 1
	create_secure_temp_file || return 1
	assert_equal "600" "$(/usr/bin/stat -f '%Lp' "${JSON_OPTIONS}")" "temporary-file mode"
}

function test_valid_json_uses_opaque_ids ()
{
	# PURPOSE: Verify unusual labels are escaped and never used as output identifiers.
	# PARMS: None
	# RETURN: 0 when generated JSON is valid and contains an opaque name.

	reset_fixture || return 1
	create_test_app 'Odd "Name"\Utility' || return 1
	prepare_dialog_configuration || return 1
	/usr/bin/plutil -convert json -o /dev/null -- "${JSON_OPTIONS}" >/dev/null || {
		fail "Generated dialog JSON is invalid"
		return 1
	}
	/usr/bin/grep -F '"name": "appdelete_0001"' "${JSON_OPTIONS}" >/dev/null || {
		fail "Opaque dialog ID is missing"
		return 1
	}
}

function test_valid_selection_parser ()
{
	# PURPOSE: Verify valid JSON selects only IDs whose values are true.
	# PARMS: None
	# RETURN: 0 when the parser returns the expected in-memory selection.

	local first_id
	local output

	reset_fixture || return 1
	create_test_app "Calculator" || return 1
	create_test_app "TextEdit" || return 1
	prepare_dialog_configuration || return 1
	find_item_id_by_label "Calculator" || return 1
	first_id="${REPLY}"
	dialog_output_for_selection "${first_id}"
	output="${REPLY}"
	parse_dialog_selection "${output}" || return 1
	assert_equal "${first_id}" "${(j:,:)SELECTED_ITEM_IDS}" "selected IDs"
}

function test_traversal_payload_is_rejected ()
{
	# PURPOSE: Verify a path-like JSON key cannot enter selection state.
	# PARMS: None
	# RETURN: 0 when parsing fails closed.

	reset_fixture || return 1
	create_test_app "Calculator" || return 1
	prepare_dialog_configuration || return 1
	assert_failure parse_dialog_selection $'{\n  "../../private/tmp" : true\n}'
}

function test_unknown_opaque_id_is_rejected ()
{
	# PURPOSE: Verify an unissued opaque ID cannot enter selection state.
	# PARMS: None
	# RETURN: 0 when parsing fails closed.

	reset_fixture || return 1
	create_test_app "Calculator" || return 1
	prepare_dialog_configuration || return 1
	assert_failure parse_dialog_selection $'{\n  "appdelete_9999" : true\n}'
}

function test_duplicate_or_missing_ids_are_rejected ()
{
	# PURPOSE: Verify the response must contain every issued ID exactly once.
	# PARMS: None
	# RETURN: 0 when duplicate and incomplete responses both fail.

	local item_id

	reset_fixture || return 1
	create_test_app "Calculator" || return 1
	create_test_app "TextEdit" || return 1
	prepare_dialog_configuration || return 1
	item_id="${${(@k)APPROVED_TARGETS}[1]}"

	assert_failure parse_dialog_selection $'{\n  "'"${item_id}"$'" : true,\n  "'"${item_id}"$'" : false\n}' || return 1
	assert_failure parse_dialog_selection $'{\n  "'"${item_id}"$'" : true\n}'
}

function test_path_traversal_mapping_is_rejected ()
{
	# PURPOSE: Verify even an internally mapped traversal path cannot pass target validation.
	# PARMS: None
	# RETURN: 0 when validation rejects the path.

	local outside_path

	reset_fixture || return 1
	outside_path="${APPLICATIONS_DIR}/../Outside"
	/bin/mkdir -p "${TEST_ROOT}/fixture-$(( TEST_COUNTER - 1 ))/Outside" || return 1
	ALLOWED_FOLDERS=("Outside")
	APPROVED_TARGETS[appdelete_0001]="${outside_path}"
	APPROVED_LABELS[appdelete_0001]="Outside"
	APPROVED_TYPES[appdelete_0001]="folder"
	assert_failure validate_approved_target "appdelete_0001"
}

function test_unsafe_allowed_folder_configuration_is_rejected ()
{
	# PURPOSE: Verify ALLOWED_FOLDERS cannot expand the deletion boundary with traversal.
	# PARMS: None
	# RETURN: 0 when the unsafe entry is not discovered.

	reset_fixture || return 1
	/bin/mkdir -p "${APPLICATIONS_DIR}/../Outside" || return 1
	ALLOWED_FOLDERS=("../Outside")
	build_file_list_array || return 1
	assert_equal "0" "${#FILES_LIST}" "unsafe allowed-folder candidate count"
}

function test_symlinked_allowed_folder_is_rejected ()
{
	# PURPOSE: Verify a configured folder symlink cannot become a recursive deletion target.
	# PARMS: None
	# RETURN: 0 when the symlink is excluded.

	local outside_path

	reset_fixture || return 1
	outside_path="${APPLICATIONS_DIR}/../Outside"
	/bin/mkdir -p "${outside_path}" || return 1
	/bin/ln -s "${outside_path}" "${APPLICATIONS_DIR}/Linked Folder" || return 1
	ALLOWED_FOLDERS=("Linked Folder")
	build_file_list_array || return 1
	assert_equal "0" "${#FILES_LIST}" "symlink candidate count"
}

function test_case_variant_of_protected_app_is_excluded ()
{
	# PURPOSE: Verify protected application matching cannot be bypassed by case changes.
	# PARMS: None
	# RETURN: 0 when the protected app is excluded.

	reset_fixture || return 1
	create_test_app "SELF SERVICE" || return 1
	create_test_app "Calculator" || return 1
	build_file_list_array || return 1
	assert_equal "1" "${#FILES_LIST}" "candidate count"
	assert_equal "${APPLICATIONS_DIR}/Calculator.app" "${FILES_LIST[1]}" "remaining candidate"
}

function test_confirmation_snapshot_ignores_legacy_selection_file ()
{
	# PURPOSE: Verify post-confirmation file tampering cannot alter the deletion target.
	# PARMS: None
	# RETURN: 0 when only the confirmed app is removed and the forged target survives.

	local app_path
	local outside_path
	local item_id
	local output
	local attacker_file

	reset_fixture || return 1
	app_path="${APPLICATIONS_DIR}/Calculator.app"
	outside_path="${APPLICATIONS_DIR}/../Outside"
	attacker_file="${TEST_ROOT}/attacker-selection"
	create_test_app "Calculator" || return 1
	/bin/mkdir -p "${outside_path}" || return 1
	prepare_dialog_configuration || return 1
	find_item_id_by_label "Calculator" || return 1
	item_id="${REPLY}"
	dialog_output_for_selection "${item_id}"
	output="${REPLY}"
	parse_dialog_selection "${output}" || return 1
	prepare_confirmation || return 1

	# This recreates the former attack input after confirmation. No production code reads it.
	print -r -- '"../Outside" : true' > "${attacker_file}"
	TMP_FILE_STORAGE="${attacker_file}"
	SELECTED_ITEM_IDS=()
	delete_files || return 1

	assert_not_exists "${app_path}" || return 1
	assert_exists "${outside_path}"
}

function test_tampered_target_map_fails_before_any_deletion ()
{
	# PURPOSE: Verify batch revalidation prevents partial deletion after target substitution.
	# PARMS: None
	# RETURN: 0 when all original and external paths survive.

	local app_path
	local folder_path
	local outside_path
	local app_id
	local folder_id
	local output

	reset_fixture || return 1
	app_path="${APPLICATIONS_DIR}/Calculator.app"
	folder_path="${APPLICATIONS_DIR}/Vendor Tools"
	outside_path="${APPLICATIONS_DIR}/../Outside"
	ALLOWED_FOLDERS=("Vendor Tools")
	create_test_app "Calculator" || return 1
	create_test_folder "Vendor Tools" || return 1
	/bin/mkdir -p "${outside_path}" || return 1
	prepare_dialog_configuration || return 1
	find_item_id_by_label "Calculator" || return 1
	app_id="${REPLY}"
	find_item_id_by_label "Vendor Tools" || return 1
	folder_id="${REPLY}"
	dialog_output_for_selection "${app_id}" "${folder_id}"
	output="${REPLY}"
	parse_dialog_selection "${output}" || return 1
	prepare_confirmation || return 1

	APPROVED_TARGETS[$folder_id]="${APPLICATIONS_DIR}/../Outside"
	assert_failure delete_files || return 1
	assert_exists "${app_path}" || return 1
	assert_exists "${folder_path}" || return 1
	assert_exists "${outside_path}"
}

function test_target_replaced_by_symlink_is_rejected ()
{
	# PURPOSE: Verify a selected folder changed into a symlink is not recursively followed.
	# PARMS: None
	# RETURN: 0 when deletion fails and the external target survives.

	local folder_path
	local moved_path
	local outside_path
	local item_id
	local output

	reset_fixture || return 1
	folder_path="${APPLICATIONS_DIR}/Vendor Tools"
	moved_path="${APPLICATIONS_DIR}/Vendor Tools original"
	outside_path="${APPLICATIONS_DIR}/../Outside"
	ALLOWED_FOLDERS=("Vendor Tools")
	create_test_folder "Vendor Tools" || return 1
	/bin/mkdir -p "${outside_path}" || return 1
	prepare_dialog_configuration || return 1
	find_item_id_by_label "Vendor Tools" || return 1
	item_id="${REPLY}"
	dialog_output_for_selection "${item_id}"
	output="${REPLY}"
	parse_dialog_selection "${output}" || return 1
	prepare_confirmation || return 1

	/bin/mv "${folder_path}" "${moved_path}" || return 1
	/bin/ln -s "${outside_path}" "${folder_path}" || return 1
	assert_failure delete_files || return 1
	assert_exists "${folder_path}" || return 1
	assert_exists "${moved_path}" || return 1
	assert_exists "${outside_path}"
}

function test_valid_allowed_folder_deletion ()
{
	# PURPOSE: Verify a valid configured direct-child folder can still be deleted.
	# PARMS: None
	# RETURN: 0 when the selected folder and nested content are removed.

	local folder_path
	local item_id
	local output

	reset_fixture || return 1
	folder_path="${APPLICATIONS_DIR}/Vendor Tools"
	ALLOWED_FOLDERS=("Vendor Tools")
	create_test_folder "Vendor Tools" || return 1
	prepare_dialog_configuration || return 1
	find_item_id_by_label "Vendor Tools" || return 1
	item_id="${REPLY}"
	dialog_output_for_selection "${item_id}"
	output="${REPLY}"
	parse_dialog_selection "${output}" || return 1
	prepare_confirmation || return 1
	delete_files || return 1
	assert_not_exists "${folder_path}"
}

source "${APPDELETE_SCRIPT}" >/dev/null || {
	print -u2 -- "Unable to load ${APPDELETE_SCRIPT}"
	exit 1
}

# Keep expected security failures quiet while preserving messages for assertions/debugging.
function logMe ()
{
	# PURPOSE: Capture AppDelete log messages during tests without touching system paths.
	# PARMS: $1 - Log message.
	# RETURN: Always 0.

	TEST_LOG_MESSAGES+=("$1")
	return 0
}

TEST_ROOT=$(/usr/bin/mktemp -d "/private/tmp/AppDeleteSecurityTests.XXXXXX") || {
	print -u2 -- "Unable to create isolated test root"
	exit 1
}
trap cleanup_test_root EXIT HUP INT TERM

run_test test_secure_temp_file_permissions
run_test test_valid_json_uses_opaque_ids
run_test test_valid_selection_parser
run_test test_traversal_payload_is_rejected
run_test test_unknown_opaque_id_is_rejected
run_test test_duplicate_or_missing_ids_are_rejected
run_test test_path_traversal_mapping_is_rejected
run_test test_unsafe_allowed_folder_configuration_is_rejected
run_test test_symlinked_allowed_folder_is_rejected
run_test test_case_variant_of_protected_app_is_excluded
run_test test_confirmation_snapshot_ignores_legacy_selection_file
run_test test_tampered_target_map_fails_before_any_deletion
run_test test_target_replaced_by_symlink_is_rejected
run_test test_valid_allowed_folder_deletion

print -- ""
print -- "${TESTS_PASSED} passed; ${TESTS_FAILED} failed"
[[ ${TESTS_FAILED} -eq 0 ]]
