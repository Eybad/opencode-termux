#!/data/data/com.termux/files/usr/bin/bash
# Instalador de OpenCode para Termux sobre el overlay glibc (sin proot).
#
# Modelo de integridad en dos capas:
#   1. Instalacion: se verifica el SHA256 del TARBALL contra sha256.txt (fail-closed)
#      y, si gh esta disponible, la release attestation firmada por GitHub.
#   2. Post-instalacion: se registra un manifest con el hash del binario ya
#      parcheado, para que verify.sh pueda detectar manipulacion posterior.
#
# patchelf MODIFICA los bytes del binario, por lo que el hash del binario
# instalado nunca coincide con el del tarball. Por eso se registran ambos.

set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

APP=opencode
REPO=anomalyco/opencode
ARCHIVE_NAME="$APP-linux-arm64.tar.gz"
RELEASE_PREDICATE="https://in-toto.io/attestation/release/v0.2"

GLIBC_PREFIX="$PREFIX/glibc"
LOADER="$GLIBC_PREFIX/lib/ld-linux-aarch64.so.1"
RPATH="$GLIBC_PREFIX/lib"
LIBEXEC_DIR="$PREFIX/libexec/$APP"
BIN_FILE="$LIBEXEC_DIR/$APP"
MANIFEST="$LIBEXEC_DIR/manifest.txt"
WRAPPER="$PREFIX/bin/$APP"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HASH_FILE="$SCRIPT_DIR/sha256.txt"

# Colores como escapes reales; se desactivan si la salida no es una terminal.
if [[ -t 1 ]]; then
  MUTED=$'\033[0;2m'; GREEN=$'\033[0;32m'; RED=$'\033[0;31m'
  ORANGE=$'\033[38;5;214m'; NC=$'\033[0m'
else
  MUTED=''; GREEN=''; RED=''; ORANGE=''; NC=''
fi

log()  { printf '%s[%s]%s %s\n' "$MUTED" "$(date +%H:%M:%S)" "$NC" "$*"; }
info() { log "${GREEN}INFO${NC}: $*"; }
warn() { log "${ORANGE}WARN${NC}: $*" >&2; }
err()  { log "${RED}ERROR${NC}: $*" >&2; }

usage() {
  cat <<EOF
Instalador de OpenCode para Termux (overlay glibc, sin proot)

Uso: install.sh [opciones]

Opciones:
  -h, --help                 Mostrar esta ayuda
  -v, --version <version>    Instalar una version especifica (ej: 1.18.9)
  -u, --uninstall            Desinstalar
  -r, --reinstall            Forzar reinstalacion
      --sha256 <hash>        Pinear el SHA256 del tarball explicitamente
                             (para usar el script sin sha256.txt)
      --require-attestation  Abortar si no se puede verificar la attestation
                             de GitHub (requiere gh instalado y autenticado)

Sin -v se consulta la ultima release en GitHub. Si esa version no tiene un
hash registrado en sha256.txt, el script ABORTA (fail-closed): agregá el hash
o pasá --sha256.
EOF
  exit 0
}

REQUESTED_VERSION=""
PINNED_SHA=""
UNINSTALL=false
REINSTALL=false
REQUIRE_ATTEST=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    -v|--version)
      [[ $# -ge 2 ]] || { err "--version requiere un argumento (ej: -v 1.18.9)"; exit 2; }
      REQUESTED_VERSION="$2"; shift 2 ;;
    --sha256)
      [[ $# -ge 2 ]] || { err "--sha256 requiere un argumento"; exit 2; }
      PINNED_SHA="$2"; shift 2 ;;
    --require-attestation) REQUIRE_ATTEST=true; shift ;;
    -u|--uninstall) UNINSTALL=true; shift ;;
    -r|--reinstall) REINSTALL=true; shift ;;
    *)
      err "Opcion desconocida: $1"
      err "Usá --help para ver las opciones disponibles."
      exit 2 ;;
  esac
done

# --- estado para limpieza / rollback ------------------------------------------
TMP_FILE=""
EXTRACT_DIR=""
BACKUP_DIR=""
FRESH_INSTALL=false
INSTALL_DONE=false

