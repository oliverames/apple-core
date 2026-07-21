#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-Apple Core}"
APP_BUNDLE="${APP_BUNDLE:-${APP_NAME}.app}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-notarytool-profile}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-oliverames/apple-core}"
VERSION="${VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
SCHEME="${SCHEME:-Apple Core}"
CONFIGURATION="${CONFIGURATION:-Release}"
DESTINATION="${DESTINATION:-platform=macOS}"
PROJECT_FILE="${PROJECT_FILE:-${APP_NAME}.xcodeproj/project.pbxproj}"
DIST_DIR="${DIST_DIR:-dist}"
ARCHIVE_PATH="${ARCHIVE_PATH:-${DIST_DIR}/${APP_NAME}.xcarchive}"
EXPORT_DIR="${EXPORT_DIR:-${DIST_DIR}/export}"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-${DIST_DIR}/export-options.plist}"
TEAM_ID="${TEAM_ID:-}"
SIGNING_CERTIFICATE="${SIGNING_CERTIFICATE:-Developer ID Application}"
BUNDLE_ID="${BUNDLE_ID:-}"
PROVISIONING_PROFILE_NAME="${PROVISIONING_PROFILE_NAME:-}"
PROVISIONING_PROFILE_UUID="${PROVISIONING_PROFILE_UUID:-}"

# Derived artifact names for notarization/release steps.
NOTARY_ZIP="${DIST_DIR}/${APP_NAME}-notarize.zip"

# Swift package dependencies can embed their checkout path in diagnostic
# strings. Build release products under a neutral path so public binaries do
# not disclose the build user's username or home directory.
RELEASE_DERIVED_DATA_PATH="${RELEASE_DERIVED_DATA_PATH:-/private/tmp/apple-core-release-derived-data}"

print_usage() {
  cat <<'EOF'
Usage: Scripts/release.sh [command]

Commands:
  all         Prepare a signed local release: check, bump, archive, export, notarize/staple, package, appcast
  check       Quick release build check
  bump        Bump version/build numbers
  archive     Create an Xcode archive for direct distribution
  export      Export a Developer ID signed app from the archive
  profiles    List installed provisioning profiles
  package     Create the release zip from the app bundle
  notarize    Submit the app bundle for notarization
  staple      Staple the notarization ticket to the app bundle
  appcast     Sign the release zip (Sparkle EdDSA) and add an item to appcast.xml
  commit      Commit version bump and create release tag
  push-tags   Push the requested release tag to origin (asks for confirmation)
  release     Create a GitHub release (no assets)
  upload      Upload the release asset to GitHub
  help        Show this help

Environment:
  APP_NAME          App name (default: Apple Core)
  APP_BUNDLE        App bundle path (default: ${APP_NAME}.app)
  KEYCHAIN_PROFILE  Notarytool profile (default: notarytool-profile)
  GITHUB_REPOSITORY GitHub repository used for release publishing
  RELEASE_DERIVED_DATA_PATH Neutral DerivedData path used for public builds
  VERSION           Required for bumping, commit, release, and upload
  BUILD_NUMBER      Optional; used when bumping build number
  SCHEME            Xcode scheme for build check (default: Apple Core)
  CONFIGURATION     Build configuration for build check (default: Release)
  DESTINATION       Build destination for build check (default: platform=macOS)
  PROJECT_FILE      Xcode project file (default: ${APP_NAME}.xcodeproj/project.pbxproj)
  DIST_DIR          Output directory for artifacts (default: dist)
  ARCHIVE_PATH      Archive path (default: dist/${APP_NAME}.xcarchive)
  EXPORT_DIR        Export path for the signed app (default: dist/export)
  EXPORT_OPTIONS_PLIST Export options plist path (default: dist/export-options.plist)
  TEAM_ID           Team ID for Developer ID signing (optional)
  SIGNING_CERTIFICATE Signing certificate (default: Developer ID Application)
  BUNDLE_ID         Bundle identifier for export profiles (optional)
  PROVISIONING_PROFILE_NAME Provisioning profile name for export (optional)
  PROVISIONING_PROFILE_UUID Provisioning profile UUID for export (optional)
EOF
}

