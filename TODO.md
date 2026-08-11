# Repository TODO

## Standardize branding assets across scripts

- [ ] Replace the legacy `install_SymFiles` custom-event name with `install_BrandingAssets` in the remaining scripts and their Jamf Pro policies.
- [ ] Give every script an independently configurable local branding-assets directory, using the `BrandingAssetsDirectory` key from the managed defaults plist and the neutral `/Library/Application Support/JamfProScripts/BrandingAssets` default.
- [ ] Replace organization-specific default asset names with documented neutral names such as `SwiftDialog-Banner.png`, while retaining explicit managed overrides for existing deployments.
- [ ] Resolve relative asset filenames against that directory before attempting installation, and use the resolved path for the current execution after installation.
- [ ] Validate local asset configuration consistently and fail closed when a required Jamf event fails or its expected asset postcondition is not met.
- [ ] Consolidate the repeated branding configuration and dependency checks into an audited shared implementation where repository deployment conventions permit it.
- [ ] Document each script's required assets and privileged Jamf custom events, including migration steps and expected postconditions.

AppDelete version 3.2 is the reference implementation. Keep the legacy event and existing asset paths available during a staged migration for scripts that have not yet moved to the new contract.
