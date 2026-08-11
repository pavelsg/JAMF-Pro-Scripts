## App Delete

This script is designed to allow non-admin users the ability to remove applications and folders from the /Applications folder. 

You can control what applications users are not allowed to remove by putting their exact Finder names into the `NOT_ALLOWED_APPS` array. Omit the final `.app` bundle suffix. Matching is case-insensitive and literal, so `Falcon` protects only `Falcon`, not `Falcon Sensor`, and characters such as `*` are not treated as patterns. An empty array intentionally permits every discovered application; an invalid path-like entry causes AppDelete to fail closed without presenting deletion choices.

You can also include folders that are allowed to be deleted by putting direct folder names into the `ALLOWED_FOLDERS` array. Paths, `.`, `..`, symbolic links, and names ending in `.app` are rejected. Applications cannot bypass `NOT_ALLOWED_APPS` through the folder configuration.

It automatically excludes the preinstalled items that come with the OS _[SIP Protected]_.

### Deletion safety

AppDelete runs as root so non-admin users can remove approved items. The script therefore treats Swift Dialog output as untrusted:

- The dialog configuration is stored in a mode `0600` temporary file.
- Checkbox labels are assigned opaque IDs; dialog output never becomes a filesystem path.
- Selected IDs and their exact targets remain in process memory.
- The same validated selection snapshot is used for confirmation and deletion.
- Every target is revalidated as an approved, non-symlinked direct child of `/Applications` before any item in the batch is deleted.
- Protected-application policy is enforced during discovery and immediately before deletion.

Run the security regression suite after changing discovery, selection, or deletion behavior:

```shell
zsh AppDelete/tests/AppDeleteSecurityTests.zsh
```

### Screenshots ###
Picture of what the end users see when they run it:

![User's View](./AppDelete-Welcome.png)

The script will have them confirm their choices before the actual deletion occurs

![](./AppDelete-Confirm.png)

and give them an option to do it again (and again)

![](./AppDelete-Results.png)


| **Version**|**Notes**|
|:--------:|-----|
| 1.0 |  Initial Release |
| 1.1 |  Major code cleanup & documentation |
||		Structured code to be more inline / consistent across all apps |
| 1.2 |  Remove the MAC_HADWARE_CLASS item as it was misspelled and not used anymore... |
| 2.0 |  Bumped Swift Dialog min version to 2.5.0 |
||		NEW: Added option to allow folders to be deleted (ALLOWED_FOLDERS) |
||		Put shadows in the banner text |
|| 		Reordered sections to better show what can be modified |
| 2.1 |  Added option to sort array (case insensitive) after the application scan & folders added  |
| 2.2 |  Code cleanup |
||       Added feature to read in defaults file |
||        removed unnecessary variables. |
||        Fixed typos |
| 2.3 |  Add logic in the delete_files section to not continue processing if name is blank |
|| Fixed issue with reading in the defaults file and setting the variables. |
| 2.4 | Changed JAMF 'policy -trigger' to 'JAMF policy -event'
||       Optimized "Common" section for better performance
||       Fixed variable names in the defaults file section
| 2.5 | Updated SD Version requirements to 3.1.0
||       Added ability to set subtitle, color, and padding from defaults file
| 2.6 | Prevented local selection-file tampering and path traversal |
|| Selection state is held in memory and represented by opaque dialog IDs |
|| Added exact target validation, root-only temporary state, cleanup traps, and security regression tests |
| 2.7 | Replaced protected-app substring removal with validated, case-insensitive exact matching |
|| Added fail-closed policy initialization and deletion-time protection checks |
|| Prevented application bundles from bypassing protection through `ALLOWED_FOLDERS` |
