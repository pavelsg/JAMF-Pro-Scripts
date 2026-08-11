# AppDelete Security and Behavior Audit

## Audit metadata

- Audit date: 2026-08-11
- Repository commit: `43b3561`
- Audited implementation: `AppDelete/AppDelete.sh`
- Audited documentation: `AppDelete/README.md`
- Audit type: Read-only static review with non-destructive parsing and path-resolution checks

### Remediation update

AD-001 was remediated in the current uncommitted working tree on 2026-08-11. The original finding below describes commit `43b3561`; the added "Remediation implemented" section records the replacement security boundary and verification results. Other audit findings remain independently applicable unless explicitly noted.

## Executive summary

The current AppDelete script is **not safe to deploy in its intended Jamf/root execution context**.

The primary issue is a high-severity arbitrary-directory deletion vulnerability. The script stores the user's selected items in a world-writable temporary file, constructs the confirmation message from that file, and then reads the file again after confirmation. It does not verify that the final values came from the displayed application list, reject path traversal, or confirm that each deletion target is a direct child of `/Applications`.

Consequently, a local non-admin user or process can alter the selection file while the confirmation dialog is open and cause the root-running script to execute `rm -rf` against a directory outside `/Applications`. The substituted target would not be shown in the confirmation dialog.

The script also invokes two Jamf policy events whose implementations are not present in this repository. Those events can install software or perform other server-configured actions and must be audited separately.

## Scope and methodology

The audit covered all 435 lines of `AppDelete/AppDelete.sh`, its README, repository references to its configuration and Jamf policy events, and the script's external command usage.

Checks performed included:

- Mapping the script's functions and execution flow.
- Tracing every recursive deletion operand back to its input.
- Reviewing temporary-file creation, permissions, parsing, and cleanup.
- Reviewing application discovery and protected-application filtering.
- Identifying subprocesses, Jamf policy triggers, local writes, logged data, and collected system information.
- Running `zsh -n AppDelete/AppDelete.sh`, which completed successfully.
- Performing non-destructive tests of the selection parser and path resolution. The AppDelete script itself was not executed.

Swift Dialog was not installed in the audit environment, so a full UI integration test was not performed. The high-severity finding does not depend on Swift Dialog internals because it exists in the script's temporary-file and deletion logic.

## Findings

### AD-001: A local user can cause arbitrary root-level directory deletion

- Severity: High
- Status: Remediated in the current working tree; pending commit and staged-device UI verification
- Affected lines: 57-60, 319, 329-336, 356-379

#### Evidence

The script creates two unpredictable temporary files with `mktemp`, but immediately makes both files writable by every local user:

```zsh
JSON_OPTIONS=$(mktemp /var/tmp/$SCRIPT_NAME.XXXXX)
TMP_FILE_STORAGE=$(mktemp /var/tmp/$SCRIPT_NAME.XXXXX)
/bin/chmod 666 $JSON_OPTIONS
/bin/chmod 666 $TMP_FILE_STORAGE
```

`TMP_FILE_STORAGE` remains mode `0666` throughout the workflow. The script writes the dialog output into it:

```zsh
echo $tmp | grep -v ": false" > "${TMP_FILE_STORAGE}"
```

It reads the file once to construct `messagebody`, which is shown to the user in the final confirmation dialog. After confirmation, `delete_files` opens and reads the same mutable file again.

Each line is converted into `name`, but the script performs no exact-membership check against `FILES_LIST`, no validation against `ALLOWED_FOLDERS`, no rejection of `..` or `/`, and no canonical-path containment check:

```zsh
name=$( echo "${line}" | xargs | /usr/bin/awk -F " : " '{print $1}' | tr -d '"')

if [[ -d "/Applications/${name}.app" ]]; then
    /bin/rm -rf "/Applications/${name}.app"
elif [[ -d "/Applications/${name}" ]]; then
    /bin/rm -rf "/Applications/${name}"
fi
```

