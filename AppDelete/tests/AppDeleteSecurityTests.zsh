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

function assert_candidate_present ()
{
	# PURPOSE: Assert that an exact filesystem path is present in FILES_LIST.
	# PARMS: $1 - Expected candidate path.
	# RETURN: 0 when present; otherwise 1.

	local expected_path="$1"
	local candidate_path

	for candidate_path in "${FILES_LIST[@]}"; do
		[[ "${candidate_path}" == "${expected_path}" ]] && return 0
	done

	fail "Expected deletion candidate: ${expected_path}"
}

function assert_candidate_absent ()
{
	# PURPOSE: Assert that an exact filesystem path is absent from FILES_LIST.
	# PARMS: $1 - Disallowed candidate path.
	# RETURN: 0 when absent; otherwise 1.

	local disallowed_path="$1"
	local candidate_path

	for candidate_path in "${FILES_LIST[@]}"; do
		if [[ "${candidate_path}" == "${disallowed_path}" ]]; then
			fail "Unexpected deletion candidate: ${disallowed_path}"
			return 1
		fi
	done

	return 0
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
	PROTECTED_APP_NAMES=()
	PROTECTED_POLICY_READY=0
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

function create_mock_jamf_binary ()
{
	# PURPOSE: Create an isolated Jamf command double for dependency-policy tests.
	# PARMS: $1 - Mock binary path.
	# RETURN: 0 when the executable mock is ready; otherwise 1.

	local mock_path="$1"

	print -r -- '#!/bin/zsh' > "${mock_path}" || return 1
	print -r -- 'print -r -- "$*" > "${APPDELETE_TEST_JAMF_ARGS}"' >> "${mock_path}" || return 1
	print -r -- 'if [[ "${APPDELETE_TEST_INSTALL_BANNER:-0}" == "1" ]]; then' >> "${mock_path}" || return 1
	print -r -- '    /bin/mkdir -p "${APPDELETE_TEST_BANNER:h}" || exit 90' >> "${mock_path}" || return 1
	print -r -- '    : > "${APPDELETE_TEST_BANNER}" || exit 91' >> "${mock_path}" || return 1
	print -r -- 'fi' >> "${mock_path}" || return 1
	print -r -- 'if [[ "${APPDELETE_TEST_INSTALL_DIALOG:-0}" == "1" ]]; then' >> "${mock_path}" || return 1
	print -r -- '    /bin/mkdir -p "${APPDELETE_TEST_DIALOG:h}" || exit 92' >> "${mock_path}" || return 1
	print -r -- '    print -r -- "#!/bin/zsh" > "${APPDELETE_TEST_DIALOG}" || exit 93' >> "${mock_path}" || return 1
	print -r -- '    print -r -- '\''print -r -- "${APPDELETE_TEST_DIALOG_VERSION:-3.1.0}"'\'' >> "${APPDELETE_TEST_DIALOG}" || exit 94' >> "${mock_path}" || return 1
	print -r -- '    /bin/chmod 700 "${APPDELETE_TEST_DIALOG}" || exit 95' >> "${mock_path}" || return 1
	print -r -- 'fi' >> "${mock_path}" || return 1
	print -r -- 'exit "${APPDELETE_TEST_JAMF_EXIT:-0}"' >> "${mock_path}" || return 1
	/bin/chmod 700 "${mock_path}"
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

function test_protected_matching_is_exact_not_substring ()
{
	# PURPOSE: Verify prefixes and suffixes of a protected name remain independent apps.
	# PARMS: None
	# RETURN: 0 when only the exact protected application is excluded.

	reset_fixture || return 1
	NOT_ALLOWED_APPS=("Falcon")
	create_test_app "Falcon" || return 1
	create_test_app "Falcon Sensor" || return 1
	create_test_app "My Falcon" || return 1
	build_file_list_array || return 1

	assert_equal "2" "${#FILES_LIST}" "candidate count" || return 1
	assert_candidate_absent "${APPLICATIONS_DIR}/Falcon.app" || return 1
	assert_candidate_present "${APPLICATIONS_DIR}/Falcon Sensor.app" || return 1
	assert_candidate_present "${APPLICATIONS_DIR}/My Falcon.app"
}

function test_protected_names_treat_glob_characters_literally ()
{
	# PURPOSE: Verify configuration characters such as brackets and stars are not patterns.
	# PARMS: None
	# RETURN: 0 when only the literal protected name is excluded.

	reset_fixture || return 1
	NOT_ALLOWED_APPS=('Agent [Prod]*')
	create_test_app 'Agent [Prod]*' || return 1
	create_test_app "Agent Prod" || return 1
	build_file_list_array || return 1

	assert_equal "1" "${#FILES_LIST}" "candidate count" || return 1
	assert_candidate_absent "${APPLICATIONS_DIR}/Agent [Prod]*.app" || return 1
	assert_candidate_present "${APPLICATIONS_DIR}/Agent Prod.app"
}

function test_invalid_protected_configuration_fails_closed ()
{
	# PURPOSE: Verify a path-like NOT_ALLOWED_APPS entry aborts candidate discovery.
	# PARMS: None
	# RETURN: 0 when the policy remains unavailable and no candidates are exposed.

	reset_fixture || return 1
	NOT_ALLOWED_APPS=("Self Service" "../Falcon")
	create_test_app "Calculator" || return 1

	assert_failure build_file_list_array || return 1
	assert_equal "0" "${PROTECTED_POLICY_READY}" "protected-policy readiness" || return 1
	assert_equal "0" "${#FILES_LIST}" "candidate count"
}

function test_duplicate_protected_names_are_normalized_once ()
{
	# PURPOSE: Verify case variants normalize into one exact protected-policy entry.
	# PARMS: None
	# RETURN: 0 when duplicate variants collapse and remain protected.

	reset_fixture || return 1
	NOT_ALLOWED_APPS=("Self Service" "SELF SERVICE" "self service")
	initialize_protected_app_policy || return 1

	assert_equal "1" "${#PROTECTED_APP_NAMES}" "normalized protected-name count" || return 1
	assert_success is_protected_app_name "SeLf SeRvIcE"
}

function test_protection_is_rechecked_before_deletion ()
{
	# PURPOSE: Verify a target newly protected after discovery fails deletion validation.
	# PARMS: None
	# RETURN: 0 when the protected application survives.

	local app_path
	local item_id
	local output

	reset_fixture || return 1
	NOT_ALLOWED_APPS=()
	app_path="${APPLICATIONS_DIR}/Calculator.app"
	create_test_app "Calculator" || return 1
	prepare_dialog_configuration || return 1
	find_item_id_by_label "Calculator" || return 1
	item_id="${REPLY}"
	dialog_output_for_selection "${item_id}"
	output="${REPLY}"
	parse_dialog_selection "${output}" || return 1
	prepare_confirmation || return 1

	NOT_ALLOWED_APPS=("Calculator")
	initialize_protected_app_policy || return 1
	assert_failure delete_files || return 1
	assert_exists "${app_path}"
}

function test_allowed_folders_cannot_reintroduce_app_bundles ()
{
	# PURPOSE: Verify ALLOWED_FOLDERS cannot bypass application protection with a .app name.
	# PARMS: None
	# RETURN: 0 when the protected bundle remains absent from deletion candidates.

	reset_fixture || return 1
	NOT_ALLOWED_APPS=("Self Service")
	ALLOWED_FOLDERS=("Self Service.app")
	create_test_app "Self Service" || return 1
	build_file_list_array || return 1

	assert_equal "0" "${#FILES_LIST}" "candidate count" || return 1
	assert_candidate_absent "${APPLICATIONS_DIR}/Self Service.app"
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

function test_default_branding_configuration_contract ()
{
	# PURPOSE: Verify AppDelete's compatible default asset path and renamed Jamf event.
	# PARMS: None
	# RETURN: 0 when defaults use the support directory and descriptive event name.

	assert_equal "${SUPPORT_DIR}" "${BRANDING_ASSETS_DIR}" "default branding-assets directory" || return 1
	assert_equal "${SUPPORT_DIR}/GE_SD_BannerImage.png" "${SD_BANNER_IMAGE}" "default banner path" || return 1
	assert_equal "install_BrandingAssets" "${BRANDING_ASSETS_INSTALL_POLICY}" "branding-assets event"
}

function test_custom_branding_directory_is_resolved ()
{
	# PURPOSE: Verify a configured asset filename is resolved against its independent directory.
	# PARMS: None
	# RETURN: 0 when the normalized full path uses BRANDING_ASSETS_DIR.

	BRANDING_ASSETS_DIR="${TEST_ROOT}/Managed Branding/"
	SD_BANNER_IMAGE="Company Banner.PNG"
	initialize_branding_configuration || return 1
	assert_equal "${TEST_ROOT}/Managed Branding" "${BRANDING_ASSETS_DIR}" "normalized branding-assets directory" || return 1
	assert_equal "${TEST_ROOT}/Managed Branding/Company Banner.PNG" "${SD_BANNER_IMAGE}" "custom banner path"
}

function test_absolute_banner_path_is_preserved ()
{
	# PURPOSE: Verify an explicitly configured absolute local banner path is not rebased.
	# PARMS: None
	# RETURN: 0 when the absolute banner path remains unchanged.

	local absolute_banner="${TEST_ROOT}/Independent/Banner.heic"

	BRANDING_ASSETS_DIR="${TEST_ROOT}/Managed Branding"
	SD_BANNER_IMAGE="${absolute_banner}"
	initialize_branding_configuration || return 1
	assert_equal "${absolute_banner}" "${SD_BANNER_IMAGE}" "absolute banner path"
}

function test_invalid_branding_configuration_is_rejected ()
{
	# PURPOSE: Verify ambiguous or traversing branding paths fail validation.
	# PARMS: None
	# RETURN: 0 when all unsafe configuration variants are rejected.

	BRANDING_ASSETS_DIR="relative/assets"
	SD_BANNER_IMAGE="Banner.png"
	assert_failure initialize_branding_configuration || return 1

	BRANDING_ASSETS_DIR="${TEST_ROOT}/Branding/../Elsewhere"
	SD_BANNER_IMAGE="Banner.png"
	assert_failure initialize_branding_configuration || return 1

	BRANDING_ASSETS_DIR="${TEST_ROOT}/Branding"
	SD_BANNER_IMAGE="../Banner.png"
	assert_failure initialize_branding_configuration || return 1

	BRANDING_ASSETS_DIR="${TEST_ROOT}/Branding"
	SD_BANNER_IMAGE="Banner.txt"
	assert_failure initialize_branding_configuration || return 1

	BRANDING_ASSETS_DIR="${TEST_ROOT}/Branding"
	SD_BANNER_IMAGE=$'Banner\tName.png'
	assert_failure initialize_branding_configuration
}

function test_existing_banner_skips_jamf_policy ()
{
	# PURPOSE: Verify an already-readable banner does not trigger an external Jamf policy.
	# PARMS: None
	# RETURN: 0 when the existing asset is accepted without a Jamf binary.

	SD_BANNER_IMAGE="${TEST_ROOT}/Existing/Banner.png"
	/bin/mkdir -p "${SD_BANNER_IMAGE:h}" || return 1
	: > "${SD_BANNER_IMAGE}" || return 1
	JAMF_BINARY="${TEST_ROOT}/does-not-exist"
	assert_success check_branding_assets
}

function test_missing_banner_invokes_renamed_policy ()
{
	# PURPOSE: Verify a successful branding event must produce the configured local banner.
	# PARMS: None
	# RETURN: 0 when the renamed event is invoked and its installed banner is accepted.

	local mock_jamf="${TEST_ROOT}/mock-jamf-success"
	local argument_log="${TEST_ROOT}/mock-jamf-success.args"

	create_mock_jamf_binary "${mock_jamf}" || return 1
	JAMF_BINARY="${mock_jamf}"
	BRANDING_ASSETS_INSTALL_POLICY="install_BrandingAssets"
	SD_BANNER_IMAGE="${TEST_ROOT}/Branding/Banner.png"
	export APPDELETE_TEST_JAMF_ARGS="${argument_log}"
	export APPDELETE_TEST_INSTALL_BANNER=1
	export APPDELETE_TEST_BANNER="${SD_BANNER_IMAGE}"
	export APPDELETE_TEST_JAMF_EXIT=0

	check_branding_assets || return 1
	assert_exists "${SD_BANNER_IMAGE}" || return 1
	assert_equal "policy -event install_BrandingAssets" "$(<"${argument_log}")" "Jamf branding event arguments"
}

function test_branding_policy_failure_is_fail_closed ()
{
	# PURPOSE: Verify a failed Jamf branding policy prevents dependency readiness.
	# PARMS: None
	# RETURN: 0 when a nonzero Jamf status is propagated.

	local mock_jamf="${TEST_ROOT}/mock-jamf-failure"

	create_mock_jamf_binary "${mock_jamf}" || return 1
	JAMF_BINARY="${mock_jamf}"
	BRANDING_ASSETS_INSTALL_POLICY="install_BrandingAssets"
	SD_BANNER_IMAGE="${TEST_ROOT}/Missing/Banner.png"
	export APPDELETE_TEST_JAMF_ARGS="${TEST_ROOT}/mock-jamf-failure.args"
	export APPDELETE_TEST_INSTALL_BANNER=0
	export APPDELETE_TEST_BANNER="${SD_BANNER_IMAGE}"
	export APPDELETE_TEST_JAMF_EXIT=12

	assert_failure check_branding_assets || return 1
	assert_not_exists "${SD_BANNER_IMAGE}"
}

function test_branding_policy_requires_banner_postcondition ()
{
	# PURPOSE: Verify a zero Jamf status is insufficient when the expected asset remains absent.
	# PARMS: None
	# RETURN: 0 when the missing postcondition causes a failure.

	local mock_jamf="${TEST_ROOT}/mock-jamf-no-asset"

	create_mock_jamf_binary "${mock_jamf}" || return 1
	JAMF_BINARY="${mock_jamf}"
	BRANDING_ASSETS_INSTALL_POLICY="install_BrandingAssets"
	SD_BANNER_IMAGE="${TEST_ROOT}/StillMissing/Banner.png"
	export APPDELETE_TEST_JAMF_ARGS="${TEST_ROOT}/mock-jamf-no-asset.args"
	export APPDELETE_TEST_INSTALL_BANNER=0
	export APPDELETE_TEST_BANNER="${SD_BANNER_IMAGE}"
	export APPDELETE_TEST_JAMF_EXIT=0

	assert_failure check_branding_assets || return 1
	assert_not_exists "${SD_BANNER_IMAGE}"
}

function test_swift_dialog_policy_failure_is_fail_closed ()
{
	# PURPOSE: Verify a failed Swift Dialog Jamf event prevents dependency readiness.
	# PARMS: None
	# RETURN: 0 when the nonzero Jamf status is propagated and no binary appears.

	local mock_jamf="${TEST_ROOT}/mock-jamf-dialog-failure"

	create_mock_jamf_binary "${mock_jamf}" || return 1
	JAMF_BINARY="${mock_jamf}"
	DIALOG_INSTALL_POLICY="install_SwiftDialog"
	SW_DIALOG="${TEST_ROOT}/Missing/dialog"
	SD_VERSION="0.0.0"
	export APPDELETE_TEST_JAMF_ARGS="${TEST_ROOT}/mock-jamf-dialog-failure.args"
	export APPDELETE_TEST_INSTALL_BANNER=0
	export APPDELETE_TEST_INSTALL_DIALOG=0
	export APPDELETE_TEST_DIALOG="${SW_DIALOG}"
	export APPDELETE_TEST_JAMF_EXIT=14

	assert_failure check_swift_dialog_install || return 1
	assert_not_exists "${SW_DIALOG}"
}

function test_swift_dialog_policy_requires_verified_postcondition ()
{
	# PURPOSE: Verify a successful event must install an executable, sufficiently new dialog binary.
	# PARMS: None
	# RETURN: 0 when installation and version postconditions are enforced.

	local mock_jamf="${TEST_ROOT}/mock-jamf-dialog-success"
	local argument_log="${TEST_ROOT}/mock-jamf-dialog-success.args"

	create_mock_jamf_binary "${mock_jamf}" || return 1
	JAMF_BINARY="${mock_jamf}"
	DIALOG_INSTALL_POLICY="install_SwiftDialog"
	SW_DIALOG="${TEST_ROOT}/Installed/dialog"
	SD_VERSION="0.0.0"
	export APPDELETE_TEST_JAMF_ARGS="${argument_log}"
	export APPDELETE_TEST_INSTALL_BANNER=0
	export APPDELETE_TEST_INSTALL_DIALOG=1
	export APPDELETE_TEST_DIALOG="${SW_DIALOG}"
	export APPDELETE_TEST_DIALOG_VERSION="3.2.0"
	export APPDELETE_TEST_JAMF_EXIT=0

	check_swift_dialog_install || return 1
	[[ -x "${SW_DIALOG}" ]] || fail "Expected an executable Swift Dialog test binary" || return 1
	assert_equal "3.2.0" "${SD_VERSION}" "installed Swift Dialog version" || return 1
	assert_equal "policy -event install_SwiftDialog" "$(<"${argument_log}")" "Jamf Swift Dialog event arguments"
}

source "${APPDELETE_SCRIPT}" >/dev/null || {
	print -u2 -- "Unable to load ${APPDELETE_SCRIPT}"
	exit 1
}
autoload 'is-at-least'

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
run_test test_protected_matching_is_exact_not_substring
run_test test_protected_names_treat_glob_characters_literally
run_test test_invalid_protected_configuration_fails_closed
run_test test_duplicate_protected_names_are_normalized_once
run_test test_protection_is_rechecked_before_deletion
run_test test_allowed_folders_cannot_reintroduce_app_bundles
run_test test_confirmation_snapshot_ignores_legacy_selection_file
run_test test_tampered_target_map_fails_before_any_deletion
run_test test_target_replaced_by_symlink_is_rejected
run_test test_valid_allowed_folder_deletion
run_test test_default_branding_configuration_contract
run_test test_custom_branding_directory_is_resolved
run_test test_absolute_banner_path_is_preserved
run_test test_invalid_branding_configuration_is_rejected
run_test test_existing_banner_skips_jamf_policy
run_test test_missing_banner_invokes_renamed_policy
run_test test_branding_policy_failure_is_fail_closed
run_test test_branding_policy_requires_banner_postcondition
run_test test_swift_dialog_policy_failure_is_fail_closed
run_test test_swift_dialog_policy_requires_verified_postcondition

print -- ""
print -- "${TESTS_PASSED} passed; ${TESTS_FAILED} failed"
[[ ${TESTS_FAILED} -eq 0 ]]
