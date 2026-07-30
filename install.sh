#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

APP=opencode
REPO=anomalyco/opencode
GLIBC_PREFIX="$PREFIX/glibc"
LIBEXEC_DIR="$PREFIX/libexec/$APP"
BIN_FILE="$LIBEXEC_DIR/$APP"
WRAPPER="$PREFIX/bin/$APP"
ARCHIVE_NAME="$APP-linux-arm64.tar.gz"

# SHA256 de cada release (actualizar manualmente)
declare -A SHA256_ASSETS
SHA256_ASSETS=(
  ["v1.18.9"]="b16bd7593ea960a25d9c6849b3023bcd9b9244a6f51675341fd2052043b0670f"
)

MUTED='\033[0;2m'
GREEN='\033[0;32m'
RED='\033[0;31m'
ORANGE='\033[38;5;214m'
NC='\033[0m'

log() { echo -e "${MUTED}[$(date +%H:%M:%S)]${NC} $*"; }
info() { log "${GREEN}INFO${NC}: $*"; }
warn() { log "${ORANGE}WARN${NC}: $*"; }
err() { log "${RED}ERROR${NC}: $*"; }

usage() {
  cat <<EOF
Instalador nativo de OpenCode para Termux (glibc-runner)

Uso: install.sh [opciones]

Opciones:
  -h, --help              Mostrar ayuda
  -v, --version <version> Instalar version especifica (e.g., 1.18.9)
  -u, --uninstall         Desinstalar
  -r, --reinstall         Reinstalar (forzar)
EOF
  exit 0
}

REQUESTED_VERSION=""
UNINSTALL=false
REINSTALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    -v|--version) REQUESTED_VERSION="$2"; shift 2 ;;
    -u|--uninstall) UNINSTALL=true; shift ;;
    -r|--reinstall) REINSTALL=true; shift ;;
    *) warn "Opcion desconocida: $1"; shift ;;
  esac
done

uninstall() {
  info "Desinstalando..."
  rm -rf "$LIBEXEC_DIR"
  rm -f "$WRAPPER"
  info "OpenCode eliminado. Para remover glibc-runner si no lo necesitas:"
  info "  pkg remove glibc-runner patchelf glibc-repo"
  exit 0
}

[[ "$UNINSTALL" == true ]] && uninstall

check_termux() {
  if [[ ! -d /data/data/com.termux ]]; then
    err "Esto solo funciona en Termux."
    info "No se detecto /data/data/com.termux"
    exit 1
  fi
  if [[ "$(uname -m)" != "aarch64" ]]; then
    err "Solo soportado en aarch64 (ARM64). Arquitectura actual: $(uname -m)"
    exit 1
  fi
}

resolve_version() {
  if [[ -n "$REQUESTED_VERSION" ]]; then
    VERSION="${REQUESTED_VERSION#v}"
  else
    local json
    json=$(curl -sfL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || true)
    if [[ -z "$json" ]]; then
      err "No se pudo obtener la ultima version desde GitHub API"
      err "Probá especificando la version: -v 1.18.9"
      exit 1
    fi
    if command -v jq &>/dev/null; then
      VERSION=$(echo "$json" | jq -r '.tag_name[1:] // empty' 2>/dev/null || true)
    else
      VERSION=$(echo "$json" | awk -F '"' '/"tag_name":/{print $4}' | sed 's/^v//' 2>/dev/null || true)
    fi
    if [[ -z "$VERSION" ]]; then
      err "No se pudo extraer la version desde la respuesta de GitHub API"
      err "Instalá jq: pkg install jq"
      err "O especificá la version manualmente: -v 1.18.9"
      exit 1
    fi
  fi
  TAG="v$VERSION"
  info "Version objetivo: $VERSION"
}

