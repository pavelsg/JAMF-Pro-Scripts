#!/bin/zsh
# Integration tests for the generic macOS file-package builder.
# Packages are built and expanded under /private/tmp; nothing is installed.

setopt NO_UNSET PIPE_FAIL

typeset -gr SCRIPT_DIR="${0:A:h}"
typeset -gr BUILDER="${SCRIPT_DIR:h}/build-file-package.zsh"
typeset -g TEST_ROOT=""
typeset -gi TEST_COUNTER=0
typeset -gi TESTS_PASSED=0
typeset -gi TESTS_FAILED=0

function cleanup_test_root ()
{
	# PURPOSE: Remove only this suite's isolated fixture directory.
	# PARMS: TEST_ROOT
	# RETURN: None.

	trap - EXIT HUP INT TERM
	case "${TEST_ROOT}" in
		/private/tmp/BuildFilePackageTests.[[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]])
			if [[ -d "${TEST_ROOT}" && ! -L "${TEST_ROOT}" ]]; then
				/bin/chmod -R u+rwX "${TEST_ROOT}" 2>/dev/null || return 1
				/bin/rm -rf -- "${TEST_ROOT}"
			fi
			;;
	esac
}

function fail ()
{
	# PURPOSE: Report one assertion failure.
	# PARMS: $1 - Message.
	# RETURN: Always 1.

	print -u2 -r -- "    $1"
	return 1
}

function assert_success ()
{
	# PURPOSE: Require a command to return status 0.
	# PARMS: Command and arguments.
	# RETURN: 0 on success; otherwise 1.

	"$@" || fail "Expected success: $*"
}

function assert_failure ()
{
	# PURPOSE: Require a command to return a nonzero status.
	# PARMS: Command and arguments.
	# RETURN: 0 for expected failure; otherwise 1.

	if "$@"; then
		fail "Expected failure: $*"
		return 1
	fi
	return 0
}

function assert_equal ()
{
	# PURPOSE: Require two scalar values to be equal.
	# PARMS: $1 - Expected; $2 - actual; $3 - context.
	# RETURN: 0 when equal; otherwise 1.

	[[ "$2" == "$1" ]] || fail "$3: expected '$1', got '$2'"
}

function assert_exists ()
{
	# PURPOSE: Require a regular path to exist.
	# PARMS: $1 - Path.
	# RETURN: 0 when present; otherwise 1.

	[[ -e "$1" && ! -L "$1" ]] || fail "Expected path to exist: $1"
}

function assert_not_exists ()
{
	# PURPOSE: Require a path, including a symlink, to be absent.
	# PARMS: $1 - Path.
	# RETURN: 0 when absent; otherwise 1.

	[[ ! -e "$1" && ! -L "$1" ]] || fail "Expected path to be absent: $1"
}

function assert_line ()
{
	# PURPOSE: Require an exact line in multiline text.
	# PARMS: $1 - Expected line; $2 - text.
	# RETURN: 0 when present; otherwise 1.

	local line

	for line in "${(f)2}"; do
		[[ "${line#./}" == "$1" ]] && return 0
	done
	fail "Expected exact line: $1"
}

function assert_no_line ()
{
	# PURPOSE: Require an exact line to be absent from multiline text.
	# PARMS: $1 - Disallowed line; $2 - text.
	# RETURN: 0 when absent; otherwise 1.

	local line

	for line in "${(f)2}"; do
		if [[ "${line#./}" == "$1" ]]; then
			fail "Unexpected exact line: $1"
			return 1
		fi
	done
	return 0
}

function new_fixture ()
{
	# PURPOSE: Create and return a unique test fixture below TEST_ROOT.
	# PARMS: None
	# RETURN: 0 with the path in REPLY.

	REPLY="${TEST_ROOT}/fixture-${TEST_COUNTER}"
	(( TEST_COUNTER++ ))
	/bin/mkdir -p "${REPLY}"
}

function run_test ()
{
	# PURPOSE: Run one test and update suite totals.
	# PARMS: $1 - Test function.
	# RETURN: Always 0.

	local test_name="$1"

	if "${test_name}"; then
		print -r -- "PASS ${test_name}"
		(( TESTS_PASSED++ ))
	else
		print -u2 -r -- "FAIL ${test_name}"
		(( TESTS_FAILED++ ))
	fi
	return 0
}

