#!/bin/bash

set -euo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

usage() {
  cat <<'EOF'
Submit a Developer ID-signed CopilotBridge.app for Apple notarization, staple it,
and create a verified distributable arm64 zip beside the app.

Usage:
  NOTARY_KEYCHAIN_PROFILE=<profile> scripts/notarize.sh /path/to/CopilotBridge.app

Create the profile once outside the repository (credentials remain in Keychain):
  xcrun notarytool store-credentials <profile>

The input app is validated before upload. A successful run attaches Apple's
notarization ticket and writes <app-name>-arm64.zip beside the app.
EOF
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 64
fi

require_command codesign
require_command ditto
require_command file
require_command find
require_command grep
require_command lipo
require_command plutil
require_command spctl
require_command xcrun

readonly NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
[[ -n "${NOTARY_KEYCHAIN_PROFILE}" ]] || die "NOTARY_KEYCHAIN_PROFILE is required"
[[ "${NOTARY_KEYCHAIN_PROFILE}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || \
  die "NOTARY_KEYCHAIN_PROFILE contains unsupported characters"

raw_app_path="$1"
[[ "${raw_app_path}" != *$'\n'* && "${raw_app_path}" != *$'\r'* ]] || \
  die "app path must not contain newline characters"
while [[ "${raw_app_path}" == */ && "${raw_app_path}" != "/" ]]; do
  raw_app_path="${raw_app_path%/}"
done
[[ -d "${raw_app_path}" ]] || die "app bundle was not found: ${raw_app_path}"
[[ ! -L "${raw_app_path}" ]] || die "refusing to notarize an app path that is a symbolic link"

APP_PARENT="$(cd "$(dirname "${raw_app_path}")" && pwd -P)"
readonly APP_PARENT
APP_BASENAME="$(basename "${raw_app_path}")"
readonly APP_BASENAME
[[ "${APP_BASENAME}" == *.app ]] || die "input must be a .app bundle"
readonly APP_PATH="${APP_PARENT}/${APP_BASENAME}"
readonly INFO_PLIST="${APP_PATH}/Contents/Info.plist"

[[ -f "${INFO_PLIST}" ]] || die "app bundle has no Contents/Info.plist"
plutil -lint "${INFO_PLIST}" >/dev/null

EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${INFO_PLIST}" 2>/dev/null || true)"
readonly EXECUTABLE_NAME
[[ "${EXECUTABLE_NAME}" =~ ^[A-Za-z0-9._-]+$ ]] || die "CFBundleExecutable is missing or unsafe"
readonly EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/${EXECUTABLE_NAME}"
[[ -x "${EXECUTABLE_PATH}" ]] || die "bundle executable is missing or not executable"
EXECUTABLE_ARCHITECTURES="$(lipo -archs "${EXECUTABLE_PATH}")"
readonly EXECUTABLE_ARCHITECTURES
[[ "${EXECUTABLE_ARCHITECTURES}" == "arm64" ]] || \
  die "expected an arm64-only executable, found: ${EXECUTABLE_ARCHITECTURES}"

codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
SIGNATURE_DETAILS="$(codesign --display --verbose=4 "${APP_PATH}" 2>&1)"
readonly SIGNATURE_DETAILS
[[ "${SIGNATURE_DETAILS}" == *"Authority=Developer ID Application:"* ]] || \
  die "app must be signed with a Developer ID Application certificate, not ad hoc"
[[ "${SIGNATURE_DETAILS}" == *"flags=0x10000(runtime)"* ]] || \
  die "app signature must enable the hardened runtime"
[[ "${SIGNATURE_DETAILS}" == *"Timestamp="* ]] || \
  die "app signature must include a secure timestamp"

SIGNED_ENTITLEMENTS="$(codesign --display --entitlements :- "${APP_PATH}" 2>/dev/null || true)"
GET_TASK_ALLOW="$(printf '%s' "${SIGNED_ENTITLEMENTS}" | \
  plutil -extract com.apple.security.get-task-allow raw -o - - 2>/dev/null || true)"
if [[ "${GET_TASK_ALLOW}" == "true" ]]; then
  die "release app must not enable get-task-allow"
fi

mach_o_count=0
while IFS= read -r -d '' candidate; do
  if ! file -b "${candidate}" | grep -q 'Mach-O'; then
    continue
  fi
  mach_o_count=$((mach_o_count + 1))
  candidate_architectures="$(lipo -archs "${candidate}")"
  [[ "${candidate_architectures}" == "arm64" ]] || \
    die "nested Mach-O is not arm64-only: ${candidate} (${candidate_architectures})"
  codesign --verify --strict --verbose=2 "${candidate}"
  candidate_details="$(codesign --display --verbose=4 "${candidate}" 2>&1)"
  [[ "${candidate_details}" == *"Authority=Developer ID Application:"* ]] || \
    die "nested Mach-O is not Developer ID signed: ${candidate}"
  [[ "${candidate_details}" == *"flags=0x10000(runtime)"* ]] || \
    die "nested Mach-O lacks hardened runtime: ${candidate}"
  [[ "${candidate_details}" == *"Timestamp="* ]] || \
    die "nested Mach-O lacks secure timestamp: ${candidate}"
  candidate_entitlements="$(codesign --display --entitlements :- "${candidate}" 2>/dev/null || true)"
  candidate_get_task_allow="$(printf '%s' "${candidate_entitlements}" | \
    plutil -extract com.apple.security.get-task-allow raw -o - - 2>/dev/null || true)"
  [[ "${candidate_get_task_allow}" != "true" ]] || \
    die "nested Mach-O enables get-task-allow: ${candidate}"
done < <(find "${APP_PATH}/Contents" -type f -print0)
[[ "${mach_o_count}" -gt 0 ]] || die "app bundle contains no Mach-O executable"

temp_dir="$(mktemp -d /tmp/copilotbridge-notary.XXXXXX)"
case "${temp_dir}" in
  /tmp/copilotbridge-notary.*) ;;
  *) die "mktemp returned an unexpected temporary path" ;;
esac
pending_archive=""

cleanup() {
  if [[ -n "${pending_archive:-}" && -f "${pending_archive}" ]]; then
    rm -f "${pending_archive}"
  fi
  if [[ -n "${temp_dir:-}" && -d "${temp_dir}" ]]; then
    rm -rf "${temp_dir}"
  fi
}
trap cleanup EXIT

readonly ZIP_PATH="${temp_dir}/${APP_BASENAME%.app}.zip"
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "${APP_PATH}" "${ZIP_PATH}"
[[ -s "${ZIP_PATH}" ]] || die "failed to create notarization archive"

printf 'Submitting %s for notarization...\n' "${APP_BASENAME}"
submission_result=""
if ! submission_result="$(xcrun notarytool submit "${ZIP_PATH}" \
  --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" \
  --wait \
  --timeout 30m \
  --output-format json \
  --no-progress)"; then
  submission_id="$(printf '%s' "${submission_result}" | plutil -extract id raw -o - - 2>/dev/null || true)"
  if [[ -n "${submission_id}" ]]; then
    xcrun notarytool log "${submission_id}" \
      --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" || true
  fi
  die "notarization submission failed or timed out"
