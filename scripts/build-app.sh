#!/bin/bash

set -euo pipefail

readonly APP_NAME="CopilotBridge"
readonly PRODUCT_NAME="CopilotBridge"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
readonly ROOT_DIR
readonly INFO_PLIST_SOURCE="${ROOT_DIR}/Resources/Info.plist"
readonly APP_ICON_SOURCE="${ROOT_DIR}/Resources/AppIcon.icns"
readonly PROJECT_LICENSE_SOURCE="${ROOT_DIR}/LICENSE"
readonly THIRD_PARTY_NOTICES_SOURCE="${ROOT_DIR}/THIRD_PARTY_NOTICES.md"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

usage() {
  cat <<'EOF'
Build an arm64 CopilotBridge.app from the SwiftPM executable product.

Usage:
  scripts/build-app.sh

Optional environment variables:
  OUTPUT_DIR          Destination directory (default: <repository>/dist)
  BUNDLE_ID           Bundle identifier (default: com.copilotbridge.app)
  MARKETING_VERSION   Short version string (default: Resources/Info.plist)
  BUILD_NUMBER        Bundle build number (default: 1)
  SIGNING_IDENTITY    Developer ID Application identity or SHA-1 hash.
                      Omit it, leave it empty, or use "-" for ad-hoc signing.
EOF
}

