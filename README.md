# termux-opencode

Instalación **sin proot** de [OpenCode](https://opencode.ai) en **Termux** (Android aarch64), usando el overlay glibc oficial del ecosistema Termux.

OpenCode se distribuye como binario **glibc**. Termux usa bionic libc. Para evitar virtualización (proot), se usa `glibc-runner` que provee el loader dinámico y librerías glibc, más `patchelf` para cambiar el intérprete del ELF. El binario oficial corre directamente sobre el kernel Android, sin contenedores ni emulación.

```
Termux (bionic libc)
  └─ glibc overlay ($PREFIX/glibc/lib/ld-linux-aarch64.so.1 + libs)  ← capa de compatibilidad
       └─ opencode (binario oficial Linux ARM64, patchelf'd)
```

No es "nativo bionic" — es el binario oficial de Linux ejecutado sobre la capa glibc que provee Termux. Es un trade-off válido: evita proot, usa el binario sin modificar, pero depende de que el overlay glibc se mantenga compatible.

## Requisitos

- Android 10+ (aarch64)
- Termux desde F-Droid o GitHub (NO Google Play, está desactualizado)
- ~300 MB libres

## Instalación

```bash
# 1. Bajá el proyecto
pkg install git -y
git clone https://github.com/tu-user/termux-opencode.git
cd termux-opencode

# 2. Ejecutá el instalador
bash install.sh
```

**Qué hace exactamente:**

| Paso | Acción |
|---|---|
| 1 | `pkg update && pkg install glibc-repo glibc-runner patchelf file jq -y` |
| 2 | Descarga `opencode-linux-arm64.tar.gz` de GitHub Releases |
| 3 | Extrae binario a `$PREFIX/libexec/opencode/opencode` |
| 4 | `patchelf --set-interpreter $GLIBC_PREFIX/lib/ld-linux-aarch64.so.1 --set-rpath $GLIBC_PREFIX/lib` |
| 5 | Crea wrapper en `$PREFIX/bin/opencode` (ya en PATH) |
| 6 | Verifica que `opencode --version` funcione |

## Uso

```bash
# Iniciar opencode en el directorio actual
opencode

# Abrir un proyecto específico
opencode /ruta/al/proyecto

# Primera vez: conectar un provider
# Dentro de opencode: /connect

# Ver versión
opencode --version
```

## Seguridad

### Método principal: GitHub Release Attestations

OpenCode publica sus releases con **artifact attestations** firmadas via Sigstore/GitHub OIDC. Este es el mecanismo correcto para verificar que el binario fue construido por GitHub Actions y no fue manipulado.

```bash
# Instalar gh (GitHub CLI) en Termux
pkg install gh -y

# Descargar la attestation del release
gh release download -R anomalyco/opencode -p "*.json" -D /tmp/attest

# Verificar el binario instalado contra la attestation
gh attestation verify $PREFIX/libexec/opencode/opencode \
  --owner anomalyco \
  --digest sha256:$(sha256sum $PREFIX/libexec/opencode/opencode | cut -d' ' -f1)
```

El comando `gh attestation verify` valida que el binario fue emitido por el repositorio `anomalyco/opencode` y que el hash coincide con el release oficial.

Para más información: [GitHub Artifact Attestations](https://docs.github.com/en/actions/security-guides/using-artifact-attestations)

### Verificación opcional: SHA256

Los scripts `install.sh` y `verify.sh` incluyen una lista de SHA256 conocidos como verificación adicional durante la descarga. **Fail-closed**: si la versión a instalar no tiene un hash registrado en `SHA256_ASSETS`, el script se detiene con error y no ejecuta el binario no verificado.

```
SHA256 (v1.18.9) = b16bd7593ea960a25d9c6849b3023bcd9b9244a6f51675341fd2052043b0670f
```

Este hash se obtuvo descargando el asset desde la API de GitHub y calculando `sha256sum` localmente. Podés verificarlo desde la [página de releases oficial](https://github.com/anomalyco/opencode/releases/tag/v1.18.9): expandí "Show all assets" (los assets del CLI están detrás de un toggle JS) y buscá el SHA256 listado junto a `opencode-linux-arm64.tar.gz`.

> **Nota**: el hash en este script no es una prueba de confianza contra un atacante que controle el repo. Para verificación criptográfica robusta, usá `gh attestation verify` como se explica arriba (`gh` verifica la firma Sigstore/OIDC del workflow de GitHub Actions).

### patchelf y fragilidad del stack glibc

`patchelf --set-interpreter` y `--set-rpath` modifican respectivamente el campo `PT_INTERP` (loader dinámico) y `DT_RUNPATH` (ruta de librerías) del ELF para apuntar al loader y librerías glibc de Termux. No se altera el contenido del binario ni se parchean instrucciones. Se puede inspeccionar con `patchelf --print-interpreter` y `patchelf --print-rpath`.

**Nota de fragilidad**: este enfoque te ata al loader glibc instalado (`$PREFIX/glibc/lib/ld-linux-aarch64.so.1`) y a su compatibilidad exacta con el binario. Cuando el stack glibc de Termux se actualiza (cambio de versión de glibc, paths, o estructura de librerías), el binario puede dejar de funcionar hasta reaplicar `patchelf` o reinstalar. Esto es inherente al modelo de compatibilidad glibc-on-Termux.

## Actualización

```bash
bash install.sh       # detecta versión nueva si la hay
bash install.sh -r    # forzar reinstalación
```

## Desinstalación

```bash
bash install.sh -u
# o manual:
rm -rf $PREFIX/libexec/opencode
rm -f $PREFIX/bin/opencode
# Opcional: pkg remove glibc-runner patchelf glibc-repo file
```

## Limitaciones conocidas

### 1. Shebangs rotos en procesos hijos (por unset LD_PRELOAD)

El wrapper hace `unset LD_PRELOAD` antes de ejecutar opencode (necesario: `libtermux-exec.so` es bionic y crashea procesos glibc). Esto desactiva el interceptor de `execve()` que reescribe shebangs.

**Problema real**: no es W^X. `termux-exec` intercepta `execve()` para reescribir shebangs estándar (`#!/bin/bash`, `#!/usr/bin/env node`) hacia las rutas absolutas de Termux (`/data/data/com.termux/files/usr/bin/...`). Sin `LD_PRELOAD`, cualquier script con shebang estándar que opencode intente ejecutar como proceso hijo falla con `ENOENT` (No such file or directory), porque rutas como `/bin/bash` no existen en Android.

**Mitigaciones**:
- opencode ejecuta comandos via `bash -c "comando"` — bash es un binario ELF en Termux, no un script. Funciona.
- Herramientas ELF como `git`, `node`, `rg` también funcionan (no dependen de shebang).
- Si opencode ejecuta algún script inline, hook de git, o archivo con shebang estándar, va a fallar. La solución es parchear esos scripts con `termux-fix-shebang` previamente.

### 2. Colisión de LD_LIBRARY_PATH

Si el shell de Termux tiene `LD_LIBRARY_PATH` definida (apuntando a librerías bionic), y el wrapper no la limpia, los procesos hijos bionic de opencode podrían cargar librerías glibc, causando segfault o errores de enlazado. El wrapper hace `unset LD_LIBRARY_PATH` para evitarlo.

Si algún proceso hijo necesita rutas de librerías personalizadas, deben definirse explícitamente dentro de ese subproceso, no heredadas del wrapper.

### 3. DNS

glibc usa `nsswitch.conf`. Si tenés problemas de resolución DNS, copiá un `/etc/nsswitch.conf` básico a `$PREFIX/glibc/etc/`:

```
hosts: files dns
```

## Por qué no otras alternativas

| Alternativa | Problema |
|---|---|
| **proot-distro** | Virtualización completa, overhead de filesystem, no necesario |
| **npm i -g opencode-ai** | El paquete npm descarga el mismo binario glibc. Mismo problema de base |
| **Build Bun + opencode desde source para Android** | Extremadamente complejo (~60GB disco, NDK, 33+ parches), requiere mantenimiento continuo |
| **Fork opencode con builds bionic nativos** | guysoft/opencode-termux existe pero releases desactualizados |
| **`opencode-ai/opencode` (proyecto Go distinto)** | Existe otro proyecto homónimo en Go sin relación con `anomalyco/opencode`. Los mantenedores advierten la colisión de nombre. Verificá que el repo sea `anomalyco/opencode` o ex-`sst/opencode`. Ambos publican un binario `opencode` y son fáciles de confundir. |

## Referencias

- [OpenCode GitHub](https://github.com/anomalyco/opencode)
- [OpenCode Docs](https://opencode.ai/docs)
- [termux-glibc-packages](https://github.com/termux/glibc-packages)
- [glibc-runner (grun)](https://github.com/termux-pacman/glibc-packages/wiki/About-glibc-runner-(grun))
- [bun-on-termux (mismo principio)](https://github.com/tribixbite/bun-on-termux)
- [GitHub Artifact Attestations](https://docs.github.com/en/actions/security-guides/using-artifact-attestations)
- [Termux-exec - reescritura de shebangs](https://wiki.termux.com/wiki/Termux-exec)