function test_help_documents_contract ()
{
	# PURPOSE: Verify the CLI exposes its required mapping contract.
	# PARMS: None
	# RETURN: 0 when help succeeds and identifies the primary options.

	local help_output

	help_output=$("${BUILDER}" --help) || return 1
	[[ "${help_output}" == *'--identifier'* ]] || return 1
	[[ "${help_output}" == *'--version'* ]] || return 1
	[[ "${help_output}" == *'--map SOURCE DEST MODE'* ]] || return 1
	[[ "${help_output}" == *'--tree SOURCE DEST FILE_MODE DIRECTORY_MODE'* ]]
}

function test_builds_multiple_file_payload_with_modes ()
{
	# PURPOSE: Build and expand a real package containing files with spaces and distinct modes.
	# PARMS: None
	# RETURN: 0 when payload paths, content, and modes are exact.

	local fixture
	local first_source
	local second_source
	local third_source
	local output_package
	local expanded_package
	local payload_listing

	new_fixture || return 1
	fixture="${REPLY}"
	first_source="${fixture}/banner source.png"
	second_source="${fixture}/helper source.sh"
	third_source="${fixture}/private source.dat"
	output_package="${fixture}/dist/Files-1.2.3.pkg"
	expanded_package="${fixture}/expanded"
	print -r -- 'fake png fixture' > "${first_source}" || return 1
	print -r -- '#!/bin/zsh' > "${second_source}" || return 1
	print -r -- 'private fixture' > "${third_source}" || return 1

	"${BUILDER}" \
		--identifier com.example.tests.file-package \
		--version 1.2.3 \
		--output "${output_package}" \
		--map "${first_source}" "/Library/Application Support/File Package/banner image.png" 0644 \
		--map "${second_source}" "/usr/local/share/file-package/helper.sh" 755 \
		--map "${third_source}" "/Library/Application Support/File Package/private.dat" 0400 \
		>/dev/null || return 1

	assert_exists "${output_package}" || return 1
	payload_listing=$(/usr/sbin/pkgutil --payload-files "${output_package}") || return 1
	assert_line "Library/Application Support/File Package/banner image.png" "${payload_listing}" || return 1
	assert_line "usr/local/share/file-package/helper.sh" "${payload_listing}" || return 1
	assert_line "Library/Application Support/File Package/private.dat" "${payload_listing}" || return 1

	/usr/sbin/pkgutil --expand-full "${output_package}" "${expanded_package}" || return 1
	assert_equal "fake png fixture" "$(<"${expanded_package}/Payload/Library/Application Support/File Package/banner image.png")" "expanded banner content" || return 1
	assert_equal "#!/bin/zsh" "$(<"${expanded_package}/Payload/usr/local/share/file-package/helper.sh")" "expanded helper content" || return 1
	assert_equal "644" "$(/usr/bin/stat -f '%Lp' "${expanded_package}/Payload/Library/Application Support/File Package/banner image.png")" "expanded banner mode" || return 1
	assert_equal "755" "$(/usr/bin/stat -f '%Lp' "${expanded_package}/Payload/usr/local/share/file-package/helper.sh")" "expanded helper mode" || return 1
	assert_equal "400" "$(/usr/bin/stat -f '%Lp' "${expanded_package}/Payload/Library/Application Support/File Package/private.dat")" "expanded private mode" || return 1
	assert_equal "755" "$(/usr/bin/stat -f '%Lp' "${expanded_package}/Payload/Library/Application Support/File Package")" "expanded parent-directory mode"
}

function test_refuses_to_replace_existing_output ()
{
	# PURPOSE: Verify repeated builds cannot overwrite a reviewed package artifact.
	# PARMS: None
	# RETURN: 0 when the second build fails and the original checksum is unchanged.

	local fixture
	local source_file
	local output_package
	local original_checksum

	new_fixture || return 1
	fixture="${REPLY}"
	source_file="${fixture}/source.txt"
	output_package="${fixture}/output.pkg"
	print -r -- 'immutable output test' > "${source_file}" || return 1

	"${BUILDER}" --identifier com.example.tests.no-overwrite --version 1.0 --output "${output_package}" \
		--map "${source_file}" "/Library/Application Support/FilePackage/source.txt" 0644 >/dev/null || return 1
	original_checksum=$(/usr/bin/shasum -a 256 "${output_package}") || return 1
	assert_failure "${BUILDER}" --identifier com.example.tests.no-overwrite --version 1.0 --output "${output_package}" \
		--map "${source_file}" "/Library/Application Support/FilePackage/source.txt" 0644 >/dev/null 2>&1 || return 1
	assert_equal "${original_checksum}" "$(/usr/bin/shasum -a 256 "${output_package}")" "existing package checksum"
}

