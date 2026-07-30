#!/data/data/com.termux/files/usr/bin/bash
# Verifica el estado de la instalacion de OpenCode en Termux.
#
# IMPORTANTE sobre el hash: patchelf reescribe PT_INTERP y DT_RUNPATH, por lo
# que el binario instalado NUNCA tiene el mismo sha256 que el tarball del
# release. Comparar uno contra otro (como hacia la version anterior de este
# script) falla siempre. Aca se compara contra el hash post-patchelf que
# install.sh registro en el manifest, lo que si detecta manipulacion posterior.

set -uo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

APP=opencode
GLIBC_PREFIX="$PREFIX/glibc"
GLIBC_LIB="$GLIBC_PREFIX/lib"
LOADER="$GLIBC_LIB/ld-linux-aarch64.so.1"
LIBEXEC_DIR="$PREFIX/libexec/$APP"
BIN_FILE="$LIBEXEC_DIR/$APP"
MANIFEST="$LIBEXEC_DIR/manifest.txt"
WRAPPER="$PREFIX/bin/$APP"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HASH_FILE="$SCRIPT_DIR/sha256.txt"

if [[ -t 1 ]]; then
  GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; ORANGE=$'\033[38;5;214m'
  MUTED=$'\033[0;2m'; NC=$'\033[0m'
else
  GREEN=''; RED=''; ORANGE=''; MUTED=''; NC=''
fi

FAILS=0
WARNS=0

# Nota: se usa FAILS=$((FAILS+1)) y no ((FAILS++)). Con FAILS=0, ((FAILS++))
# devuelve estado de salida 1 (post-incremento evalua a 0), lo que abortaria
# el script si estuviera activo `set -e`.
pass() { printf '%sPASS%s: %s\n' "$GREEN" "$NC" "$1"; }
fail() { printf '%sFAIL%s: %s\n' "$RED" "$NC" "$1"; FAILS=$((FAILS + 1)); }
warn() { printf '%sWARN%s: %s\n' "$ORANGE" "$NC" "$1"; WARNS=$((WARNS + 1)); }
note() { printf '%s      %s%s\n' "$MUTED" "$1" "$NC"; }

manifest_get() {
  local key="$1"
  [[ -f "$MANIFEST" ]] || return 0
  awk -F= -v k="$key" '$1==k { sub(/^[^=]*=/,""); print; exit }' "$MANIFEST"
}

lookup_sha256() {
  local tag="$1"
  [[ -f "$HASH_FILE" ]] || return 0
  awk -v t="$tag" '$1==t { print $2; exit }' "$HASH_FILE"
}

normalize_version() {
  grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"${1:-}" | head -1 || true
}

printf '=== Verificacion de OpenCode en Termux ===\n\n'

# 1. Manifest de instalacion
M_VERSION=""; M_TAG=""; M_SHA_PATCHED=""; M_SHA_TARBALL=""
M_INTERP=""; M_RPATH=""; M_ATTEST=""
if [[ -f "$MANIFEST" ]]; then
  M_VERSION=$(manifest_get version)
  M_TAG=$(manifest_get tag)
  M_SHA_PATCHED=$(manifest_get binary_sha256_patched)
  M_SHA_TARBALL=$(manifest_get tarball_sha256)
  M_INTERP=$(manifest_get interpreter)
  M_RPATH=$(manifest_get rpath)
  M_ATTEST=$(manifest_get attestation)
  pass "Manifest presente (version $M_VERSION, instalado $(manifest_get installed_at))"
else
  warn "No hay manifest en $MANIFEST"
  note "Instalacion previa a este script o hecha a mano."
  note "Reinstalá con 'bash install.sh -r' para habilitar la verificacion de integridad."
fi

# 2. Binario presente y ejecutable
if [[ -f "$BIN_FILE" ]]; then
  pass "Binario presente: $BIN_FILE"
  if [[ -x "$BIN_FILE" ]]; then
    pass "Binario ejecutable"
  else
    fail "El binario no tiene permiso de ejecucion (chmod 755 $BIN_FILE)"
  fi
else
  fail "Binario NO encontrado: $BIN_FILE"
fi

# 3. Formato ELF
if [[ -f "$BIN_FILE" ]]; then
  if command -v file >/dev/null 2>&1; then
    FT=$(file "$BIN_FILE" 2>/dev/null || true)
    if grep -qi 'ELF 64-bit.*ARM aarch64' <<<"$FT"; then
      pass "Formato: ELF64 ARM aarch64"
    else
      fail "Formato inesperado: ${FT:-<desconocido>}"
    fi
  else
    warn "'file' no disponible; no se puede verificar el formato ELF"
  fi
fi