A non-destructive test using the existing parser demonstrated that a forged selected-item name of `../../private/tmp`:

- Is parsed without modification.
- Satisfies the folder branch's `-d` check.
- Produces the operand `/Applications/../../private/tmp`.
- Resolves to `/private/tmp`.

No deletion was executed during the test.

#### Attack sequence

1. AppDelete starts in its intended Jamf/root context and creates `/var/tmp/AppDelete.XXXXX` with mode `0666`.
2. The user completes the selection screen.
3. The script reads the selection file and displays the confirmation message.
4. While the confirmation dialog is open, a local user or process rewrites the world-writable selection file with a path-traversal value.
5. The user clicks Delete.
6. `delete_files` rereads the modified file and executes root-level recursive deletion against the substituted path.

The confirmation message is not recalculated after step 4, so it does not disclose the substituted target.

#### Impact

An authorized Self Service user who does not have administrator privileges can potentially delete root-owned directories outside `/Applications`. This can destroy user data, application data, management tooling, or operating-system components and can make the Mac unusable.

#### Required remediation

- Keep temporary state root-only with mode `0600`; do not change it to `0666`.
- Prefer keeping the parsed selection in memory rather than rereading a mutable file after confirmation.
- Freeze one validated selection snapshot and use that same snapshot for both confirmation and deletion.
- Require every selection to exactly match an entry generated by the script.
- Reject empty names, `.`, `..`, `/`, path separators, control characters, and unexpected extensions.
- Canonicalize each target and verify it is an allowed direct child of `/Applications` before deletion.
- Revalidate the target type and allowlist membership immediately before `rm`.
- Use `rm -rf -- "$validated_target"` only after all validation succeeds.

#### Remediation implemented

- Removed the disk-backed selection file entirely.
- Kept the remaining Swift Dialog configuration file mode `0600` with signal and exit cleanup traps.
- Assigned each checkbox a safe opaque ID and retained the ID-to-path mapping in process memory.
- Rejected unknown, duplicate, missing, and malformed dialog result IDs.
- Frozen one validated in-memory selection for both confirmation and deletion.
- Required targets to be non-symlinked direct children of `/Applications` with an exact expected path and type.
- Revalidated the entire confirmed batch before deleting any item.
- Added isolated regression tests covering traversal input, forged IDs, legacy selection-file tampering, mapping substitution, symlink replacement, batch fail-closed behavior, and valid app/folder deletion.

Verification command:

```shell
zsh AppDelete/tests/AppDeleteSecurityTests.zsh
```

Current full-suite result: `20 passed; 0 failed`.

### AD-002: The protected-application control is unreliable and incorrectly documented

- Severity: Medium
- Status: Remediated in the current working tree; pending commit and staged-device UI verification
- Affected lines: README line 5; script lines 101-108 and 239-245

The README instructs administrators to add protected applications to `MANAGED_APPS`, but the implementation reads `NOT_ALLOWED_APPS`. Following the README therefore does not update the list used by the script.

The implementation also uses case-sensitive substring replacement:

```zsh
for i in "${NOT_ALLOWED_APPS[@]}"; do FILES_LIST=("${FILES_LIST[@]/$i}") ; done
```

Non-destructive tests demonstrated the following behavior:

| Discovered name | Result after filtering |
| --- | --- |
| `Self Service` | Removed from the list |
| `SELF SERVICE` | Remains in the list |
| `Self Service Beta` | Changed to ` Beta` |
| `Falcon Sensor` | Changed to ` Sensor` |

The script does not enforce the protected-app list again at deletion time. It must not be treated as a security boundary.

#### Required remediation

- Correct the README to use the implemented configuration name.
- Compare complete names rather than replacing matching substrings.
- Define and consistently apply the intended case-sensitivity rules.
- Recheck protected applications immediately before deletion.
- Add regression tests for exact matches, case variants, prefixes, suffixes, and names containing spaces.

#### Remediation implemented