function test_builds_nested_tree_with_hidden_and_empty_directories ()
{
	# PURPOSE: Verify --tree preserves hierarchy, hidden files, empty directories, and modes.
	# PARMS: None
	# RETURN: 0 when a tree-only package is complete and excludes Finder metadata.

	local fixture
	local tree_source
	local output_package
	local expanded_package
	local payload_listing
	local -a remaining_staging_directories

	new_fixture || return 1
	fixture="${REPLY}"
	tree_source="${fixture}/source tree"
	output_package="${fixture}/dist/Tree-2.0.pkg"
	expanded_package="${fixture}/expanded-tree"
	/bin/mkdir -p "${tree_source}/Nested/Deep" "${tree_source}/Empty" "${tree_source}/.Hidden" || return 1
	print -r -- 'nested content' > "${tree_source}/Nested/Deep/content.txt" || return 1
	print -r -- 'hidden content' > "${tree_source}/.Hidden/.configuration" || return 1
	print -r -- 'finder metadata' > "${tree_source}/Nested/.DS_Store" || return 1

	"${BUILDER}" \
		--identifier com.example.tests.tree-package \
		--version 2.0 \
		--output "${output_package}" \
		--tree "${tree_source}" "/Library/Application Support/File Package/Tree Payload" 0640 0555 \
		>/dev/null || return 1

	assert_exists "${output_package}" || return 1
	remaining_staging_directories=("${output_package:h}"/BuildFilePackage.*(N))
	assert_equal "0" "${#remaining_staging_directories}" "staging directories after tree build" || return 1
	payload_listing=$(/usr/sbin/pkgutil --payload-files "${output_package}") || return 1
	assert_line "Library/Application Support/File Package/Tree Payload" "${payload_listing}" || return 1
	assert_line "Library/Application Support/File Package/Tree Payload/Nested/Deep/content.txt" "${payload_listing}" || return 1
	assert_line "Library/Application Support/File Package/Tree Payload/Empty" "${payload_listing}" || return 1
	assert_line "Library/Application Support/File Package/Tree Payload/.Hidden/.configuration" "${payload_listing}" || return 1
	assert_no_line "Library/Application Support/File Package/Tree Payload/Nested/.DS_Store" "${payload_listing}" || return 1

	/usr/sbin/pkgutil --expand-full "${output_package}" "${expanded_package}" || return 1
	assert_equal "nested content" "$(<"${expanded_package}/Payload/Library/Application Support/File Package/Tree Payload/Nested/Deep/content.txt")" "nested tree content" || return 1
	assert_equal "hidden content" "$(<"${expanded_package}/Payload/Library/Application Support/File Package/Tree Payload/.Hidden/.configuration")" "hidden tree content" || return 1
	assert_equal "640" "$(/usr/bin/stat -f '%Lp' "${expanded_package}/Payload/Library/Application Support/File Package/Tree Payload/Nested/Deep/content.txt")" "tree file mode" || return 1
	assert_equal "555" "$(/usr/bin/stat -f '%Lp' "${expanded_package}/Payload/Library/Application Support/File Package/Tree Payload/Empty")" "empty tree directory mode" || return 1
	assert_not_exists "${expanded_package}/Payload/Library/Application Support/File Package/Tree Payload/Nested/.DS_Store"
}

