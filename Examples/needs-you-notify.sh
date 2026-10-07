#!/bin/sh
# A macOS notification each time an agent session starts waiting on you,
# from `agent-hooks tail --sessions` (README.md). Run it in a terminal, or
# from a launch agent; Ctrl-C stops it.
#
#   Examples/needs-you-notify.sh [path/to/agent-hooks]
set -eu
hooks=${1:-agent-hooks}

# A string field of a JSON line, or nothing. Enough for the session lines,
# whose values are short names.
field() {
  printf '%s\n' "$2" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"
}

"$hooks" tail --sessions --name needs-you-notify | while IFS= read -r line; do
  # Only a session's line has a state; an event's text can't hold this
  # unescaped.
  case $line in
    *'"state":"needs_you"'*) ;;
    *) continue ;;
  esac
  project=$(field project "$line")
  name=$(field name "$line")
  what="wants permission"
  [ "$(field asking "$line")" = input ] && what="has a question"
  # The words go in as arguments, never into the script's text.
  osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' \
    "${name:-$project}" "An agent in $project $what" >/dev/null
done