cleanup() {
  local rc=$?
  if [[ -n "$TMP_FILE" && -f "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
  fi
  if [[ -n "$EXTRACT_DIR" && -d "$EXTRACT_DIR" ]]; then
    rm -rf "$EXTRACT_DIR"
  fi

  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    if [[ $rc -ne 0 && "$INSTALL_DONE" != true ]]; then
      warn "Instalacion fallida: restaurando la version anterior..."
      rm -rf "$LIBEXEC_DIR"
      mv "$BACKUP_DIR" "$LIBEXEC_DIR"
    else
      rm -rf "$BACKUP_DIR"
    fi
  elif [[ $rc -ne 0 && "$INSTALL_DONE" != true && "$FRESH_INSTALL" == true ]]; then
    # No habia instalacion previa que restaurar: no dejar una a medias, porque
    # una proxima corrida podria confundirla con una instalacion valida.
    warn "Instalacion fallida: limpiando los archivos incompletos..."
    rm -rf "$LIBEXEC_DIR"
    rm -f "$WRAPPER"
  fi
  exit $rc
}
trap cleanup EXIT

uninstall() {
  info "Desinstalando..."
  rm -rf "$LIBEXEC_DIR"
  rm -f "$WRAPPER"
  info "OpenCode eliminado."
  info "Para remover las dependencias si no las necesitas:"
  info "  pkg remove glibc-runner patchelf glibc-repo"
  exit 0
}

[[ "$UNINSTALL" == true ]] && uninstall

# --- helpers ------------------------------------------------------------------

# Extrae el primer x.y.z de una cadena arbitraria. `opencode --version` puede
# imprimir "1.18.9", "opencode 1.18.9" o "1.18.9 (build abc)" segun la version.
normalize_version() {
  local out
  out=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"${1:-}" | head -1 || true)
  printf '%s' "$out"
}

lookup_sha256() {
  local tag="$1"
  [[ -f "$HASH_FILE" ]] || return 0
  awk -v t="$tag" '$1==t { print $2; exit }' "$HASH_FILE"
}

manifest_get() {
  local key="$1"
  [[ -f "$MANIFEST" ]] || return 0
  awk -F= -v k="$key" '$1==k { sub(/^[^=]*=/,""); print; exit }' "$MANIFEST"
}

sha_of() { sha256sum "$1" | cut -d' ' -f1; }

# --- pasos --------------------------------------------------------------------

preflight() {
  if [[ ! -d /data/data/com.termux ]]; then
    err "Esto solo funciona en Termux (no se detecto /data/data/com.termux)."
    exit 1
  fi
  if [[ "$(uname -m)" != "aarch64" ]]; then
    err "Solo soportado en aarch64 (ARM64). Arquitectura actual: $(uname -m)"
    exit 1
  fi
  # curl se usa ANTES de install_deps, asi que tiene que existir de entrada.
  local missing=()
  local c
  for c in curl tar sha256sum awk; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Faltan herramientas basicas: ${missing[*]}"
    err "Instalalas con: pkg install curl tar coreutils gawk"
    exit 1
  fi
}

resolve_version() {
  if [[ -n "$REQUESTED_VERSION" ]]; then
    VERSION=$(normalize_version "$REQUESTED_VERSION")
    if [[ -z "$VERSION" ]]; then
      err "Version invalida: '$REQUESTED_VERSION' (se espera x.y.z, ej: 1.18.9)"
      exit 2
    fi
  else
    local body code
    body=$(mktemp)
    code=$(curl -sS --proto '=https' --tlsv1.2 -L \
             -H 'Accept: application/vnd.github+json' \
             -o "$body" -w '%{http_code}' \
             "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || echo 000)

    case "$code" in
      200) : ;;
      403|429)
        err "GitHub API devolvio HTTP $code (limite de peticiones sin autenticar)."
        err "Esperá un rato, o especificá la version: -v 1.18.9"
        rm -f "$body"; exit 1 ;;
      000)
        err "No se pudo contactar la GitHub API (sin red o DNS roto)."
        err "Especificá la version manualmente: -v 1.18.9"
        rm -f "$body"; exit 1 ;;
      *)
        err "GitHub API devolvio HTTP $code al buscar la ultima release."
        err "Especificá la version manualmente: -v 1.18.9"
        rm -f "$body"; exit 1 ;;
    esac

    local raw
    if command -v jq >/dev/null 2>&1; then
      raw=$(jq -r '.tag_name // empty' "$body" 2>/dev/null || true)
    else
      raw=$(awk -F'"' '/"tag_name":/ { print $4; exit }' "$body" || true)
    fi
    rm -f "$body"

    VERSION=$(normalize_version "$raw")
    if [[ -z "$VERSION" ]]; then
      err "No se pudo extraer la version de la respuesta de GitHub."
      err "Especificá la version manualmente: -v 1.18.9"
      exit 1
    fi
  fi
  TAG="v$VERSION"
  info "Version objetivo: $VERSION"
}

