function promptLooksFingerprint(text) {
  var s = String(text || "").toLowerCase()
  return s.indexOf("finger") !== -1 || s.indexOf("fprint") !== -1 || s.indexOf("swipe") !== -1
}

function fingerprintConfiguredFromPamConfig(raw) {
  // Fingerprint is available whenever pam_fprintd appears anywhere in the auth
  // stack — it need not be the first module. A clamshell gate (pam_exec) may
  // legitimately precede it to skip fingerprint while the lid is closed.
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^\s+|\s+$/g, "")
    if (!line || line.charAt(0) === "#") continue
    if (!line.match(/^auth\s+/)) continue
    if (line.indexOf("pam_fprintd.so") !== -1) return true
  }
  return false
}

function authorizationRequest(message) {
  var text = String(message || "")
  // pkexec's message: "Authentication is needed to run `CMD' as the super user"
  // (or "... as user NAME"). CMD is pkexec's cmdline_short, which keeps any
  // quotes the command itself contains, so anchor on the fixed tail instead of
  // stopping at the next quote.
  var match = text.match(/^Authentication is (?:needed|required) to run [`']([\s\S]+)[`'] as (?:(the super user)|user ([\s\S]+))$/i)
  if (!match) return { title: text, program: "", args: "", command: "" }

  var command = match[1].replace(/^\s+|\s+$/g, "").match(/^(\S+)\s*([\s\S]*)$/)
  if (!command) return { title: text, program: "", args: "", command: "" }

  // command keeps the message's text exactly, empty and space-padded
  // arguments included, for matching against the waiting pkexec.
  return {
    title: match[2] ? "Run as root" : "Run as " + match[3],
    program: command[1],
    args: command[2],
    command: match[1]
  }
}

// omarchy-polkit-caller's JSON: who started pkexec, and the full command it was
// given, shell-quoted and already capped.
function callerFromOutput(exitCode, output) {
  var info = null
  if (exitCode === 0) {
    try {
      info = JSON.parse(String(output || ""))
    } catch (e) {}
  }
  info = info || {}
  return {
    requestedBy: typeof info.requestedBy === "string" ? info.requestedBy : "",
    command: typeof info.command === "string" ? info.command : "",
    shortened: info.shortened === true
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    promptLooksFingerprint: promptLooksFingerprint,
    fingerprintConfiguredFromPamConfig: fingerprintConfiguredFromPamConfig,
    authorizationRequest: authorizationRequest,
    callerFromOutput: callerFromOutput
  }
}