# If APP_BUNDLE isn't explicit, derive the built app path from Xcode settings.
resolve_app_bundle() {
  resolve_exported_app || true
  if [[ -d "${APP_BUNDLE}" ]]; then
    return 0
  fi

  local built_products_dir=""
  local full_product_name=""

  built_products_dir="$(xcodebuild -quiet -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -destination "${DESTINATION}" -showBuildSettings | awk -F ' = ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}')"
  full_product_name="$(xcodebuild -quiet -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -destination "${DESTINATION}" -showBuildSettings | awk -F ' = ' '/FULL_PRODUCT_NAME/ {print $2; exit}')"

  if [[ -n "${built_products_dir}" && -n "${full_product_name}" ]]; then
    local candidate="${built_products_dir}/${full_product_name}"
    if [[ -d "${candidate}" ]]; then
      APP_BUNDLE="${candidate}"
    fi
  fi
}

require_app_bundle() {
  resolve_app_bundle
  if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "Missing app bundle: ${APP_BUNDLE}" >&2
    exit 1
  fi
}

require_keychain_profile() {
  if [[ -z "${KEYCHAIN_PROFILE}" ]]; then
    echo "Missing keychain profile. Set KEYCHAIN_PROFILE." >&2
    exit 1
  fi
}

require_version() {
  if [[ -z "${VERSION}" ]]; then
    echo "VERSION is required for releases." >&2
    exit 1
  fi
  VERSION="${VERSION#v}"
  if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    echo "VERSION must be a semantic version such as 1.0.0 or 1.0.0-beta.1." >&2
    exit 1
  fi
}

require_clean_tree() {
  if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    echo "Working tree is dirty. Commit or stash changes first." >&2
    exit 1
  fi
}

release_tag() {
  require_version
  printf 'v%s' "${VERSION}"
}

ensure_dist_dir() {
  mkdir -p "${DIST_DIR}"
}

resolve_bundle_id() {
  if [[ -n "${BUNDLE_ID}" ]]; then
    return 0
  fi
  if [[ ! -f "${PROJECT_FILE}" ]]; then
    return 1
  fi
  local project_path="${PROJECT_FILE%/project.pbxproj}"
  BUNDLE_ID="$(
    xcodebuild -quiet -project "${project_path}" -target "${APP_NAME}" \
      -configuration "${CONFIGURATION}" -showBuildSettings \
      | awk -F ' = ' '/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = / {print $2; exit}'
  )"
  [[ -n "${BUNDLE_ID}" ]]
}