- Corrected the README to reference `NOT_ALLOWED_APPS` and documented its exact configuration contract.
- Replaced substring replacement with a validated, case-normalized associative policy set.
- Made matching case-insensitive, exact, and literal; glob-like configuration characters have no pattern behavior.
- Made invalid path-like protected entries fail closed instead of silently weakening protection.
- Excluded protected applications during discovery and rechecked the policy immediately before deletion.
- Prevented names ending in `.app` from being reintroduced through `ALLOWED_FOLDERS`.
- Added regression tests for case variants, exact-versus-substring behavior, special characters, duplicate normalized names, invalid configuration, deletion-time enforcement, and folder-list bypasses.

Verification result: `20 passed; 0 failed`.

### AD-003: The script invokes opaque Jamf policies not documented in the README

- Severity: Operational/security dependency
- Status: Requires separate Jamf server review
- Affected lines: 98-99, 162-197

The script invokes these custom Jamf policy events:

```text
install_SwiftDialog
install_SymFiles
```

`install_SwiftDialog` runs if Swift Dialog is missing or below the required version. `install_SymFiles` runs when the configured banner image is missing and its name has a recognized image extension.

These events are not defined in this repository. The script names suggest installation behavior, but a Jamf custom event executes whatever actions are associated with it on the Jamf server. Those actions can include package installation, downloads, scripts, inventory changes, and other privileged operations.

#### Required remediation

- Audit both event definitions in Jamf Pro, including packages, scripts, files and processes, maintenance actions, and policy scope.
- Document these prerequisites and side effects in `AppDelete/README.md`.
- Fail closed with a clear error if a dependency installation fails.

### AD-004: Deletion failures are logged and displayed as successes

- Severity: Low
- Status: Remediated in the current working tree as part of the fail-closed deletion flow
- Affected lines: 365-405

The return status from `rm` is ignored. The script logs `Removed application` or `Removed Folder` immediately after the command, even when the deletion failed. The completion dialog then says that the listed items were deleted.

This can conceal permission failures, immutable files, filesystem errors, or partial deletion and gives administrators and users inaccurate evidence about the outcome.

#### Required remediation

- Check the return status from every deletion.
- Verify that the target no longer exists.
- Track successful and failed targets separately.
- Show and log an accurate per-target result.
- Return a nonzero script status when any requested deletion fails.

### AD-005: Hand-built JSON and text parsing mishandle valid application names

- Severity: Low, with defense-in-depth security implications
- Status: Partially remediated; JSON escaping, literal suffix handling, original labels, and opaque output IDs are implemented
- Affected lines: 226-284 and 286-336

Application names are interpolated into JSON without JSON escaping. Swift Dialog output is then processed with `echo`, `grep`, `xargs`, `awk`, and `tr` instead of a structured JSON parser.

Names containing quotes, backslashes, newlines, the delimiter ` : `, or other JSON-significant characters can corrupt the dialog configuration or selection parsing. The use of `${(C)i}` also changes capitalization before the label is returned and used to reconstruct the deletion path. This can fail on case-sensitive filesystems and makes the displayed identifier differ from the discovered filename.

The application scan removes `.app` using the regular expression delimiter `.app`, where `.` means any character. Names containing an earlier matching sequence can consequently be truncated.

#### Required remediation

- Generate valid JSON with a structured JSON tool and proper string escaping.
- Parse Swift Dialog's JSON response with a structured parser.
- Preserve the original filename as an internal identifier; use a separate display label if needed.
- Remove only a literal trailing `.app` suffix.
- Add tests for unusual but valid macOS filenames.

### AD-006: Temporary files can survive interrupted execution

- Severity: Low
- Status: Remediated in the current working tree with mode `0600` state and exit/signal cleanup traps
- Affected lines: 199-204 and 414-435

Temporary files are removed only through `cleanup_and_exit`. The script does not install traps for interruption, termination, or abnormal exits. Temporary files can therefore remain in `/var/tmp`; the selection file may remain world-readable and world-writable.