check_current() {
  if [[ "$REINSTALL" == true ]]; then
    return 0
  fi
  if [[ -x "$BIN_FILE" ]]; then
    local current
    # unset LD_PRELOAD para que el loader glibc no intente cargar libtermux-exec.so (bionic)
    current=$((unset LD_PRELOAD; "$BIN_FILE" --version) 2>/dev/null || echo "")
    if [[ -n "$current" && "$current" == "$VERSION" ]]; then
      info "OpenCode $VERSION ya instalado. Usá -r para reinstalar."
      exit 0
    fi
  fi
  if [[ -f "$WRAPPER" ]]; then
    local wrapper_current
    wrapper_current=$("$WRAPPER" --version 2>/dev/null || echo "")
    if [[ -n "$wrapper_current" && "$wrapper_current" == "$VERSION" ]]; then
      info "OpenCode $VERSION ya instalado (wrapper funcional). Usá -r para reinstalar."
      exit 0
    fi
  fi
}

install_deps() {
  info "Actualizando repositorios e instalando dependencias..."
  pkg update -y 2>&1 || { warn "pkg update fallo, continuando de todas formas..."; }
  pkg install glibc-repo glibc-runner patchelf file jq -y 2>&1 || {
    err "Falló la instalacion de dependencias."
    err "Verificá que Termux esté actualizado: pkg update && pkg upgrade"
    exit 1
  }
  if [[ ! -f "$GLIBC_PREFIX/lib/ld-linux-aarch64.so.1" ]]; then
    err "Loader glibc no encontrado en $GLIBC_PREFIX/lib/"
    err "Ejecutá: pkg install glibc-repo glibc-runner"
    exit 1
  fi
  info "Loader glibc: $GLIBC_PREFIX/lib/ld-linux-aarch64.so.1"
}

download_and_verify() {
  local URL="https://github.com/$REPO/releases/download/$TAG/$ARCHIVE_NAME"
  local TMP_DIR="${TMPDIR:-$PREFIX/tmp}"
  local TMP_FILE="$TMP_DIR/opencode-install-$TAG.tar.gz"
  local EXPECTED="${SHA256_ASSETS[$TAG]:-}"

  # Verificar que el directorio temporal exista
  mkdir -p "$TMP_DIR"

  info "Descargando $ARCHIVE_NAME..."
  curl -fL -o "$TMP_FILE" "$URL" || {
    err "Falló la descarga desde $URL"
    exit 1
  }

  local ACTUAL
  ACTUAL=$(sha256sum "$TMP_FILE" | cut -d' ' -f1)

  # Fail-closed: si no hay hash registrado, no confiar en el binario
  if [[ -z "$EXPECTED" ]]; then
    err "SHA256 no registrado para $TAG en SHA256_ASSETS."
    err "El hash del binario descargado es: $ACTUAL"
    err "Verificá manualmente en https://github.com/$REPO/releases/tag/$TAG"
    err "Luego actualizá SHA256_ASSETS en install.sh y verify.sh,"
    err "o usá -v <version> con una version que tenga hash registrado."
    rm -f "$TMP_FILE"
    exit 1
  fi

  if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    err "SHA256 MISMATCH!"
    err "  Esperado: $EXPECTED"
    err "  Obtenido: $ACTUAL"
    err "  URL: $URL"
    rm -f "$TMP_FILE"
    exit 1
  fi
  info "SHA256 verificado: $ACTUAL"

  # Verificar que sea gzip válido
  if ! file "$TMP_FILE" 2>/dev/null | grep -qi "gzip compressed"; then
    err "El archivo descargado no es un tarball gzip"
    file "$TMP_FILE"
    rm -f "$TMP_FILE"
    exit 1
  fi

  # Extraer a directorio temporal para manejar estructuras variables del tarball
  local EXTRACT_DIR="$TMP_DIR/opencode-extract-$TAG"
  rm -rf "$EXTRACT_DIR"
  mkdir -p "$EXTRACT_DIR"
  tar -xzf "$TMP_FILE" -C "$EXTRACT_DIR"
  rm -f "$TMP_FILE"

  # Buscar el binario en cualquier nivel del tarball
  local found
  found=$(find "$EXTRACT_DIR" -name "$APP" -type f 2>/dev/null | head -1)
  if [[ -z "$found" ]]; then
    err "No se encontró el binario '$APP' dentro del tarball"
    err "Contenido del tarball:"
    find "$EXTRACT_DIR" -type f 2>/dev/null | head -20
    rm -rf "$EXTRACT_DIR"
    exit 1
  fi

  mkdir -p "$LIBEXEC_DIR"
  mv "$found" "$BIN_FILE"
  chmod 755 "$BIN_FILE"
  rm -rf "$EXTRACT_DIR"

  if [[ ! -x "$BIN_FILE" ]]; then
    err "El binario extraido no es ejecutable"
    ls -la "$BIN_FILE"
    exit 1
  fi
  info "Binario instalado en $BIN_FILE"
}