# Resuelve el hash esperado ANTES de descargar, para fallar rapido y no bajar
# 170 MB en vano si la version no esta registrada.
resolve_expected_sha() {
  if [[ -n "$PINNED_SHA" ]]; then
    EXPECTED_SHA="$PINNED_SHA"
    warn "Usando SHA256 pasado por --sha256 (verificalo vos mismo)."
    return 0
  fi
  EXPECTED_SHA=$(lookup_sha256 "$TAG")
  if [[ -z "$EXPECTED_SHA" ]]; then
    err "No hay SHA256 registrado para $TAG."
    if [[ ! -f "$HASH_FILE" ]]; then
      err "Tampoco se encontro $HASH_FILE (¿clonaste el repo completo?)."
    fi
    err ""
    err "Fail-closed: no se instala un binario sin verificar. Opciones:"
    err "  1. Agregá el hash a sha256.txt (instrucciones dentro del archivo)."
    err "  2. Instalá una version registrada: -v 1.18.9"
    err "  3. Pineá el hash a mano: --sha256 <sha256-del-tarball>"
    exit 1
  fi
  if [[ ! "$EXPECTED_SHA" =~ ^[0-9a-f]{64}$ ]]; then
    err "El SHA256 esperado para $TAG no es un hash valido: '$EXPECTED_SHA'"
    exit 1
  fi
}

check_current() {
  [[ "$REINSTALL" == true ]] && return 0

  local installed
  installed=$(normalize_version "$(manifest_get version)")

  # Si no hay manifest (instalacion vieja), caemos al wrapper.
  if [[ -z "$installed" && -x "$WRAPPER" ]]; then
    installed=$(normalize_version "$("$WRAPPER" --version 2>/dev/null || true)")
  fi

  if [[ -n "$installed" && "$installed" == "$VERSION" && -x "$BIN_FILE" && -x "$WRAPPER" ]]; then
    info "OpenCode $VERSION ya esta instalado. Usá -r para reinstalar."
    exit 0
  fi
  [[ -n "$installed" ]] && info "Version instalada: $installed -> actualizando a $VERSION"
  return 0
}

install_deps() {
  info "Actualizando repositorios e instalando dependencias..."
  pkg update -y >/dev/null 2>&1 || warn "pkg update fallo; continuando con los indices actuales."
  if ! pkg install glibc-repo glibc-runner patchelf file jq curl -y; then
    err "Fallo la instalacion de dependencias."
    err "Verificá que Termux este actualizado: pkg update && pkg upgrade"
    exit 1
  fi
  if [[ ! -f "$LOADER" ]]; then
    err "Loader glibc no encontrado en $LOADER"
    err "Ejecutá: pkg install glibc-repo glibc-runner"
    exit 1
  fi
  info "Loader glibc: $LOADER"
}

download() {
  local url="https://github.com/$REPO/releases/download/$TAG/$ARCHIVE_NAME"
  local tmp_dir="${TMPDIR:-$PREFIX/tmp}"
  mkdir -p "$tmp_dir"
  # mktemp evita nombres predecibles en el directorio temporal.
  TMP_FILE=$(mktemp "$tmp_dir/opencode-install-XXXXXX.tar.gz")

  info "Descargando $ARCHIVE_NAME ($TAG)..."
  if ! curl -fL --proto '=https' --tlsv1.2 -o "$TMP_FILE" "$url"; then
    err "Fallo la descarga desde $url"
    err "Verificá que el tag $TAG exista y tenga el asset $ARCHIVE_NAME."
    exit 1
  fi
}

verify_tarball() {
  TARBALL_SHA=$(sha_of "$TMP_FILE")
  if [[ "$TARBALL_SHA" != "$EXPECTED_SHA" ]]; then
    err "SHA256 MISMATCH del tarball!"
    err "  Esperado: $EXPECTED_SHA"
    err "  Obtenido: $TARBALL_SHA"
    err "  Asset:    $ARCHIVE_NAME ($TAG)"
    err "No se instala nada. Si la release fue re-publicada legitimamente,"
    err "actualizá sha256.txt tras verificar la attestation de GitHub."
    exit 1
  fi
  info "SHA256 del tarball verificado: $TARBALL_SHA"

  if ! file "$TMP_FILE" 2>/dev/null | grep -qi 'gzip compressed'; then
    err "El archivo descargado no es un tarball gzip:"
    file "$TMP_FILE" >&2 || true
    exit 1
  fi
}

