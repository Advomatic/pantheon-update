#!/bin/bash
# pantheon-update.sh
# Bash script to run security updates on a Pantheon site.

##
# If there was an error, ask to remove the multi-dev. Then exit.
#
# @param string $message
# @param int $return_code
##
cleanup_on_error() {
  >&2 echo -e ""
  >&2 echo -e "${INVERSE}ERROR:"
  >&2 echo -e "$1${NOINVERSE}"
  >&2 echo -e ""
  exit "$2";
}

# Used for questions and warnings.
UNDERLINE=$'\033[4m'
NOUNDERLINE=$'\033[24m'
# Used for options.
BOLD=$'\033[1m\033[36m'
NOBOLD=$'\033[39m\033[22m'
# Used for errors.
INVERSE=$'\033[7m'
NOINVERSE=$'\033[27m'
# Used for pro tips
TIP=$'\033[33m'
NOTIP=$'\033[39m'

cleanup_on_error 'This repository has been retired and merged into https://github.com/Advomatic/pantheon-tools Please use that new version instead.' 99