patch_interpreter() {
  local LOADER="$GLIBC_PREFIX/lib/ld-linux-aarch64.so.1"
  local RPATH="$GLIBC_PREFIX/lib"

  info "Aplicando patchelf: interpreter=$LOADER, rpath=$RPATH"
  patchelf --set-interpreter "$LOADER" --set-rpath "$RPATH" "$BIN_FILE" || {
    err "Falló patchelf. Verificá que el binario sea ELF64 valido."
    exit 1
  }

  # Verificar que el parche quedó bien
  local CHECK_INTERP
  CHECK_INTERP=$(patchelf --print-interpreter "$BIN_FILE" 2>/dev/null || echo "")
  if [[ "$CHECK_INTERP" != "$LOADER" ]]; then
    err "patchelf no aplicó correctamente el intérprete"
    err "  Esperado: $LOADER"
    err "  Actual: $CHECK_INTERP"
    exit 1
  fi
  info "Interpreter verificado: $CHECK_INTERP"
}

create_wrapper() {
  cat > "$WRAPPER" << WRAPPER_EOF
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BIN="$BIN_FILE"

if [[ ! -x "\$BIN" ]]; then
  echo "ERROR: opencode no encontrado en \$BIN" >&2
  echo "Ejecutá: bash install.sh" >&2
  exit 1
fi

# libtermux-exec.so (bionic) + LD_LIBRARY_PATH heredada crashean procesos glibc
# termux-exec reescribe shebangs via execve() hook; sin LD_PRELOAD los
# scripts con shebang estandar fallan con ENOENT en Android.
# LD_LIBRARY_PATH con rutas bionic provoca segfault al cargar libs glibc.
unset LD_PRELOAD
unset LD_LIBRARY_PATH
exec "\$BIN" "\$@"
WRAPPER_EOF

  chmod 755 "$WRAPPER"
  info "Wrapper creado en $WRAPPER (ya en PATH)"
}

verify_install() {
  info "Verificando instalacion..."
  if ! "$WRAPPER" --version &>/dev/null; then
    err "El wrapper no pudo ejecutar opencode. Probá reiniciar Termux."
    err "Comando: $(command -v "$APP")"
    exit 1
  fi
  local VER
  VER=$("$WRAPPER" --version 2>/dev/null)
  info "OpenCode $VER funcionando correctamente"
}

show_logo() {
  echo ""
  echo "${GREEN}OpenCode instalado nativamente en Termux!${NC}"
  echo ""
  echo "${MUTED}Uso:${NC}"
  echo "  ${GREEN}opencode${NC}              ${MUTED}# Iniciar en directorio actual${NC}"
  echo ""
  echo "${MUTED}Primera vez:${NC}"
  echo "  /connect    ${MUTED}# Conectar provider (API key)${NC}"
  echo ""
  echo "${MUTED}Documentacion: https://opencode.ai/docs${NC}"
}

main() {
  check_termux
  resolve_version
  check_current
  install_deps
  download_and_verify
  patch_interpreter
  create_wrapper
  verify_install
  show_logo
}

main
