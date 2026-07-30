#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

APP=opencode
LIBEXEC_DIR="$PREFIX/libexec/$APP"
BIN_FILE="$LIBEXEC_DIR/$APP"
WRAPPER="$PREFIX/bin/$APP"
GLIBC_LIB="$PREFIX/glibc/lib"

# SHA256 registrados (actualizar con cada release)
declare -A SHA256_ASSETS
SHA256_ASSETS=(
  ["v1.18.9"]="b16bd7593ea960a25d9c6849b3023bcd9b9244a6f51675341fd2052043b0670f"
)

GREEN='\033[0;32m'
RED='\033[0;31m'
ORANGE='\033[38;5;214m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $1"; }
fail() { echo -e "${RED}FAIL${NC}: $1"; ((FAILS++)); }
warn() { echo -e "${ORANGE}WARN${NC}: $1"; }
FAILS=0

echo "=== Verificacion de OpenCode nativo en Termux ==="
echo ""

# 1. Binario existe
if [[ -f "$BIN_FILE" ]]; then
  pass "Binario existe: $BIN_FILE"
else
  fail "Binario NO encontrado: $BIN_FILE"
fi

# 2. Es ejecutable
if [[ -x "$BIN_FILE" ]]; then
  pass "Binario es ejecutable"
else
  fail "Binario no es ejecutable (chmod?)"
fi

# 3. Es ELF ARM64
FILE_TYPE=""
if command -v file &>/dev/null; then
  FILE_TYPE=$(file "$BIN_FILE" 2>/dev/null || echo "")
fi
if echo "$FILE_TYPE" | grep -qi "ELF 64-bit LSB.*ARM aarch64"; then
  pass "Formato: ELF64 ARM aarch64"
elif [[ -n "$FILE_TYPE" ]]; then
  warn "Formato inusual: $FILE_TYPE"
else
  warn "file no disponible para verificar formato"
fi

# 4. Intérprete patcheado correctamente
if command -v patchelf &>/dev/null; then
  INTERP=$(patchelf --print-interpreter "$BIN_FILE" 2>/dev/null || echo "")
  EXPECTED_INTERP="$GLIBC_LIB/ld-linux-aarch64.so.1"
  if [[ "$INTERP" == "$EXPECTED_INTERP" ]]; then
    pass "Interpreter: $INTERP"
  else
    warn "Interpreter inesperado: $INTERP"
    warn "  Esperado: $EXPECTED_INTERP"
  fi
else
  warn "patchelf no instalado, no se puede verificar interpreter"
fi

# 5. Wrapper existe y es ejecutable
if [[ -x "$WRAPPER" ]]; then
  pass "Wrapper existe: $WRAPPER"
else
  fail "Wrapper no encontrado o no ejecutable"
fi

# 6. SHA256 del binario
VERSION=$("$WRAPPER" --version 2>/dev/null || echo "")
if [[ -n "$VERSION" ]]; then
  pass "Version: $VERSION"
  TAG="v$VERSION"
  EXPECTED="${SHA256_ASSETS[$TAG]:-}"
  if [[ -n "$EXPECTED" ]]; then
    ACTUAL=$(sha256sum "$BIN_FILE" | cut -d' ' -f1)
    if [[ "$ACTUAL" == "$EXPECTED" ]]; then
      pass "SHA256 verificado: $ACTUAL"
    else
      fail "SHA256 MISMATCH!
  Binario: $ACTUAL
  Esperado: $EXPECTED"
    fi
  else
    fail "SHA256 no registrado para $TAG - no se puede verificar el binario"
  fi
else
  warn "No se pudo ejecutar opencode para obtener version"
fi

# 7. Loader glibc existe
if [[ -f "$GLIBC_LIB/ld-linux-aarch64.so.1" ]]; then
  pass "Loader glibc existe en $GLIBC_LIB"
else
  fail "Loader glibc NO encontrado. Ejecutá: pkg install glibc-runner"
fi

echo ""
echo "=== Resultado: $FAILS fallos ==="
[[ "$FAILS" -gt 0 ]] && exit 1 || exit 0
