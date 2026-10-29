# Release, signing and TestFlight

## How a build is produced

`.github/workflows/ios.yml` runs on GitHub's `macos-26` runners (Xcode 26.x) for every push to `main` under `ios/`, and on demand (Actions › *iOS build, test & TestFlight* › Run workflow).

1. `xcodegen generate` creates `ios/TriviaClash.xcodeproj` from `ios/project.yml`. The project file isn't committed.
2. Unit tests run on the newest available iPhone simulator.
3. `scripts/write_asc_key.sh` writes the App Store Connect API key from `ASC_KEY_P8`. It accepts a full PEM, base64 of a PEM, or just the key body.
4. `scripts/asc.py` registers the bundle ID `com.surproductions.triviaclash` if it's missing and finds the App Store Connect app record. The build number is a UTC timestamp (`YYYYMMDDHHMM`), bumped past the latest uploaded build.
5. `xcodebuild archive` builds **unsigned**. The team is at its Apple Development certificate limit, so automatic development signing can't create a new certificate. No existing certificate is revoked.
6. `xcodebuild -exportArchive` with `method = app-store-connect`, `-allowProvisioningUpdates` and the API key signs the IPA with Apple's **cloud-managed distribution certificate** and an automatically created *iOS Team Store* provisioning profile.
7. The IPA is verified: bundle ID, version, presence of the encrypted question bundle, code signature and provisioning profile.
8. `xcrun altool --upload-app` sends it to TestFlight.
9. The IPA is attached to a GitHub **pre-release** tagged `v1.0.0-build.<number>` and saved as a workflow artifact.

## Repository secrets

| Secret | Value |
|---|---|
| `APPLE_TEAM_ID` | 10-character Team ID (Membership page in the developer portal) |
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | Issuer ID from App Store Connect › Users and Access › Integrations |
| `ASC_KEY_P8` | Contents of `AuthKey_<id>.p8` |

The API key needs the **Admin** role, or App Manager with access to cloud-managed distribution certificates, so Xcode can create signing assets.

## One-time App Store Connect setup

TestFlight uploads need an app record, which Apple's API can't create:

1. **App Store Connect › Apps › + › New App**
2. Platform iOS, name *Trivia Clasher* (or a variant if taken), primary language English
3. Bundle ID `com.surproductions.triviaclash` (CI has already registered it), SKU `triviaclash`

Then re-run the workflow. Uploaded builds appear under TestFlight after Apple's processing (usually 5–30 minutes). Internal testers can install immediately. External testers need a short Beta App Review.

## About the IPA

The exported IPA is signed for **App Store Connect distribution**:

- ✅ It's the exact binary uploaded to TestFlight and the App Store.
- ❌ It **can't be installed directly** on an iPhone (no sideloading, no Apple Configurator). Install it through **TestFlight**.

Installing outside TestFlight would need an Ad Hoc (release-testing) build with each device's UDID registered in the developer account.

## Versioning

- `MARKETING_VERSION` (1.0.0) lives in `ios/project.yml`.
- `CURRENT_PROJECT_VERSION` is overridden by CI with the timestamp build number.