fi
submission_status="$(printf '%s' "${submission_result}" | plutil -extract status raw -o - - 2>/dev/null || true)"
submission_id="$(printf '%s' "${submission_result}" | plutil -extract id raw -o - - 2>/dev/null || true)"
if [[ "${submission_status}" != "Accepted" ]]; then
  if [[ -n "${submission_id}" ]]; then
    xcrun notarytool log "${submission_id}" \
      --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" || true
  fi
  die "notarization was not accepted (status: ${submission_status:-unknown})"
fi
printf 'Notarization accepted: %s\n' "${submission_id}"

printf 'Stapling notarization ticket...\n'
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"
spctl --assess --type execute --verbose=2 "${APP_PATH}"

readonly STAPLED_ARCHIVE="${temp_dir}/${APP_BASENAME%.app}-arm64.zip"
readonly ARCHIVE_VALIDATION_DIR="${temp_dir}/archive-validation"
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
  "${APP_PATH}" "${STAPLED_ARCHIVE}"
mkdir -p "${ARCHIVE_VALIDATION_DIR}"
ditto -x -k --norsrc --noextattr --noqtn --noacl \
  "${STAPLED_ARCHIVE}" "${ARCHIVE_VALIDATION_DIR}"
codesign --verify --deep --strict --verbose=2 \
  "${ARCHIVE_VALIDATION_DIR}/${APP_BASENAME}"
xcrun stapler validate "${ARCHIVE_VALIDATION_DIR}/${APP_BASENAME}"

readonly FINAL_ARCHIVE="${APP_PARENT}/${APP_BASENAME%.app}-arm64.zip"
pending_archive="$(mktemp "${APP_PARENT}/.${APP_BASENAME%.app}-arm64.zip.XXXXXX")"
install -m 644 "${STAPLED_ARCHIVE}" "${pending_archive}"
mv -f "${pending_archive}" "${FINAL_ARCHIVE}"
pending_archive=""

printf 'Notarized and stapled app: %s\n' "${APP_PATH}"
printf 'Notarized archive: %s\n' "${FINAL_ARCHIVE}"
