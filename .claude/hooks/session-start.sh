#!/bin/bash
# SessionStart hook.
# 1. Always: print the lessons index, so every Claude session starts from what real runs taught.
# 2. Claude Code on the web only: make the repo's checks runnable (pwsh, Bicep, PSScriptAnalyzer,
#    Pester, shellcheck, gitleaks). Tools come from GitHub releases (the PowerShell Gallery may be blocked);
#    Pester only exists on the Gallery, so it is best-effort. Idempotent; never fails the session.
# stdout becomes session context: keep it to the index and a one-line tool status.
set -uo pipefail

repo="${CLAUDE_PROJECT_DIR:-$(pwd)}"
if [ -f "$repo/docs/lessons/README.md" ]; then
  echo "=== Lessons from real runs (build/lessons). Read the relevant one before changing that area. ==="
  sed -n '/^| #/,/^$/p' "$repo/docs/lessons/README.md"
fi

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

tools="$HOME/.avdlz-tools"
log="$tools/install.log"
mkdir -p "$tools/bin" "$tools/modules"
: > "$log"

fetch() { curl -fsSL --retry 3 -o "$2" "$1" >>"$log" 2>&1; }

# PowerShell 7
if [ ! -x "$tools/pwsh/pwsh" ] && ! command -v pwsh >/dev/null 2>&1; then
  mkdir -p "$tools/pwsh"
  fetch https://github.com/PowerShell/PowerShell/releases/download/v7.5.4/powershell-7.5.4-linux-x64.tar.gz "$tools/pwsh.tgz" \
    && tar -xzf "$tools/pwsh.tgz" -C "$tools/pwsh" >>"$log" 2>&1 && chmod +x "$tools/pwsh/pwsh" && rm -f "$tools/pwsh.tgz"
fi
[ -x "$tools/pwsh/pwsh" ] && ln -sf "$tools/pwsh/pwsh" "$tools/bin/pwsh"

# Bicep CLI
if [ ! -x "$tools/bin/bicep" ] && ! command -v bicep >/dev/null 2>&1; then
  fetch https://github.com/Azure/bicep/releases/latest/download/bicep-linux-x64 "$tools/bin/bicep" && chmod +x "$tools/bin/bicep"
fi

# ShellCheck (lints deploy.sh)
if [ ! -x "$tools/bin/shellcheck" ] && ! command -v shellcheck >/dev/null 2>&1; then
  fetch https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz "$tools/sc.txz" \
    && tar -xJf "$tools/sc.txz" -C "$tools" >>"$log" 2>&1 && cp "$tools/shellcheck-v0.10.0/shellcheck" "$tools/bin/" && rm -rf "$tools/sc.txz" "$tools/shellcheck-v0.10.0"
fi

# gitleaks, same version as the secret-scan workflow
if [ ! -x "$tools/bin/gitleaks" ] && ! command -v gitleaks >/dev/null 2>&1; then
  fetch https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz "$tools/gl.tgz" \
    && tar -xzf "$tools/gl.tgz" -C "$tools/bin" gitleaks >>"$log" 2>&1 && rm -f "$tools/gl.tgz"
fi

# PSScriptAnalyzer, same version as CI (a newer analyzer enforces more rules)
if [ ! -f "$tools/modules/PSScriptAnalyzer/PSScriptAnalyzer.psd1" ]; then
  mkdir -p "$tools/modules/PSScriptAnalyzer"
  fetch https://github.com/PowerShell/PSScriptAnalyzer/releases/download/1.25.0/PSScriptAnalyzer.1.25.0.nupkg "$tools/psa.nupkg" \
    && (cd "$tools/modules/PSScriptAnalyzer" && unzip -oq "$tools/psa.nupkg" >>"$log" 2>&1) && rm -f "$tools/psa.nupkg"
fi

export PATH="$tools/bin:$PATH"
export PSModulePath="$tools/modules${PSModulePath:+:$PSModulePath}"

# Pester (Gallery only; skipped quietly when the Gallery is unreachable)
if command -v pwsh >/dev/null 2>&1 && [ ! -d "$tools/modules/Pester" ]; then
  timeout 120 pwsh -NoProfile -NonInteractive -Command \
    "Save-Module Pester -MinimumVersion 5.5.0 -Path '$tools/modules' -Repository PSGallery -Force -ErrorAction Stop" >>"$log" 2>&1 || true
fi

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export PATH=\"$tools/bin:\$PATH\""
    echo "export PSModulePath=\"$tools/modules\${PSModulePath:+:\$PSModulePath}\""
  } >> "$CLAUDE_ENV_FILE"
fi

have() { if [ "$1" = ok ]; then printf '%s ok' "$2"; else printf '%s MISSING' "$2"; fi; }
s=()
command -v pwsh >/dev/null 2>&1 && s+=("$(have ok pwsh)") || s+=("$(have no pwsh)")
command -v bicep >/dev/null 2>&1 && s+=("$(have ok bicep)") || s+=("$(have no bicep)")
command -v shellcheck >/dev/null 2>&1 && s+=("$(have ok shellcheck)") || s+=("$(have no shellcheck)")
command -v gitleaks >/dev/null 2>&1 && s+=("$(have ok gitleaks)") || s+=("$(have no gitleaks)")
[ -f "$tools/modules/PSScriptAnalyzer/PSScriptAnalyzer.psd1" ] && s+=("$(have ok PSScriptAnalyzer)") || s+=("$(have no PSScriptAnalyzer)")
[ -d "$tools/modules/Pester" ] && s+=("$(have ok Pester)") || s+=("Pester unavailable (Gallery blocked): run the offline scenarios directly with pwsh -File build/tests/offline/<Name>.Scenario.ps1")
echo "=== Tools: ${s[*]} (log: $log) ==="
exit 0
