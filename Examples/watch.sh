#!/bin/sh
# Your agents at a glance: `agent-hooks tail --sessions` as one coloured
# line per event, and a bold one each time a session changes state
# (README.md). Needs jq (`brew install jq` if your macOS lacks it). Ctrl-C stops it.
#
#   Examples/watch.sh [path/to/agent-hooks]
set -eu
hooks=${1:-agent-hooks}

"$hooks" tail --sessions --name watch | jq --unbuffered -r '
  def clock: (.at / 1000 | strflocaltime("%H:%M:%S"));
  def who: (.session | split("/") | .[0]);
  if .state then
    ({working: "\u001b[1;34m● working",
      idle: "\u001b[1;37m○ idle",
      needs_you: "\u001b[1;33m▲ needs you (\(.asking // "?"))",
      gone: "\u001b[2m× gone"}[.state] // .state) as $s
    | "\(clock)  \(who | . + " " * (7 - length))\(.project)/\(.workspace // "-")  \($s)\u001b[0m"
  else
    "\u001b[2m\(clock)  \(.agent | . + " " * (7 - length))\(.hook) \(.topic // .tool // .outcome // "")\u001b[0m"
  end'