# La attestation de GitHub cubre el TARBALL, no el binario extraido ni el
# parcheado. Y es de tipo release (in-toto release/v0.2), no SLSA provenance,
# asi que hay que pasar --predicate-type explicitamente.
verify_attestation() {
  ATTEST_STATUS="omitida"
  if ! command -v gh >/dev/null 2>&1; then
    if [[ "$REQUIRE_ATTEST" == true ]]; then
      err "--require-attestation pero gh no esta instalado: pkg install gh"
      exit 1
    fi
    info "gh no instalado: se omite la attestation (pkg install gh para habilitarla)."
    return 0
  fi

  info "Verificando la release attestation firmada por GitHub..."
  local out
  if out=$(gh attestation verify "$TMP_FILE" \
             --repo "$REPO" \
             --predicate-type "$RELEASE_PREDICATE" 2>&1); then
    ATTEST_STATUS="verificada"
    info "Attestation valida: el tarball fue publicado por $REPO."
    return 0
  fi

  ATTEST_STATUS="fallida"
  if [[ "$REQUIRE_ATTEST" == true ]]; then
    err "Fallo la verificacion de la attestation:"
    printf '%s\n' "$out" >&2
    exit 1
  fi
  warn "No se pudo verificar la attestation (¿gh sin autenticar? ¿sin red?)."
  warn "El SHA256 pineado ya fue verificado, asi que se continua."
  warn "Detalle: $(printf '%s' "$out" | head -1)"
}

extract_install() {
  local tmp_dir="${TMPDIR:-$PREFIX/tmp}"
  EXTRACT_DIR=$(mktemp -d "$tmp_dir/opencode-extract-XXXXXX")
  tar -xzf "$TMP_FILE" -C "$EXTRACT_DIR"
  rm -f "$TMP_FILE"; TMP_FILE=""

  # Elegir el binario ELF ejecutable, no cualquier archivo llamado opencode.
  local found=""
  local cand
  while IFS= read -r cand; do
    if file "$cand" 2>/dev/null | grep -qi 'ELF 64-bit.*ARM aarch64'; then
      found="$cand"; break
    fi
  done < <(find "$EXTRACT_DIR" -type f -name "$APP" 2>/dev/null)

  if [[ -z "$found" ]]; then
    err "No se encontro un binario ELF aarch64 llamado '$APP' en el tarball."
    err "Contenido:"
    find "$EXTRACT_DIR" -type f 2>/dev/null | head -20 >&2
    exit 1
  fi

  BIN_SHA_ORIG=$(sha_of "$found")
  info "Binario localizado (sha256 original: ${BIN_SHA_ORIG:0:16}...)"

  # Respaldar la instalacion previa para poder revertir si algo falla.
  if [[ -d "$LIBEXEC_DIR" ]]; then
    BACKUP_DIR="$(dirname "$LIBEXEC_DIR")/.$APP.backup.$$"
    rm -rf "$BACKUP_DIR"
    mv "$LIBEXEC_DIR" "$BACKUP_DIR"
  else
    FRESH_INSTALL=true
  fi

  mkdir -p "$LIBEXEC_DIR"
  # Copiar todo el contenido del tarball, no solo el binario, para soportar
  # releases futuras que incluyan archivos de soporte.
  local root="$found"
  root=$(dirname "$found")
  cp -a "$root/." "$LIBEXEC_DIR/"
  # Reubicar el binario si venia en un subdirectorio.
  if [[ ! -f "$BIN_FILE" ]]; then
    cp -a "$found" "$BIN_FILE"
  fi
  chmod 755 "$BIN_FILE"
  rm -rf "$EXTRACT_DIR"; EXTRACT_DIR=""

  info "Binario instalado en $BIN_FILE"
}

patch_interpreter() {
  info "Aplicando patchelf (interpreter y rpath -> overlay glibc)..."
  if ! patchelf --set-interpreter "$LOADER" --set-rpath "$RPATH" "$BIN_FILE"; then
    err "Fallo patchelf sobre $BIN_FILE"
    exit 1
  fi

  local got_interp got_rpath
  got_interp=$(patchelf --print-interpreter "$BIN_FILE" 2>/dev/null || true)
  got_rpath=$(patchelf --print-rpath "$BIN_FILE" 2>/dev/null || true)
  if [[ "$got_interp" != "$LOADER" ]]; then
    err "patchelf no aplico el interpreter correctamente."
    err "  Esperado: $LOADER"
    err "  Obtenido: ${got_interp:-<vacio>}"
    exit 1
  fi
  if [[ "$got_rpath" != *"$RPATH"* ]]; then
    err "patchelf no aplico el rpath correctamente."
    err "  Esperado contener: $RPATH"
    err "  Obtenido: ${got_rpath:-<vacio>}"
    exit 1
  fi
  BIN_SHA_PATCHED=$(sha_of "$BIN_FILE")
  info "Interpreter y rpath verificados."
}