if [[ $# -ne 0 ]]; then
  usage >&2
  exit 64
fi

require_command swift
require_command lipo
require_command plutil
require_command codesign
require_command ditto
require_command file
require_command find
require_command install_name_tool
require_command otool
require_command security
require_command xattr
require_command xcode-select
require_command xcrun

[[ -f "${ROOT_DIR}/Package.swift" ]] || die "Package.swift was not found at ${ROOT_DIR}"
[[ -f "${INFO_PLIST_SOURCE}" ]] || die "Info.plist was not found at ${INFO_PLIST_SOURCE}"
[[ -f "${APP_ICON_SOURCE}" ]] || die "AppIcon.icns was not found at ${APP_ICON_SOURCE}"
[[ -f "${PROJECT_LICENSE_SOURCE}" ]] || die "LICENSE was not found at ${PROJECT_LICENSE_SOURCE}"
[[ -f "${THIRD_PARTY_NOTICES_SOURCE}" ]] || \
  die "THIRD_PARTY_NOTICES.md was not found at ${THIRD_PARTY_NOTICES_SOURCE}"

readonly BUNDLE_ID="${BUNDLE_ID:-com.copilotbridge.app}"
readonly MARKETING_VERSION="${MARKETING_VERSION:-$(plutil -extract CFBundleShortVersionString raw -o - "${INFO_PLIST_SOURCE}")}"
readonly BUILD_NUMBER="${BUILD_NUMBER:-1}"
readonly SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

[[ "${BUNDLE_ID}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$ ]] || \
  die "BUNDLE_ID must be a reverse-DNS identifier"
[[ "${MARKETING_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  die "MARKETING_VERSION must contain exactly three numeric components"
[[ "${BUILD_NUMBER}" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || \
  die "BUILD_NUMBER must contain one to three numeric components"

output_dir_input="${OUTPUT_DIR:-${ROOT_DIR}/dist}"
mkdir -p "${output_dir_input}"
OUTPUT_DIR_RESOLVED="$(cd "${output_dir_input}" && pwd -P)"
readonly OUTPUT_DIR_RESOLVED
[[ -n "${OUTPUT_DIR_RESOLVED}" && "${OUTPUT_DIR_RESOLVED}" != "/" ]] || \
  die "refusing unsafe OUTPUT_DIR: ${OUTPUT_DIR_RESOLVED:-<empty>}"

if [[ "${SIGNING_IDENTITY}" != "-" ]]; then
  identity_line="$(security find-identity -v -p codesigning 2>/dev/null | \
    grep -F -- "${SIGNING_IDENTITY}" | head -n 1 || true)"
  [[ -n "${identity_line}" ]] || die "SIGNING_IDENTITY does not match a valid code-signing identity"
  [[ "${identity_line}" == *"Developer ID Application:"* ]] || \
    die "SIGNING_IDENTITY must identify a Developer ID Application certificate"
fi

printf 'Building %s for arm64 (release)...\n' "${PRODUCT_NAME}"
swift build \
  --package-path "${ROOT_DIR}" \
  --configuration release \
  --arch arm64 \
  --product "${PRODUCT_NAME}"

BIN_DIR="$(swift build \
  --package-path "${ROOT_DIR}" \
  --configuration release \
  --arch arm64 \
  --show-bin-path)"
readonly BIN_DIR
readonly BUILT_EXECUTABLE="${BIN_DIR}/${PRODUCT_NAME}"

[[ -x "${BUILT_EXECUTABLE}" ]] || die "SwiftPM product is missing or not executable: ${BUILT_EXECUTABLE}"
BUILT_ARCHITECTURES="$(lipo -archs "${BUILT_EXECUTABLE}")"
readonly BUILT_ARCHITECTURES
[[ "${BUILT_ARCHITECTURES}" == "arm64" ]] || \
  die "expected an arm64-only executable, found: ${BUILT_ARCHITECTURES}"

for dependency in swift-nio swift-atomics swift-collections swift-system; do
  [[ -f "${ROOT_DIR}/.build/checkouts/${dependency}/LICENSE.txt" ]] || \
    die "dependency license is missing: ${dependency}/LICENSE.txt"
done
[[ -f "${ROOT_DIR}/.build/checkouts/swift-nio/NOTICE.txt" ]] || \
  die "dependency notice is missing: swift-nio/NOTICE.txt"

staging_root="$(mktemp -d -t copilotbridge-stage)"
case "${staging_root}" in
  */copilotbridge-stage.*) ;;
  *) die "mktemp returned an unexpected staging path" ;;
esac

previous_app=""
previous_archive=""
app_had_previous=false
archive_had_previous=false
app_install_started=false
archive_install_started=false
# Final outputs are a transaction: keep any old artifacts in staging until the
# replacement app has survived its post-copy signature check.
install_committed=false

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

restore_output() {
  local destination="$1"
  local backup="$2"
  local had_previous="$3"
  local install_started="$4"

  if [[ -n "${backup}" ]] && path_exists "${backup}"; then
    if path_exists "${destination}"; then
      rm -rf "${destination}" || return 1
    fi
    mv "${backup}" "${destination}" || return 1
  elif [[ "${had_previous}" == "false" && "${install_started}" == "true" ]] && \
    path_exists "${destination}"
  then
    rm -rf "${destination}" || return 1
  fi
}

cleanup() {
  local original_status=$?
  local rollback_failed=false
  trap - EXIT HUP INT TERM

  if [[ "${install_committed:-false}" != "true" ]]; then
    if [[ -n "${FINAL_APP:-}" ]] && ! restore_output \
      "${FINAL_APP}" "${previous_app:-}" "${app_had_previous:-false}" \
      "${app_install_started:-false}"
    then
      rollback_failed=true
      printf 'error: failed to restore the previous app at %s\n' "${FINAL_APP}" >&2
    fi
    if [[ -n "${FINAL_ARCHIVE:-}" ]] && ! restore_output \
      "${FINAL_ARCHIVE}" "${previous_archive:-}" "${archive_had_previous:-false}" \
      "${archive_install_started:-false}"
    then
      rollback_failed=true
      printf 'error: failed to restore the previous archive at %s\n' "${FINAL_ARCHIVE}" >&2
    fi
  fi

  if [[ "${rollback_failed}" == "true" ]]; then
    printf 'error: rollback data was preserved at %s\n' "${staging_root}" >&2
    if [[ "${original_status}" -eq 0 ]]; then
      original_status=1
    fi
  elif [[ -n "${staging_root:-}" && -d "${staging_root}" ]]; then
    rm -rf "${staging_root}" || true
  fi

  exit "${original_status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

readonly STAGED_APP="${staging_root}/${APP_NAME}.app"
readonly STAGED_EXECUTABLE="${STAGED_APP}/Contents/MacOS/${APP_NAME}"
readonly STAGED_LICENSES="${STAGED_APP}/Contents/Resources/Licenses"
mkdir -p "${STAGED_APP}/Contents/MacOS" "${STAGED_LICENSES}"
install -m 755 "${BUILT_EXECUTABLE}" "${STAGED_EXECUTABLE}"
install -m 644 "${INFO_PLIST_SOURCE}" "${STAGED_APP}/Contents/Info.plist"
install -m 644 "${APP_ICON_SOURCE}" "${STAGED_APP}/Contents/Resources/AppIcon.icns"
install -m 644 "${PROJECT_LICENSE_SOURCE}" "${STAGED_LICENSES}/CopilotBridge-LICENSE.txt"
install -m 644 "${THIRD_PARTY_NOTICES_SOURCE}" \
  "${STAGED_LICENSES}/THIRD_PARTY_NOTICES.md"
for dependency in swift-nio swift-atomics swift-collections swift-system; do
  install -m 644 "${ROOT_DIR}/.build/checkouts/${dependency}/LICENSE.txt" \
    "${STAGED_LICENSES}/${dependency}-LICENSE.txt"
done
install -m 644 "${ROOT_DIR}/.build/checkouts/swift-nio/NOTICE.txt" \
  "${STAGED_LICENSES}/swift-nio-NOTICE.txt"

# Preserve dependency resource bundles inside the standard sealed app layout.
for resource_bundle in "${BIN_DIR}"/*.bundle; do
  [[ -d "${resource_bundle}" ]] || continue
  cp -R "${resource_bundle}" "${STAGED_APP}/Contents/Resources/"
done

# SwiftPM executables built with a newer SDK may weak-link compatibility
# libraries which exist only in the active Xcode toolchain. Embed exactly the
# libraries selected by Apple's deployment scanner so the app also works on a
# macOS 14/15 machine without Xcode.
readonly STAGED_FRAMEWORKS="${STAGED_APP}/Contents/Frameworks"
mkdir -p "${STAGED_FRAMEWORKS}"
xcrun swift-stdlib-tool \
  --copy \
  --scan-executable "${STAGED_EXECUTABLE}" \
  --platform macosx \
  --destination "${STAGED_FRAMEWORKS}"

unexpected_runtime_file="$(find "${STAGED_FRAMEWORKS}" -type f ! -name '*.dylib' -print -quit)"
[[ -z "${unexpected_runtime_file}" ]] || \
  die "Swift runtime scanner produced an unexpected file: ${unexpected_runtime_file}"
unexpected_runtime_link="$(find "${STAGED_FRAMEWORKS}" -type l -print -quit)"
[[ -z "${unexpected_runtime_link}" ]] || \
  die "Swift runtime scanner produced an unexpected symbolic link: ${unexpected_runtime_link}"

embedded_runtime_count=0
readonly RUNTIME_MANIFEST="${staging_root}/embedded-swift-runtimes.list"
if ! find "${STAGED_FRAMEWORKS}" -type f -name '*.dylib' -print0 > "${RUNTIME_MANIFEST}"; then
  die "failed to enumerate embedded Swift runtimes"
fi
while IFS= read -r -d '' runtime_library; do
  file -b "${runtime_library}" | grep -q 'Mach-O' || \
    die "embedded Swift runtime is not Mach-O: ${runtime_library}"
  runtime_architectures="$(lipo -archs "${runtime_library}")"
  case " ${runtime_architectures} " in
    *" arm64 "*) ;;
    *) die "embedded Swift runtime has no arm64 slice: ${runtime_library}" ;;
  esac
  if [[ "${runtime_architectures}" != "arm64" ]]; then
    thinned_runtime="${runtime_library}.arm64-thinned"
    lipo "${runtime_library}" -thin arm64 -output "${thinned_runtime}"
    mv "${thinned_runtime}" "${runtime_library}"
  fi
  chmod 755 "${runtime_library}"
  embedded_runtime_count=$((embedded_runtime_count + 1))
done < "${RUNTIME_MANIFEST}"

readonly OTOOL_LOAD_COMMANDS="${staging_root}/executable-load-commands.txt"
readonly RPATH_MANIFEST="${staging_root}/executable-rpaths.list"
write_rpaths() {
  if ! otool -l "${STAGED_EXECUTABLE}" > "${OTOOL_LOAD_COMMANDS}"; then
    die "failed to inspect executable load commands"
  fi
  if ! awk '
    $1 == "cmd" {
      is_rpath = ($2 == "LC_RPATH")
      next
    }
    is_rpath && $1 == "path" {
      line = $0
      sub(/^[[:space:]]*path /, "", line)
      sub(/ \(offset [0-9]+\)$/, "", line)
      print line
      is_rpath = 0
    }
  ' "${OTOOL_LOAD_COMMANDS}" > "${RPATH_MANIFEST}"; then
    die "failed to parse executable rpaths"
  fi
}

write_rpaths
if [[ "${embedded_runtime_count}" -gt 0 ]]; then
  readonly APP_FRAMEWORK_RPATH='@executable_path/../Frameworks'
  if ! grep -Fqx -- "${APP_FRAMEWORK_RPATH}" "${RPATH_MANIFEST}"; then
    install_name_tool -add_rpath "${APP_FRAMEWORK_RPATH}" "${STAGED_EXECUTABLE}"
  fi
fi

# A SwiftPM link can leave the selected Xcode toolchain as an absolute
# fallback. It is neither portable nor needed once compatibility dylibs are
# embedded. Preserve system rpaths so newer macOS runtimes remain first.
DEVELOPER_DIR="$(xcode-select -p)"
readonly DEVELOPER_DIR
write_rpaths
while IFS= read -r runtime_rpath; do
  case "${runtime_rpath}" in
    "${DEVELOPER_DIR}"/*)
      install_name_tool -delete_rpath "${runtime_rpath}" "${STAGED_EXECUTABLE}"
      ;;
  esac
done < "${RPATH_MANIFEST}"

write_rpaths
if ! remaining_developer_rpath="$(awk '
  /\/Contents\/Developer\/Toolchains\// {
    print
    exit
  }
' "${RPATH_MANIFEST}")"; then
  die "failed to validate executable rpaths"
fi
[[ -z "${remaining_developer_rpath}" ]] || \
  die "executable retains a developer-toolchain rpath: ${remaining_developer_rpath}"

readonly OTOOL_DEPENDENCIES="${staging_root}/executable-dependencies.txt"
readonly DEPENDENCY_MANIFEST="${staging_root}/executable-dependencies.list"
if ! otool -L "${STAGED_EXECUTABLE}" > "${OTOOL_DEPENDENCIES}"; then
  die "failed to inspect executable dependencies"
fi
if ! awk '
  NR > 1 {
    line = $0
    sub(/^[[:space:]]*/, "", line)
    sub(/[[:space:]]+\(compatibility version .*$/, "", line)
    if (length(line) > 0) print line
  }
' "${OTOOL_DEPENDENCIES}" > "${DEPENDENCY_MANIFEST}"; then
  die "failed to parse executable dependencies"
fi
while IFS= read -r runtime_dependency; do
  case "${runtime_dependency}" in
    @rpath/*)
      runtime_name="${runtime_dependency#@rpath/}"
      [[ -n "${runtime_name}" && "${runtime_name}" != */* ]] || \
        die "unsupported runtime dependency path: ${runtime_dependency}"
      [[ -f "${STAGED_FRAMEWORKS}/${runtime_name}" ]] || \
        die "runtime dependency was not embedded: ${runtime_dependency}"
      ;;
  esac
done < "${DEPENDENCY_MANIFEST}"

if [[ "${embedded_runtime_count}" -eq 0 ]]; then
  rmdir "${STAGED_FRAMEWORKS}"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "${STAGED_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${MARKETING_VERSION}" "${STAGED_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${STAGED_APP}/Contents/Info.plist"
plutil -lint "${STAGED_APP}/Contents/Info.plist" >/dev/null
xattr -cr "${STAGED_APP}"

sign_code() {
  local path="$1"
  if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
    codesign \
      --sign - \
      --force \
      --options runtime \
      --timestamp=none \
      "${path}"
  else
    codesign \
      --sign "${SIGNING_IDENTITY}" \
      --force \
      --options runtime \
      --timestamp \
      "${path}"
  fi
}

if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
  printf 'Signing ad hoc...\n'
else
  printf 'Signing with Developer ID Application identity...\n'
fi
while IFS= read -r -d '' runtime_library; do
  sign_code "${runtime_library}"
done < "${RUNTIME_MANIFEST}"
sign_code "${STAGED_APP}"

codesign --verify --deep --strict --verbose=2 "${STAGED_APP}"

readonly STAGED_ARCHIVE="${staging_root}/${APP_NAME}-arm64.zip"
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
  "${STAGED_APP}" "${STAGED_ARCHIVE}"
[[ -s "${STAGED_ARCHIVE}" ]] || die "failed to create the arm64 app archive"

readonly ARCHIVE_VALIDATION_DIR="${staging_root}/archive-validation"
mkdir -p "${ARCHIVE_VALIDATION_DIR}"
ditto -x -k --norsrc --noextattr --noqtn --noacl \
  "${STAGED_ARCHIVE}" "${ARCHIVE_VALIDATION_DIR}"
codesign --verify --deep --strict --verbose=2 \
  "${ARCHIVE_VALIDATION_DIR}/${APP_NAME}.app"
rm -rf "${ARCHIVE_VALIDATION_DIR}"

readonly FINAL_APP="${OUTPUT_DIR_RESOLVED}/${APP_NAME}.app"
readonly FINAL_ARCHIVE="${OUTPUT_DIR_RESOLVED}/${APP_NAME}-arm64.zip"
[[ "$(basename "${FINAL_APP}")" == "${APP_NAME}.app" ]] || die "unexpected destination app name"
[[ "$(basename "${FINAL_ARCHIVE}")" == "${APP_NAME}-arm64.zip" ]] || \
  die "unexpected destination archive name"
if path_exists "${FINAL_APP}"; then
  app_had_previous=true
  previous_app="${staging_root}/previous-${APP_NAME}.app"
  mv "${FINAL_APP}" "${previous_app}" || die "failed to preserve the previous app"
fi
if path_exists "${FINAL_ARCHIVE}"; then
  archive_had_previous=true
  previous_archive="${staging_root}/previous-${APP_NAME}-arm64.zip"
  mv "${FINAL_ARCHIVE}" "${previous_archive}" || \
    die "failed to preserve the previous archive"
fi
app_install_started=true
mv "${STAGED_APP}" "${FINAL_APP}" || die "failed to install the newly built app"
archive_install_started=true
mv "${STAGED_ARCHIVE}" "${FINAL_ARCHIVE}" || \
  die "failed to install the newly built archive"

# File Provider-backed folders can immediately reattach forbidden FinderInfo.
# The archive above is created and verified in neutral temporary storage, so it
# remains the portable output even when the convenience app copy is affected.
app_copy_valid=true
if ! xattr -cr "${FINAL_APP}" || \
  ! codesign --verify --deep --strict --verbose=2 "${FINAL_APP}"
then
  app_copy_valid=false
else
  sleep 2
fi
if [[ "${app_copy_valid}" == "true" ]] && \
  ! codesign --verify --deep --strict --verbose=2 "${FINAL_APP}"
then
  app_copy_valid=false
fi
if [[ "${app_copy_valid}" == "false" ]]; then
  rm -rf "${FINAL_APP}"
  if [[ -n "${previous_app}" ]] && path_exists "${previous_app}"; then
    mv "${previous_app}" "${FINAL_APP}" || die "failed to restore the previous app"
  fi
  printf 'warning: output storage attached forbidden metadata; use %s or choose an OUTPUT_DIR outside synced storage.\n' \
    "${FINAL_ARCHIVE}" >&2
fi

install_committed=true
if [[ "${app_copy_valid}" == "true" ]]; then
  printf 'Built app: %s\n' "${FINAL_APP}"
fi
printf 'Built archive: %s\n' "${FINAL_ARCHIVE}"
printf 'Architecture: %s\n' "${BUILT_ARCHITECTURES}"
printf 'Signature: %s\n' "$([[ "${SIGNING_IDENTITY}" == "-" ]] && printf 'ad hoc' || printf 'Developer ID')"
