#!/usr/bin/env bash
# Lists the login keychain's generic passwords under one service, one line
# each: account, creation and modification time. Read from the items'
# attributes alone, which the keychain does not guard, so listing never
# asks a person for anything.
#
#   scripts/login-keychain.sh SERVICE > before
#   ...
#   scripts/login-keychain.sh SERVICE | diff before -
set -euo pipefail

service="${1:?usage: login-keychain.sh SERVICE}"
security dump-keychain "${HOME}/Library/Keychains/login.keychain-db" |
  awk -v service="\"${service}\"" '
    function flush() {
      if (class == "\"genp\"" && svce == service) print acct "\t" cdat "\t" mdat
      class = ""; svce = ""; acct = ""; cdat = ""; mdat = ""
    }
    /^keychain: / { flush() }
    /^class: / { class = $2 }
    /^ *"svce"<blob>=/ { sub(/^ *"svce"<blob>=/, ""); svce = $0 }
    /^ *"acct"<blob>=/ { sub(/^ *"acct"<blob>=/, ""); acct = $0 }
    /^ *"cdat"<timedate>=/ { cdat = $NF }
    /^ *"mdat"<timedate>=/ { mdat = $NF }
    END { flush() }
  ' | sort