# nsswitch.conf: glibc lo necesita para resolver DNS. Sin el, las peticiones
# de red de opencode pueden fallar en la resolucion de nombres.
ensure_nsswitch() {
  local ns="$GLIBC_PREFIX/etc/nsswitch.conf"
  if [[ -f "$ns" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$ns")"
  printf 'hosts: files dns\n' > "$ns"
  info "Creado $ns (resolucion DNS de glibc)."
}

create_wrapper() {
  mkdir -p "$(dirname "$WRAPPER")"
  cat > "$WRAPPER" <<WRAPPER_EOF
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BIN="$BIN_FILE"

if [[ ! -x "\$BIN" ]]; then
  echo "ERROR: opencode no encontrado en \$BIN" >&2
  echo "Reinstalá con: bash install.sh -r" >&2
  exit 1
fi

# libtermux-exec.so es bionic: precargarla en un proceso glibc lo crashea.
# Contrapartida: se pierde el hook de execve() que reescribe shebangs, asi que
# los scripts con shebang estandar (#!/bin/bash) fallan con ENOENT.
unset LD_PRELOAD
# LD_LIBRARY_PATH heredada apunta a librerias bionic -> segfault al enlazar.
unset LD_LIBRARY_PATH

exec "\$BIN" "\$@"
WRAPPER_EOF
  chmod 755 "$WRAPPER"
  info "Wrapper creado en $WRAPPER"
}

write_manifest() {
  cat > "$MANIFEST" <<EOF
# Generado por install.sh. No editar a mano.
# verify.sh compara el estado instalado contra estos valores.
manifest_version=1
app=$APP
repo=$REPO
version=$VERSION
tag=$TAG
archive=$ARCHIVE_NAME
tarball_sha256=$TARBALL_SHA
binary_sha256_original=$BIN_SHA_ORIG
binary_sha256_patched=$BIN_SHA_PATCHED
interpreter=$LOADER
rpath=$RPATH
attestation=$ATTEST_STATUS
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 644 "$MANIFEST"
  info "Manifest de integridad escrito en $MANIFEST"
}

verify_install() {
  info "Verificando la instalacion..."
  local out
  if ! out=$("$WRAPPER" --version 2>&1); then
    err "El wrapper no pudo ejecutar opencode."
    err "Salida: $(printf '%s' "$out" | head -3)"
    err "Probá cerrar y reabrir Termux, o revisá 'bash verify.sh'."
    exit 1
  fi
  local got
  got=$(normalize_version "$out")
  if [[ -n "$got" && "$got" != "$VERSION" ]]; then
    warn "La version reportada ($got) no coincide con la esperada ($VERSION)."
  fi
  INSTALL_DONE=true
  info "OpenCode ${got:-$VERSION} funcionando correctamente."
}

show_summary() {
  printf '\n'
  printf '%sOpenCode %s instalado en Termux (overlay glibc, sin proot)%s\n' "$GREEN" "$VERSION" "$NC"
  printf '\n'
  printf '%sIntegridad:%s\n' "$MUTED" "$NC"
  printf '  tarball sha256   %s\n' "$TARBALL_SHA"
  printf '  attestation      %s\n' "$ATTEST_STATUS"
  printf '\n'
  printf '%sUso:%s\n' "$MUTED" "$NC"
  printf '  %sopencode%s              %s# iniciar en el directorio actual%s\n' "$GREEN" "$NC" "$MUTED" "$NC"
  printf '  %s/connect%s              %s# conectar un provider la primera vez%s\n' "$GREEN" "$NC" "$MUTED" "$NC"
  printf '\n'
  printf '%sVerificar la instalacion:  bash verify.sh%s\n' "$MUTED" "$NC"
  printf '%sDocumentacion: https://opencode.ai/docs%s\n' "$MUTED" "$NC"
}

main() {
  preflight
  resolve_version
  resolve_expected_sha
  check_current
  install_deps
  download
  verify_tarball
  verify_attestation
  extract_install
  patch_interpreter
  ensure_nsswitch
  create_wrapper
  # El manifest se escribe DESPUES de comprobar que la instalacion funciona.
  # Si se escribiera antes, una instalacion fallida dejaria un manifest valido
  # y la proxima corrida la tomaria por buena ("ya esta instalado").
  verify_install
  write_manifest
  show_summary
}

main
