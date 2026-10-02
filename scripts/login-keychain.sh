#!/usr/bin/env bash
# Lists the login keychain's generic passwords under one service: account,
# creation and modification time. Attributes only, never a secret, so it
# never prompts.
#
# Parsing no generic password at all fails: a login keychain always holds
# some, so none means the dump's format moved, and an empty listing would
# compare equal to anything.
set -euo pipefail

service="${1:?usage: login-keychain.sh SERVICE}"
dump="$(security dump-keychain "${HOME}/Library/Keychains/login.keychain-db")"
awk -v service="\"${service}\"" '
  function flush() {
    if (class == "\"genp\"") {
      parsed++
      if (svce == service) print acct "\t" cdat "\t" mdat
    }
    class = ""; svce = ""; acct = ""; cdat = ""; mdat = ""
  }
  /^keychain: / { flush() }
  /^class: / { class = $2 }
  /^ *"svce"<blob>=/ { sub(/^ *"svce"<blob>=/, ""); svce = $0 }
  /^ *"acct"<blob>=/ { sub(/^ *"acct"<blob>=/, ""); acct = $0 }
  /^ *"cdat"<timedate>=/ { cdat = $NF }
  /^ *"mdat"<timedate>=/ { mdat = $NF }
  END {
    flush()
    if (parsed == 0) {
      print "login-keychain.sh: parsed no generic password from the dump" > "/dev/stderr"
      exit 1
    }
  }
' <<<"${dump}" | sort