function test_rejects_unsafe_sources_destinations_and_modes ()
{
	# PURPOSE: Verify filesystem-boundary validation fails before pkgbuild is invoked.
	# PARMS: None
	# RETURN: 0 when symlinks, relative/traversing paths, and special modes all fail.

	local fixture
	local source_file
	local source_link

	new_fixture || return 1
	fixture="${REPLY}"
	source_file="${fixture}/source.txt"
	source_link="${fixture}/source-link.txt"
	print -r -- 'validation fixture' > "${source_file}" || return 1
	/bin/ln -s "${source_file}" "${source_link}" || return 1

	assert_failure "${BUILDER}" --identifier com.example.tests.validation --version 1 --output "${fixture}/symlink.pkg" --map "${source_link}" /Library/Test.txt 0644 >/dev/null 2>&1 || return 1
	assert_failure "${BUILDER}" --identifier com.example.tests.validation --version 1 --output "${fixture}/relative.pkg" --map "${source_file}" Library/Test.txt 0644 >/dev/null 2>&1 || return 1
	assert_failure "${BUILDER}" --identifier com.example.tests.validation --version 1 --output "${fixture}/traversal.pkg" --map "${source_file}" /Library/../private/Test.txt 0644 >/dev/null 2>&1 || return 1
	assert_failure "${BUILDER}" --identifier com.example.tests.validation --version 1 --output "${fixture}/mode.pkg" --map "${source_file}" /Library/Test.txt 4755 >/dev/null 2>&1 || return 1
	assert_failure "${BUILDER}" --identifier com.example.tests.validation --version 1 --output "${fixture}/unreadable.pkg" --map "${source_file}" /Library/Test.txt 000 >/dev/null 2>&1
}

function test_rejects_unsafe_tree_sources_and_modes ()
{
	# PURPOSE: Verify recursive inputs fail closed on symlinks, special files, and unsafe modes.
	# PARMS: None
	# RETURN: 0 when every unsafe tree variant is rejected before pkgbuild.

	local fixture
	local safe_tree
	local symlink_tree
	local special_tree
	local tree_link

	new_fixture || return 1
	fixture="${REPLY}"
	safe_tree="${fixture}/safe-tree"
	symlink_tree="${fixture}/symlink-tree"
	special_tree="${fixture}/special-tree"
	tree_link="${fixture}/tree-link"
	/bin/mkdir -p "${safe_tree}" "${symlink_tree}" "${special_tree}" || return 1
	print -r -- 'tree file' > "${safe_tree}/file.txt" || return 1
	/bin/ln -s "${safe_tree}/file.txt" "${symlink_tree}/file-link.txt" || return 1
	/bin/ln -s "${safe_tree}" "${tree_link}" || return 1
	/usr/bin/mkfifo "${special_tree}/named-pipe" || return 1

	assert_failure "${BUILDER}" --identifier com.example.tests.tree-validation --version 1 --output "${fixture}/root-link.pkg" --tree "${tree_link}" /Library/Tree 0644 0755 >/dev/null 2>&1 || return 1
	assert_failure "${BUILDER}" --identifier com.example.tests.tree-validation --version 1 --output "${fixture}/nested-link.pkg" --tree "${symlink_tree}" /Library/Tree 0644 0755 >/dev/null 2>&1 || return 1
	assert_failure "${BUILDER}" --identifier com.example.tests.tree-validation --version 1 --output "${fixture}/special.pkg" --tree "${special_tree}" /Library/Tree 0644 0755 >/dev/null 2>&1 || return 1
	assert_failure "${BUILDER}" --identifier com.example.tests.tree-validation --version 1 --output "${fixture}/relative-tree.pkg" --tree "${safe_tree}" Library/Tree 0644 0755 >/dev/null 2>&1 || return 1
	assert_failure "${BUILDER}" --identifier com.example.tests.tree-validation --version 1 --output "${fixture}/tree-file-mode.pkg" --tree "${safe_tree}" /Library/Tree 000 0755 >/dev/null 2>&1 || return 1
	assert_failure "${BUILDER}" --identifier com.example.tests.tree-validation --version 1 --output "${fixture}/tree-dir-mode.pkg" --tree "${safe_tree}" /Library/Tree 0644 0644 >/dev/null 2>&1
}

