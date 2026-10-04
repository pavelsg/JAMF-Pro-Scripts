# Generic file-package builder

`build-file-package.zsh` creates a macOS Installer component package from explicit file and directory-tree mappings. It is intended for static system-wide content such as Swift Dialog artwork, configuration templates, helper data, or other Jamf-managed resources.

The builder accepts only readable regular files and readable/searchable directories. It rejects symlinks and special files at every tree depth, relative or traversing destinations, case-insensitive duplicate or overlapping destinations, special permission bits, ambiguous package metadata, and existing output packages. Files are staged with cleared extended attributes, packages use Installer-recommended ownership, and the completed payload is inspected before it is published.

## Requirements

- macOS with `/usr/bin/pkgbuild` and `/usr/sbin/pkgutil`.
- A Developer ID Installer identity only when `--sign` is used.
- A stable, organization-owned lowercase reverse-DNS package identifier.

## Command contract

```text
build-file-package.zsh \
  --identifier REVERSE_DNS_ID \
  --version NUMERIC_VERSION \
  --output OUTPUT.pkg \
  [--sign "Developer ID Installer: Organization (TEAMID)"] \
  [--map SOURCE_FILE ABSOLUTE_DESTINATION MODE ...] \
  [--tree SOURCE_DIRECTORY ABSOLUTE_DESTINATION FILE_MODE DIRECTORY_MODE ...]
```

Every `--map` is independent, so one package can contain files with different destinations and modes. File modes are limited to owner-readable `400` through `777` permission bits because `pkgbuild` must read the staged payload. Setuid, setgid, and sticky modes are intentionally unsupported.

`--tree` recursively copies a complete directory hierarchy while applying one explicit mode to every regular file and another to every directory. Directory modes must be owner-readable and searchable (`500-577` or `700-777`). Hidden files and empty directories are included. Finder `.DS_Store` files are omitted. Symlinks, FIFOs, sockets, device files, unreadable entries, and names containing control characters fail the build rather than being silently followed or skipped.

File mappings and tree roots must be disjoint. Tree roots must also be mutually disjoint; this keeps mode ownership and package contents deterministic when several mappings are combined. At least one `--map` or `--tree` is required.

The output path must not already exist. This prevents an incorrect version or command from silently replacing a previously reviewed artifact. Generated packages under `Packaging/dist/` are ignored by Git.

## Branding-assets example

Assuming the reviewed banner exists at `BrandingAssets/SwiftDialog-Banner.png`:

```zsh
Packaging/build-file-package.zsh \
  --identifier com.example.jamf.branding-assets \
  --version 1.0.0 \
  --output Packaging/dist/JamfProScripts-BrandingAssets-1.0.0.pkg \
  --map BrandingAssets/SwiftDialog-Banner.png \
    "/Library/Application Support/JamfProScripts/BrandingAssets/SwiftDialog-Banner.png" \
    0644
```

Replace `com.example` with a reverse-DNS namespace controlled by the deploying organization. Keep the identifier stable and increment the version for every released payload.

To sign during the build, add:

```zsh
--sign "Developer ID Installer: Example Organization (TEAMID)"
```

## Multiple-file example

```zsh
Packaging/build-file-package.zsh \
  --identifier com.example.jam.shared-files \
  --version 2.1.0 \
  --output Packaging/dist/SharedFiles-2.1.0.pkg \
  --map ./assets/Dialog-Banner.png \
    "/Library/Application Support/Example/Branding/Dialog-Banner.png" 0644 \
  --map ./assets/defaults.json \
    "/Library/Application Support/Example/Configuration/defaults.json" 0644
```

## Nested-directory example

```zsh
Packaging/build-file-package.zsh \
  --identifier com.example.jam.shared-assets \
  --version 1.0.0 \
  --output Packaging/dist/SharedAssets-1.0.0.pkg \
  --tree ./assets \
    "/Library/Application Support/Example/Assets" \
    0644 0755
```

## Verification and deployment

Inspect an unsigned package without installing it:

```zsh
/usr/sbin/pkgutil --payload-files Packaging/dist/JamfProScripts-BrandingAssets-1.0.0.pkg
```

For a signed package:

```zsh
/usr/sbin/pkgutil --check-signature Packaging/dist/JamfProScripts-BrandingAssets-1.0.0.pkg
/usr/sbin/spctl -a -vv -t install Packaging/dist/JamfProScripts-BrandingAssets-1.0.0.pkg
```

Install only on an isolated test Mac before uploading the package to Jamf Pro. The Jamf policy must use an `Ongoing` custom trigger, have mutually exclusive scope if multiple policies share the trigger, and verify or rely on the caller to verify the exact installed postcondition.

## Tests

The integration suite builds and expands real unsigned packages entirely under `/private/tmp`; it does not install anything:

```zsh
zsh Packaging/tests/BuildFilePackageTests.zsh
```
