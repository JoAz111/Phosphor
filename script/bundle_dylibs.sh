#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <mach-o-binary> <frameworks-directory>" >&2
  exit 2
fi

MAIN_BINARY="$1"
FRAMEWORKS_DIR="$2"

if [[ ! -f "$MAIN_BINARY" ]]; then
  echo "error: Mach-O binary is missing: $MAIN_BINARY" >&2
  exit 1
fi

/bin/mkdir -p "$FRAMEWORKS_DIR"

is_system_dependency() {
  [[ "$1" == /System/* || "$1" == /usr/lib/* ]]
}

dependencies() {
  /usr/bin/otool -L "$1" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}'
}

resolve_dependency() {
  local dependency="$1"
  local owner="$2"
  local basename
  basename="$(/usr/bin/basename "$dependency")"

  if [[ "$dependency" == /* && -f "$dependency" ]]; then
    echo "$dependency"
    return 0
  fi
  if [[ -f "$(/usr/bin/dirname "$owner")/$basename" ]]; then
    echo "$(/usr/bin/dirname "$owner")/$basename"
    return 0
  fi
  if [[ -f "/opt/homebrew/lib/$basename" ]]; then
    echo "/opt/homebrew/lib/$basename"
    return 0
  fi

  echo "error: unable to resolve dependency $dependency for $owner" >&2
  return 1
}

QUEUE_FILE="$(/usr/bin/mktemp -t phosphor-dylibs)"
SEEN_FILE="$(/usr/bin/mktemp -t phosphor-seen-dylibs)"
trap '/bin/rm -f "$QUEUE_FILE" "$SEEN_FILE"' EXIT

while IFS= read -r dependency; do
  if is_system_dependency "$dependency"; then
    continue
  fi
  source_path="$(resolve_dependency "$dependency" "$MAIN_BINARY")"
  basename="$(/usr/bin/basename "$source_path")"
  destination="$FRAMEWORKS_DIR/$basename"
  if [[ ! -f "$destination" ]]; then
    /bin/cp -L "$source_path" "$destination"
    /bin/chmod u+w "$destination"
    echo "$source_path|$destination" >>"$QUEUE_FILE"
    echo "$basename" >>"$SEEN_FILE"
  fi
  /usr/bin/install_name_tool -change "$dependency" "@rpath/$basename" "$MAIN_BINARY"
done < <(dependencies "$MAIN_BINARY")

line_number=1
while queue_entry="$(/usr/bin/sed -n "${line_number}p" "$QUEUE_FILE")"; [[ -n "$queue_entry" ]]; do
  line_number=$((line_number + 1))
  source_path="${queue_entry%%|*}"
  destination="${queue_entry#*|}"
  destination_name="$(/usr/bin/basename "$destination")"
  /usr/bin/install_name_tool -id "@rpath/$destination_name" "$destination"

  while IFS= read -r dependency; do
    if is_system_dependency "$dependency"; then
      continue
    fi
    dependency_name="$(/usr/bin/basename "$dependency")"
    if [[ "$dependency_name" == "$destination_name" ]]; then
      continue
    fi
    dependency_source="$(resolve_dependency "$dependency" "$source_path")"
    dependency_destination="$FRAMEWORKS_DIR/$dependency_name"
    if ! /usr/bin/grep -Fxq "$dependency_name" "$SEEN_FILE"; then
      /bin/cp -L "$dependency_source" "$dependency_destination"
      /bin/chmod u+w "$dependency_destination"
      echo "$dependency_source|$dependency_destination" >>"$QUEUE_FILE"
      echo "$dependency_name" >>"$SEEN_FILE"
    fi
    /usr/bin/install_name_tool \
      -change "$dependency" \
      "@loader_path/$dependency_name" \
      "$destination"
  done < <(dependencies "$source_path")
done