list_profiles() {
  local profiles_dir
  local found_dir="0"
  local profile tmp_plist name uuid team weatherkit app_id
  local profiles_dirs=(
    "${HOME}/Library/MobileDevice/Provisioning Profiles"
    "${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles"
  )
  resolve_bundle_id || true

  for profiles_dir in "${profiles_dirs[@]}"; do
    if [[ ! -d "${profiles_dir}" ]]; then
      continue
    fi
    found_dir="1"
    for profile in "${profiles_dir}"/*.mobileprovision "${profiles_dir}"/*.provisionprofile; do
      if [[ ! -f "${profile}" ]]; then
        continue
      fi
      tmp_plist="$(mktemp)"
      if ! security cms -D -i "${profile}" > "${tmp_plist}" 2>/dev/null; then
        rm -f "${tmp_plist}"
        continue
      fi
      name="$("/usr/libexec/PlistBuddy" -c "Print Name" "${tmp_plist}" 2>/dev/null || true)"
      uuid="$("/usr/libexec/PlistBuddy" -c "Print UUID" "${tmp_plist}" 2>/dev/null || true)"
      team="$("/usr/libexec/PlistBuddy" -c "Print TeamIdentifier:0" "${tmp_plist}" 2>/dev/null || true)"
      weatherkit="$("/usr/libexec/PlistBuddy" -c "Print Entitlements:com.apple.developer.weatherkit" "${tmp_plist}" 2>/dev/null || true)"
      app_id="$("/usr/libexec/PlistBuddy" -c "Print Entitlements:com.apple.application-identifier" "${tmp_plist}" 2>/dev/null || true)"
      rm -f "${tmp_plist}"
      if [[ -n "${BUNDLE_ID}" && -n "${app_id}" ]]; then
        if [[ "${app_id}" != *".${BUNDLE_ID}" && "${app_id}" != "${BUNDLE_ID}" ]]; then
          continue
        fi
      fi
      printf '%s\n' "Name: ${name}"
      printf '%s\n' "UUID: ${uuid}"
      printf '%s\n' "Team: ${team}"
      if [[ -n "${app_id}" ]]; then
        printf '%s\n' "App ID: ${app_id}"
      fi
      if [[ -n "${weatherkit}" ]]; then
        printf '%s\n' "WeatherKit: ${weatherkit}"
      fi
      printf '%s\n\n' "File: ${profile}"
    done
  done

  if [[ "${found_dir}" != "1" ]]; then
    echo "No provisioning profiles directory found at expected locations:" >&2
    echo "  ${profiles_dirs[0]}" >&2
    echo "  ${profiles_dirs[1]}" >&2
    exit 1
  fi
}

resolve_exported_app() {
  local candidate
  for candidate in "${EXPORT_DIR}"/*.app "${EXPORT_DIR}"/Applications/*.app "${EXPORT_DIR}"/Products/Applications/*.app; do
    if [[ -d "${candidate}" ]]; then
      APP_BUNDLE="${candidate}"
      return 0
    fi
  done
  return 1
}

release_zip() {
  require_version
  printf '%s/%s-%s.zip' "${DIST_DIR}" "${APP_NAME}" "${VERSION}"
}

cleanup() {
  rm -f "${NOTARY_ZIP}"
}

trap cleanup EXIT

bump_version() {
  require_version
  if [[ ! -f "${PROJECT_FILE}" ]]; then
    echo "Missing project file: ${PROJECT_FILE}" >&2
    exit 1
  fi
  local resolved_build_number="${BUILD_NUMBER}"
  if [[ -z "${resolved_build_number}" ]]; then
    # Find the current build number and increment it if not provided.
    resolved_build_number="0"
    while IFS= read -r line; do
      if [[ "${line}" =~ CURRENT_PROJECT_VERSION\ =\ ([0-9]+)\; ]]; then
        resolved_build_number="${BASH_REMATCH[1]}"
        break
      fi
    done < "${PROJECT_FILE}"
    resolved_build_number="$((resolved_build_number + 1))"
  fi

  echo "Setting MARKETING_VERSION to ${VERSION}"
  echo "Setting CURRENT_PROJECT_VERSION to ${resolved_build_number}"
  # Replace both version fields in the project file without agvtool.
  local tmp_file
  tmp_file="$(mktemp)"
  while IFS= read -r line; do
    if [[ "${line}" == *"MARKETING_VERSION ="* ]]; then
      printf '%s\n' "${line%%MARKETING_VERSION = *}MARKETING_VERSION = ${VERSION};" >> "${tmp_file}"
    elif [[ "${line}" == *"CURRENT_PROJECT_VERSION ="* ]]; then
      printf '%s\n' "${line%%CURRENT_PROJECT_VERSION = *}CURRENT_PROJECT_VERSION = ${resolved_build_number};" >> "${tmp_file}"
    else
      printf '%s\n' "${line}" >> "${tmp_file}"
    fi
  done < "${PROJECT_FILE}"
  mv "${tmp_file}" "${PROJECT_FILE}"
}

build_zip() {
  local source_bundle="$1"
  local output_zip="$2"
  ensure_dist_dir
  echo "Creating zip: ${output_zip}"
  ditto -c -k --keepParent "${source_bundle}" "${output_zip}"
}

build_check() {
  echo "Checking release build (scheme: ${SCHEME}, configuration: ${CONFIGURATION})"
  xcodebuild -quiet -scheme "${SCHEME}" -configuration "${CONFIGURATION}" \
    -destination "${DESTINATION}" -derivedDataPath "${RELEASE_DERIVED_DATA_PATH}" \
    CODE_SIGNING_ALLOWED=NO build
  resolve_app_bundle
}

archive_app() {
  ensure_dist_dir
  echo "Archiving app to ${ARCHIVE_PATH}"
  xcodebuild -quiet -scheme "${SCHEME}" -configuration "${CONFIGURATION}" \
    -destination "generic/platform=macOS" -derivedDataPath "${RELEASE_DERIVED_DATA_PATH}" \
    archive -archivePath "${ARCHIVE_PATH}"
}

write_export_options() {
  ensure_dist_dir
  local tmp_file
  tmp_file="$(mktemp)"
  cat > "${tmp_file}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>${SIGNING_CERTIFICATE}</string>
EOF
  local profile_value=""
  if [[ -n "${PROVISIONING_PROFILE_UUID}" ]]; then
    profile_value="${PROVISIONING_PROFILE_UUID}"
  elif [[ -n "${PROVISIONING_PROFILE_NAME}" ]]; then
    profile_value="${PROVISIONING_PROFILE_NAME}"
  fi
  if [[ -n "${profile_value}" ]]; then
    if ! resolve_bundle_id; then
      echo "BUNDLE_ID is required when using provisioning profiles." >&2
      exit 1
    fi
    cat >> "${tmp_file}" <<EOF
  <key>provisioningProfiles</key>
  <dict>
    <key>${BUNDLE_ID}</key>
    <string>${profile_value}</string>
  </dict>
EOF
  fi
  if [[ -n "${TEAM_ID}" ]]; then
    cat >> "${tmp_file}" <<EOF
  <key>teamID</key>
  <string>${TEAM_ID}</string>
EOF
  fi
  cat >> "${tmp_file}" <<'EOF'
</dict>
</plist>
EOF
  mv "${tmp_file}" "${EXPORT_OPTIONS_PLIST}"
}

export_app() {
  write_export_options
  echo "Exporting Developer ID app to ${EXPORT_DIR}"
  xcodebuild -quiet -exportArchive -archivePath "${ARCHIVE_PATH}" -exportPath "${EXPORT_DIR}" -exportOptionsPlist "${EXPORT_OPTIONS_PLIST}"
  resolve_app_bundle
}

notarize() {
  require_app_bundle
  require_keychain_profile
  ensure_dist_dir
  echo "Zipping for notarization: ${NOTARY_ZIP}"
  ditto -c -k --keepParent "${APP_BUNDLE}" "${NOTARY_ZIP}"
  echo "Submitting to notarization"
  xcrun notarytool submit "${NOTARY_ZIP}" --wait --keychain-profile="${KEYCHAIN_PROFILE}"
}

staple() {
  require_app_bundle
  echo "Stapling notarization ticket"
  xcrun stapler staple "${APP_BUNDLE}"
}

package_release() {
  require_app_bundle
  local release_zip_path
  release_zip_path="$(release_zip)"
  build_zip "${APP_BUNDLE}" "${release_zip_path}"
  shasum -a 256 "${release_zip_path}" > "${release_zip_path}.sha256"
  echo "Done: ${release_zip_path}"
}

validate_staple() {
  require_app_bundle
  echo "Validating stapled ticket"
  xcrun stapler validate "${APP_BUNDLE}"
}

validate_distribution_app() {
  require_app_bundle
  echo "Validating Developer ID signature"
  codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
  echo "Validating Gatekeeper acceptance"
  spctl --assess --type execute --verbose=2 "${APP_BUNDLE}"
  validate_staple
}

# Locate Sparkle's sign_update tool from the resolved SPM artifacts.
find_sign_update() {
  local candidate
  candidate="$(find "${HOME}/Library/Developer/Xcode/DerivedData" \
    -type f -name sign_update -path "*artifacts*Sparkle*" 2>/dev/null | head -1)"
  if [[ -z "${candidate}" ]]; then
    candidate="$(find "${HOME}/Library/Developer/Xcode/DerivedData" \
      -type f -name sign_update 2>/dev/null | head -1)"
  fi
  if [[ -z "${candidate}" ]]; then
    echo "sign_update not found. Build the app once so SPM fetches Sparkle's artifacts." >&2
    exit 1
  fi
  printf '%s' "${candidate}"
}

# Sign the release zip with the Sparkle EdDSA key (from the login keychain,
# where `generate_keys` stored it) and prepend a new item to appcast.xml.
# Publish afterward by copying appcast.xml to the gh-pages branch (see
# RELEASING.md); the app's SUFeedURL points at GitHub Pages.
update_appcast() {
  require_version
  require_app_bundle
  local release_zip_path sign_update signature notes_html pub_date length build_number
  release_zip_path="$(release_zip)"
  if [[ ! -f "${release_zip_path}" ]]; then
    echo "Missing release asset: ${release_zip_path}. Run package first." >&2
    exit 1
  fi
  sign_update="$(find_sign_update)"
  echo "Signing ${release_zip_path} with ${sign_update}"
  signature="$("${sign_update}" "${release_zip_path}" -p)"
  length="$(stat -f%z "${release_zip_path}")"
  notes_html="$(bash "$(dirname "${BASH_SOURCE[0]}")/render_release_notes.sh" "${VERSION}")"
  pub_date="$(LC_ALL=en_US.UTF-8 date -u '+%a, %d %b %Y %H:%M:%S +0000')"
  build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_BUNDLE}/Contents/Info.plist")"

  VERSION="${VERSION#v}" BUILD_NUMBER="${build_number}" SIGNATURE="${signature}" LENGTH="${length}" \
  NOTES_HTML="${notes_html}" PUB_DATE="${pub_date}" python3 - <<'PYEOF'
import os, re, sys
import xml.etree.ElementTree as ET

version = os.environ["VERSION"]
build_number = os.environ["BUILD_NUMBER"]
signature = os.environ["SIGNATURE"].strip()
length = os.environ["LENGTH"]
notes = os.environ["NOTES_HTML"]
pub_date = os.environ["PUB_DATE"]

url = (
    "https://github.com/oliverames/apple-core/releases/download/"
    f"v{version}/Apple.Core-{version}.zip"
)

item = f"""    <item>
      <title>Version {version}</title>
      <link>https://github.com/oliverames/apple-core/releases/tag/v{version}</link>
      <sparkle:version>{build_number}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <description><![CDATA[
{notes}
      ]]></description>
      <pubDate>{pub_date}</pubDate>
      <enclosure url="{url}"
                 length="{length}"
                 type="application/octet-stream"
                 sparkle:edSignature="{signature}" />
      <sparkle:minimumSystemVersion>15.1</sparkle:minimumSystemVersion>
    </item>
"""

with open("appcast.xml") as f:
    content = f.read()

if f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>" in content:
    print(f"appcast.xml already contains {version}; not adding a duplicate.", file=sys.stderr)
    sys.exit(1)

# Insert the new item immediately after <language>, so newest items lead.
marker = re.search(r"^(\s*<language>.*</language>\n)", content, re.MULTILINE)
if not marker:
    print("appcast.xml missing <language> marker; is the skeleton intact?", file=sys.stderr)
    sys.exit(1)
insert_at = marker.end()
content = content[:insert_at] + item + content[insert_at:]

try:
    ET.fromstring(content)
except ET.ParseError as error:
    print(f"generated appcast XML is invalid: {error}", file=sys.stderr)
    sys.exit(1)

with open("appcast.xml", "w") as f:
    f.write(content)
print(f"Added {version} to appcast.xml")
PYEOF

  echo "Next: publish appcast.xml to the gh-pages branch (see RELEASING.md)."
}

commit_and_tag() {
  require_version
  local release_zip_path tag
  release_zip_path="$(release_zip)"
  tag="$(release_tag)"
  if [[ ! -f "${release_zip_path}" ]]; then
    echo "Missing release asset: ${release_zip_path}" >&2
    exit 1
  fi
  validate_distribution_app
  if git rev-parse --verify "refs/tags/${tag}" >/dev/null 2>&1; then
    echo "Tag already exists: ${tag}" >&2
    exit 1
  fi
  if ! git diff --cached --quiet; then
    echo "The index already contains staged changes. Commit or unstage them before release preparation." >&2
    exit 1
  fi
  echo "Committing version bump"
  git add -- "${PROJECT_FILE}" appcast.xml
  if [[ -f "docs/release-notes/${tag}.md" ]]; then
    git add -- "docs/release-notes/${tag}.md"
  fi
  if git diff --cached --quiet; then
    echo "No changes to commit."
  else
    git commit -m "Release ${VERSION}"
  fi
  echo "Tagging release ${tag}"
  git tag -a "${tag}" -m "Release ${VERSION#v}"
}

push_tags() {
  require_version
  local tag
  tag="$(release_tag)"
  if ! git rev-parse --verify "refs/tags/${tag}" >/dev/null 2>&1; then
    echo "Missing tag: ${tag}" >&2
    exit 1
  fi
  local response=""
  read -r -p "Push tags to origin? [y/N] " response
  if [[ "${response}" != "y" && "${response}" != "Y" ]]; then
    echo "Tag push cancelled."
    exit 1
  fi
  git push origin "${tag}"
}

create_release() {
  require_version
  local tag
  tag="$(release_tag)"
  echo "Creating GitHub release ${tag}"
  gh release create "${tag}" --repo "${GITHUB_REPOSITORY}" --generate-notes
}

upload_asset() {
  require_version
  local release_zip_path tag
  release_zip_path="$(release_zip)"
  tag="$(release_tag)"
  if [[ ! -f "${release_zip_path}" ]]; then
    echo "Missing release asset: ${release_zip_path}" >&2
    exit 1
  fi
  echo "Uploading release asset ${release_zip_path}"
  gh release upload "${tag}" "${release_zip_path}" --repo "${GITHUB_REPOSITORY}" --clobber
  gh release view --web "${tag}" --repo "${GITHUB_REPOSITORY}"
}

all() {
  # Prepare verified local artifacts. Publishing remains a separate,
  # explicitly-invoked operation.
  require_clean_tree
  require_keychain_profile
  build_check
  bump_version
  archive_app
  export_app
  notarize
  staple
  validate_distribution_app
  package_release
  update_appcast
}

release() {
  create_release
}

upload() {
  upload_asset
}

COMMAND="${1:-help}"
case "${COMMAND}" in
  all)
    all
    ;;
  check)
    build_check
    ;;
  bump)
    bump_version
    ;;
  archive)
    archive_app
    ;;
  export)
    export_app
    ;;
  profiles)
    list_profiles
    ;;
  package)
    package_release
    ;;
  notarize)
    notarize
    ;;
  staple)
    staple
    ;;
  commit)
    commit_and_tag
    ;;
  push-tags)
    push_tags
    ;;
  appcast)
    update_appcast
    ;;
  release)
    release
    ;;
  upload)
    upload
    ;;
  help|-h|--help)
    print_usage
    ;;
  *)
    echo "Unknown command: ${COMMAND}" >&2
    print_usage >&2
    exit 1
    ;;
esac
