#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
readonly SCRIPT_DIR ROOT_DIR

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 1 || "$1" == "--help" ]]; then
  printf '%s\n' \
    'Usage: scripts/build-dmg.sh /path/to/CopilotBridge.app' \
    'Package an existing signed arm64 app; does not build, re-sign or install it.' \
    'DMGBUILD: dmgbuild executable (default: dmgbuild)' \
    'OUTPUT_DIR: destination directory (default: <repository>/dist)' \
    'Existing DMG/checksum files are never overwritten.'
  [[ $# -eq 1 && "$1" == "--help" ]] && exit 0
  exit 64
fi

for command_name in hdiutil codesign lipo plutil ditto shasum diff; do
  command -v "${command_name}" >/dev/null || die "required command not found: ${command_name}"
done
DMGBUILD="${DMGBUILD:-dmgbuild}"
command -v "${DMGBUILD}" >/dev/null || \
  die "install scripts/dmg-requirements.txt in a Python venv and set DMGBUILD to its bin/dmgbuild"
[[ -d "$1" ]] || die "application not found: $1"
APPLICATION="$(cd "$1" && pwd -P)"
[[ "${APPLICATION##*/}" == "CopilotBridge.app" ]] || die "expected CopilotBridge.app"
readonly APPLICATION
readonly EXECUTABLE_RELATIVE="Contents/MacOS/CopilotBridge"

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "${APPLICATION}/Contents/Info.plist")"
EXPECTED_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "${ROOT_DIR}/Resources/Info.plist")"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid application version"
[[ "${VERSION}" == "${EXPECTED_VERSION}" ]] || \
  die "app is ${VERSION}, but this release expects ${EXPECTED_VERSION}; use the current signed app"
[[ "$(plutil -extract CFBundleExecutable raw -o - "${APPLICATION}/Contents/Info.plist")" == "CopilotBridge" ]] || \
  die "unexpected application executable"
[[ "$(lipo -archs "${APPLICATION}/${EXECUTABLE_RELATIVE}")" == "arm64" ]] || die "expected arm64-only app"
codesign --verify --deep --strict "${APPLICATION}"

mkdir -p "${OUTPUT_DIR:-${ROOT_DIR}/dist}"
OUTPUT_DIR_RESOLVED="$(cd "${OUTPUT_DIR:-${ROOT_DIR}/dist}" && pwd -P)"
readonly OUTPUT_DIR_RESOLVED
readonly FILENAME="CopilotBridge-${VERSION}-arm64.dmg"
readonly FINAL_DMG="${OUTPUT_DIR_RESOLVED}/${FILENAME}"
[[ ! -e "${FINAL_DMG}" && ! -L "${FINAL_DMG}" && ! -e "${FINAL_DMG}.sha256" && ! -L "${FINAL_DMG}.sha256" ]] || \
  die "output already exists; select a different OUTPUT_DIR to preserve the previous release"

# Keep app copies outside File Provider/iCloud directories, which can add
# FinderInfo metadata that invalidates strict signature verification.
staging_root="$(mktemp -d /tmp/copilotbridge-dmg.XXXXXX)"
case "${staging_root}" in
  /tmp/copilotbridge-dmg.??????) ;;
  *) die "unexpected staging path: ${staging_root}" ;;
esac
mounted=false
completed=false

cleanup() {
  local original_status=$?
  trap - EXIT HUP INT TERM
  if [[ "${mounted}" == true ]]; then
    if hdiutil detach "${staging_root}/mounted"; then
      mounted=false
    else
      printf 'warning: test volume remains mounted at %s/mounted\n' "${staging_root}" >&2
      original_status=1
    fi
  fi
  if [[ "${completed}" == true && "${mounted}" == false ]]; then
    rm -rf "${staging_root}"
  else
    printf 'Build diagnostics preserved at %s\n' "${staging_root}" >&2
  fi
  exit "${original_status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Packaging CopilotBridge %s (arm64)...\n' "${VERSION}"
"${DMGBUILD}" -s "${SCRIPT_DIR}/dmg-settings.py" \
  -D "app=${APPLICATION}" -D "resources=${ROOT_DIR}/Resources" \
  "CopilotBridge ${VERSION}" "${staging_root}/${FILENAME}"

printf 'Verifying disk image and drag-install copy...\n'
hdiutil verify "${staging_root}/${FILENAME}"
mkdir "${staging_root}/mounted" "${staging_root}/install-test"
hdiutil attach -readonly -nobrowse -noautoopen \
  -mountpoint "${staging_root}/mounted" "${staging_root}/${FILENAME}"
mounted=true
[[ -L "${staging_root}/mounted/Applications" ]] || die "Applications shortcut missing"
[[ "$(readlink "${staging_root}/mounted/Applications")" == "/Applications" ]] || die "incorrect Applications shortcut"
[[ -f "${staging_root}/mounted/.DS_Store" ]] || die "Finder layout missing"
[[ -f "${staging_root}/mounted/.background.tiff" ]] || die "arrow background missing"
[[ -f "${staging_root}/mounted/.Installer-LICENSE.txt" ]] || die "installer license missing"
codesign --verify --deep --strict "${staging_root}/mounted/CopilotBridge.app"
ditto "${staging_root}/mounted/CopilotBridge.app" "${staging_root}/install-test/CopilotBridge.app"
codesign --verify --deep --strict "${staging_root}/install-test/CopilotBridge.app"
diff -qr "${APPLICATION}" "${staging_root}/install-test/CopilotBridge.app"
hdiutil detach "${staging_root}/mounted"
mounted=false

(
  cd "${staging_root}"
  shasum -a 256 "${FILENAME}" > "${FILENAME}.sha256"
)
mv "${staging_root}/${FILENAME}" "${FINAL_DMG}"
mv "${staging_root}/${FILENAME}.sha256" "${FINAL_DMG}.sha256"
(
  cd "${OUTPUT_DIR_RESOLVED}"
  shasum -a 256 -c "${FILENAME}.sha256"
)
completed=true
printf 'Created: %s\nChecksum: %s.sha256\n' "${FINAL_DMG}" "${FINAL_DMG}"