The stored information is normally limited to application or folder names, but leftover mutable files also make concurrent AppDelete executions harder to reason about.

#### Required remediation

- Register an `EXIT`, `INT`, `TERM`, and `HUP` cleanup trap.
- Keep temporary files mode `0600`.
- Use `rm -f --` for known regular temporary files rather than recursive removal.

## Documented and observed deletion scope

Under non-adversarial execution, the script scans only top-level `.app` directories under `/Applications`. It also adds explicitly configured entries from `ALLOWED_FOLDERS` and recursively deletes a selected folder in its entirety.

The current configured folder names are:

- `Zscaler Copy`
- `Utilities copy`
- `Cisco copy`

Folder deletion is mentioned in the README and UI, but administrators should understand that every file and nested directory inside a selected allowed folder is removed, not only application bundles.

The script does not invoke application uninstallers and does not intentionally remove associated preferences, launch agents, caches, receipts, containers, or user data outside the selected bundle or folder.

## Other observed actions and data handling

Apart from deletion, the script performs the following actions:

| Action | Destination or effect | README disclosure |
| --- | --- | --- |
| Reads managed preferences | `/Library/Managed Preferences/com.gianteaglescript.defaults.plist` | Not disclosed |
| Reads console-user information | Local directory services | Not disclosed |
| Reads CPU, RAM, OS, disk-space, and serial-number display data | Displayed in Swift Dialog | Not disclosed |
| Creates temporary files | `/var/tmp/AppDelete.XXXXX` | Not disclosed |
| Creates or modifies a log directory and file | Normally `/Library/Application Support/GiantEagle/logs/AppDelete.log` | Not disclosed |
| Changes log permissions | Directory `0755`; file `0644` | Not disclosed |
| Logs dependency status and removed names | Local log and standard output | Not disclosed |
| Invokes Jamf policy events | `install_SwiftDialog` and `install_SymFiles` | Not disclosed |

When run by Jamf, standard output may be retained in Jamf policy logs. The script itself contains no direct HTTP client call, but the two `jamf policy` invocations may communicate with Jamf infrastructure and execute server-configured content.

The `SupportFiles` value read from managed preferences is trusted without validation and controls the log location. Because managed preferences should be administrator-controlled, this is primarily a configuration trust boundary rather than a low-privilege exploit. It should nevertheless be validated and documented.

## Actions not found in the script

The audit found no direct implementation of the following actions in AppDelete itself:

- Direct `curl`, `wget`, or other HTTP requests.
- Credential or keychain access.
- Configuration-profile changes.
- Launch agent or daemon creation.
- User or group modification.
- Process termination.
- Shell `eval` or execution of a command derived from a selected application name.
- Importing or sourcing `MainLibrary.sh` or another repository script.
- Intentional deletion of application support data outside the selected application or configured folder.

The external Jamf policy events remain capable of performing actions in this list and must be assessed independently.

## Recommended disposition

Do not deploy or continue offering this version through Self Service until AD-001 is fixed and regression-tested. AD-002 should be fixed in the same release because the protected-app list currently provides a false sense of enforcement.

Before release, tests should cover at least:

- A valid selected application.
- A valid explicitly allowed folder.
- An item not present in the generated selection list.
- `..`, `.`, absolute paths, embedded slashes, and repeated separators.
- Symlink and target-replacement behavior.
- Case variants of protected applications.
- Protected names used as prefixes or suffixes of other applications.
- Quotes, backslashes, newlines, Unicode, and delimiter-like application names.
- Deletion failure and partial-failure reporting.
- Cancellation and interruption cleanup.
- Concurrent AppDelete executions.

## Overall conclusion

No intentionally concealed payload or obvious data-exfiltration code was found. However, the current implementation does not constrain its root-level recursive deletion operation to the applications and folders shown to the user. It therefore does not meet the stated safety requirement and should be treated as unsafe until the deletion boundary, temporary-state handling, protected-app enforcement, and external Jamf dependencies are corrected and verified.