# 4. Interpreter y rpath
if [[ -f "$BIN_FILE" ]] && command -v patchelf >/dev/null 2>&1; then
  EXPECTED_INTERP="${M_INTERP:-$LOADER}"
  EXPECTED_RPATH="${M_RPATH:-$GLIBC_LIB}"

  INTERP=$(patchelf --print-interpreter "$BIN_FILE" 2>/dev/null || true)
  if [[ "$INTERP" == "$EXPECTED_INTERP" ]]; then
    pass "Interpreter: $INTERP"
  else
    fail "Interpreter incorrecto"
    note "Esperado: $EXPECTED_INTERP"
    note "Obtenido: ${INTERP:-<vacio>}"
    note "Reaplicá con: bash install.sh -r"
  fi

  RP=$(patchelf --print-rpath "$BIN_FILE" 2>/dev/null || true)
  if [[ "$RP" == *"$EXPECTED_RPATH"* ]]; then
    pass "Rpath: $RP"
  else
    fail "Rpath incorrecto (esperado contener $EXPECTED_RPATH, obtenido: ${RP:-<vacio>})"
  fi
elif [[ -f "$BIN_FILE" ]]; then
  warn "patchelf no instalado; no se puede verificar interpreter/rpath"
fi

# 5. Integridad del binario instalado (post-patchelf)
if [[ -f "$BIN_FILE" ]]; then
  if [[ -n "$M_SHA_PATCHED" ]]; then
    ACTUAL=$(sha256sum "$BIN_FILE" | cut -d' ' -f1)
    if [[ "$ACTUAL" == "$M_SHA_PATCHED" ]]; then
      pass "Integridad del binario instalado OK (sha256 ${ACTUAL:0:16}...)"
    else
      fail "El binario instalado cambio desde la instalacion"
      note "Registrado: $M_SHA_PATCHED"
      note "Actual:     $ACTUAL"
      note "Puede ser una actualizacion del stack glibc, un re-patchelf o manipulacion."
    fi
  else
    warn "Sin hash registrado: no se puede verificar la integridad del binario"
  fi
fi

# 6. Cross-check del hash del tarball contra el registro sha256.txt
if [[ -n "$M_SHA_TARBALL" && -n "$M_TAG" ]]; then
  REG=$(lookup_sha256 "$M_TAG")
  if [[ -z "$REG" ]]; then
    warn "sha256.txt no tiene entrada para $M_TAG; no se puede cross-checkear el origen"
  elif [[ "$REG" == "$M_SHA_TARBALL" ]]; then
    pass "El tarball instalado coincide con el registro de sha256.txt"
  else
    fail "El hash del tarball instalado no coincide con sha256.txt"
    note "Manifest:   $M_SHA_TARBALL"
    note "sha256.txt: $REG"
  fi
fi

# 7. Attestation registrada en la instalacion
case "$M_ATTEST" in
  verificada) pass "Release attestation de GitHub verificada al instalar" ;;
  fallida)    warn "La attestation no pudo verificarse al instalar" ;;
  omitida)    warn "Attestation omitida al instalar (gh no estaba disponible)"
              note "Instalá gh y reinstalá con --require-attestation para verificacion criptografica." ;;
  "")         : ;;
  *)          warn "Estado de attestation desconocido: $M_ATTEST" ;;
esac

# 8. Wrapper
if [[ -x "$WRAPPER" ]]; then
  pass "Wrapper presente: $WRAPPER"
  if grep -q 'unset LD_PRELOAD' "$WRAPPER" && grep -q 'unset LD_LIBRARY_PATH' "$WRAPPER"; then
    pass "El wrapper limpia LD_PRELOAD y LD_LIBRARY_PATH"
  else
    fail "El wrapper no limpia LD_PRELOAD/LD_LIBRARY_PATH (crashea sobre glibc)"
  fi
else
  fail "Wrapper no encontrado o no ejecutable: $WRAPPER"
fi

# 9. Loader glibc y DNS
if [[ -f "$LOADER" ]]; then
  pass "Loader glibc presente: $LOADER"
else
  fail "Loader glibc NO encontrado. Ejecutá: pkg install glibc-repo glibc-runner"
fi

if [[ -f "$GLIBC_PREFIX/etc/nsswitch.conf" ]]; then
  pass "nsswitch.conf presente (resolucion DNS de glibc)"
else
  warn "Falta $GLIBC_PREFIX/etc/nsswitch.conf; puede fallar la resolucion DNS"
  note "Solucion: printf 'hosts: files dns\\n' > $GLIBC_PREFIX/etc/nsswitch.conf"
fi

# 10. Ejecucion real
if [[ -x "$WRAPPER" ]]; then
  if OUT=$("$WRAPPER" --version 2>&1); then
    RUNV=$(normalize_version "$OUT")
    pass "Ejecucion correcta (--version -> ${RUNV:-$OUT})"
    if [[ -n "$M_VERSION" && -n "$RUNV" && "$RUNV" != "$(normalize_version "$M_VERSION")" ]]; then
      fail "La version ejecutada ($RUNV) no coincide con el manifest ($M_VERSION)"
    fi
  else
    fail "opencode no se pudo ejecutar"
    note "Salida: $(printf '%s' "$OUT" | head -2)"
  fi
fi

printf '\n=== Resultado: %d fallos, %d advertencias ===\n' "$FAILS" "$WARNS"
if [[ "$FAILS" -gt 0 ]]; then
  exit 1
fi
exit 0