function test_rejects_ambiguous_metadata_and_mappings ()
{
	# PURPOSE: Verify package identity and mapping collisions are rejected deterministically.
	# PARMS: None
	# RETURN: 0 when invalid metadata, duplicate destinations, and collisions all fail.

	local fixture
	local first_source
	local second_source
	local first_tree
	local second_tree

	new_fixture || return 1
	fixture="${REPLY}"
	first_source="${fixture}/first.txt"
	second_source="${fixture}/second.txt"
	first_tree="${fixture}/first-tree"
	second_tree="${fixture}/second-tree"
	print -r -- 'first' > "${first_source}" || return 1
	print -r -- 'second' > "${second_source}" || return 1
	/bin/mkdir -p "${first_tree}" "${second_tree}" || return 1

	assert_failure "${BUILDER}" --identifier INVALID --version 1 --output "${fixture}/identifier.pkg" --map "${first_source}" /Library/First.txt 0644 >/dev/null 2>&1 || return 1
	assert_failure "${BUILDER}" --identifier com.example.valid --version 1.2.beta --output "${fixture}/version.pkg" --map "${first_source}" /Library/First.txt 0644 >/dev/null 2>&1 || return 1
	assert_failure "${BUILDER}" --identifier com.example.valid --version 1 --output "${fixture}/.pkg" --map "${first_source}" /Library/First.txt 0644 >/dev/null 2>&1 || return 1
	assert_failure "${BUILDER}" --identifier com.example.valid --version 1 --output "${fixture}/empty-sign.pkg" --sign "" --map "${first_source}" /Library/First.txt 0644 >/dev/null 2>&1 || return 1
	assert_failure "${BUILDER}" --identifier com.example.valid --version 1 --output "${fixture}/duplicate.pkg" \
		--map "${first_source}" /Library/First.txt 0644 --map "${second_source}" /library/first.txt 0644 >/dev/null 2>&1 || return 1
	assert_failure "${BUILDER}" --identifier com.example.valid --version 1 --output "${fixture}/collision.pkg" \
		--map "${first_source}" /Library/Parent 0644 --map "${second_source}" /Library/Parent/Child.txt 0644 >/dev/null 2>&1 || return 1
	assert_failure "${BUILDER}" --identifier com.example.valid --identifier com.example.other --version 1 --output "${fixture}/repeated.pkg" \
		--map "${first_source}" /Library/First.txt 0644 >/dev/null 2>&1 || return 1
	assert_failure "${BUILDER}" --identifier com.example.valid --version 1 --output "${fixture}/map-tree-overlap.pkg" \
		--map "${first_source}" /Library/Assets/Explicit.txt 0644 --tree "${first_tree}" /Library/Assets 0644 0755 >/dev/null 2>&1 || return 1
	assert_failure "${BUILDER}" --identifier com.example.valid --version 1 --output "${fixture}/tree-overlap.pkg" \
		--tree "${first_tree}" /Library/Assets 0644 0755 --tree "${second_tree}" /Library/Assets/Nested 0644 0755 >/dev/null 2>&1 || return 1
	assert_failure "${BUILDER}" --identifier com.example.valid --version 1 --output "${fixture}/tree-case-overlap.pkg" \
		--tree "${first_tree}" /Library/Assets 0644 0755 --tree "${second_tree}" /library/assets 0644 0755 >/dev/null 2>&1 || return 1
	assert_failure "${BUILDER}" --identifier com.example.valid --version 1 --output "${fixture}/missing-map.pkg" >/dev/null 2>&1
}

[[ -x "${BUILDER}" ]] || {
	print -u2 -r -- "Builder is not executable: ${BUILDER}"
	exit 1
}
[[ -x /usr/bin/pkgbuild && -x /usr/sbin/pkgutil ]] || {
	print -u2 -r -- "Required macOS packaging tools are unavailable."
	exit 1
}

TEST_ROOT=$(/usr/bin/mktemp -d "/private/tmp/BuildFilePackageTests.XXXXXX") || exit 1
trap cleanup_test_root EXIT HUP INT TERM

run_test test_help_documents_contract
run_test test_builds_multiple_file_payload_with_modes
run_test test_builds_nested_tree_with_hidden_and_empty_directories
run_test test_refuses_to_replace_existing_output
run_test test_rejects_unsafe_sources_destinations_and_modes
run_test test_rejects_unsafe_tree_sources_and_modes
run_test test_rejects_ambiguous_metadata_and_mappings

print -r -- ""
print -r -- "${TESTS_PASSED} passed; ${TESTS_FAILED} failed"
[[ ${TESTS_FAILED} -eq 0 ]]
