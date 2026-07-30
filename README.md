# opencode-termux

Instalación **sin proot** de [OpenCode](https://opencode.ai) en **Termux** (Android aarch64), usando el overlay glibc del ecosistema Termux.

OpenCode se distribuye como binario **glibc**. Termux usa bionic libc. Para evitar virtualización (proot), se usa `glibc-runner` que provee el loader dinámico y las librerías glibc, más `patchelf` para cambiar el intérprete del ELF. El binario oficial corre directamente sobre el kernel Android, sin contenedores ni emulación.

```
Termux (bionic libc)
  └─ glibc overlay ($PREFIX/glibc/lib/ld-linux-aarch64.so.1 + libs)  ← capa de compatibilidad
       └─ opencode (binario oficial Linux ARM64, patchelf'd)
```

No es "nativo bionic" — es el binario oficial de Linux ejecutado sobre la capa glibc que provee Termux. Es un trade-off válido: evita proot, usa el binario sin modificar su código, pero depende de que el overlay glibc se mantenga compatible.

## Requisitos

- Android 10+ (aarch64)
- Termux desde F-Droid o GitHub (NO Google Play, está desactualizado)
- ~400 MB libres (el binario pesa ~170 MB y se descarga el tarball antes de extraer)

## Instalación

```bash
pkg install git -y
git clone https://github.com/Eybad/opencode-termux.git
cd opencode-termux
bash install.sh
```

> El repo debe clonarse completo: `install.sh` lee los hashes desde `sha256.txt`. Si ejecutás el script suelto, tenés que pinear el hash con `--sha256`.

**Qué hace exactamente:**

| Paso | Acción |
|---|---|
| 1 | Preflight: Termux, aarch64, y presencia de `curl`, `tar`, `sha256sum`, `awk` |
| 2 | Resuelve la versión (`-v`, o la última release vía GitHub API) |
| 3 | Busca el SHA256 del tarball en `sha256.txt` — **si no está, aborta antes de descargar** |
| 4 | `pkg install glibc-repo glibc-runner patchelf file jq curl -y` |
| 5 | Descarga `opencode-linux-arm64.tar.gz` y verifica su SHA256 |
| 6 | Verifica la release attestation firmada por GitHub (si `gh` está disponible) |
| 7 | Extrae, valida que sea ELF64 aarch64, e instala en `$PREFIX/libexec/opencode/` |
| 8 | `patchelf --set-interpreter … --set-rpath …` y verifica que se aplicó |
| 9 | Crea `$PREFIX/glibc/etc/nsswitch.conf` si falta (DNS de glibc) |
| 10 | Crea el wrapper en `$PREFIX/bin/opencode` |
| 11 | Comprueba que `opencode --version` funcione |
| 12 | Escribe `manifest.txt` con los hashes para auditoría posterior |

Si algo falla en los pasos 7–12, se **restaura automáticamente** la instalación anterior y se borran los temporales.

### Opciones

```bash
bash install.sh                        # última release (si tiene hash registrado)
bash install.sh -v 1.18.9              # versión específica
bash install.sh -r                     # forzar reinstalación
bash install.sh -u                     # desinstalar
bash install.sh --require-attestation  # abortar si no se puede verificar la firma de GitHub
bash install.sh --sha256 <hash>        # pinear el hash a mano (uso sin sha256.txt)
```

## Uso

```bash
opencode                  # iniciar en el directorio actual
opencode /ruta/proyecto   # abrir un proyecto
opencode --version
# Primera vez, dentro de opencode:  /connect
```

## Verificación

```bash
bash verify.sh
```

Comprueba presencia y permisos del binario, formato ELF64 aarch64, intérprete y rpath, **integridad del binario instalado**, coherencia entre el manifest y `sha256.txt`, estado de la attestation, que el wrapper limpie `LD_PRELOAD`/`LD_LIBRARY_PATH`, el loader glibc, `nsswitch.conf`, y la ejecución real. Sale con código 1 si hay fallos.

## Seguridad

### Modelo de integridad en dos capas

`patchelf` reescribe `PT_INTERP` y `DT_RUNPATH`, así que **los bytes del binario instalado cambian**. Existen tres hashes distintos para una misma versión, y confundirlos es un error fácil de cometer:

| Artefacto | SHA256 (v1.18.9) | ¿Tiene attestation? |
|---|---|---|
| Tarball del release | `b16bd759…` | **Sí** |
| Binario extraído | `ae8a9b7c…` | No |
| Binario tras `patchelf` | depende del prefix y del loader | No |

Por eso la verificación está separada en dos capas:

1. **En la instalación** (`install.sh`) se verifica el **tarball**: SHA256 pineado en `sha256.txt` (fail-closed) más la release attestation firmada por GitHub.
2. **Después de instalar** (`verify.sh`) se verifica el **binario ya parcheado** contra el hash registrado en `$PREFIX/libexec/opencode/manifest.txt`, lo que detecta modificaciones posteriores a la instalación.

### Verificar la attestation a mano

Las attestations de GitHub están ligadas al **digest del tarball**, no al binario extraído ni al parcheado. Verificar el binario instalado siempre falla con "no attestations found".

```bash
pkg install gh -y
gh auth login

# Descargar el tarball del release
curl -fLO https://github.com/anomalyco/opencode/releases/download/v1.18.9/opencode-linux-arm64.tar.gz

# Opción A (recomendada): comando específico para assets de release
gh release verify-asset v1.18.9 opencode-linux-arm64.tar.gz --repo anomalyco/opencode

# Opción B: verificación genérica de attestations
gh attestation verify opencode-linux-arm64.tar.gz \
  --repo anomalyco/opencode \
  --predicate-type https://in-toto.io/attestation/release/v0.2
```

En la opción B, `--predicate-type` es **obligatorio**: opencode publica una attestation de tipo release (`in-toto.io/attestation/release/v0.2`), mientras que `gh attestation verify` exige por defecto `slsa.dev/provenance/v1` y fallaría.

El hash de v1.18.9 en `sha256.txt` fue confirmado contra esa attestation, que lista `opencode-linux-arm64.tar.gz` con el digest `b16bd759…`.

### Alcance real de la protección

- El SHA256 pineado protege contra corrupción en tránsito y contra que el asset del release sea reemplazado después de que se registró el hash. Es un modelo TOFU: la confianza inicial viene de quien agregó el hash al repo.
- La attestation sí es verificación criptográfica (Sigstore/OIDC): prueba que el tarball salió de un workflow de GitHub Actions de `anomalyco/opencode`. Usá `--require-attestation` para exigirla.
- `install.sh` **no** puede validar la firma Sigstore por sí mismo (requiere `gh`). Sin `gh`, la garantía se reduce al hash pineado; el script lo informa explícitamente y lo registra en el manifest.

### patchelf

`--set-interpreter` y `--set-rpath` modifican `PT_INTERP` y `DT_RUNPATH` del ELF para apuntar al loader y librerías glibc de Termux. No se parchean instrucciones ni se altera la lógica del programa. Inspeccionable con `patchelf --print-interpreter` y `patchelf --print-rpath`.

**Fragilidad**: este enfoque te ata al loader glibc instalado y a su compatibilidad con el binario. Cuando el stack glibc de Termux se actualiza (versión de glibc, paths, estructura de librerías), el binario puede dejar de funcionar hasta reaplicar `patchelf`. En ese caso `verify.sh` va a reportar un cambio de hash: es esperable, no necesariamente un ataque. Reinstalá con `bash install.sh -r`.

## Actualización

```bash
bash install.sh -v <nueva-version>   # tras agregar su hash a sha256.txt
bash install.sh -r                   # reinstalar la versión actual
```

**Importante**: `bash install.sh` sin `-v` consulta la última release, pero el diseño es fail-closed. Si esa versión no tiene hash en `sha256.txt`, el script **aborta** en vez de instalarla. No hay auto-update silencioso: actualizar requiere registrar el hash de la versión nueva (las instrucciones están dentro de `sha256.txt`). Es deliberado — un auto-update sin verificación anularía el sentido del hash pineado.

## Desinstalación

```bash
bash install.sh -u
# o manual:
rm -rf $PREFIX/libexec/opencode
rm -f $PREFIX/bin/opencode
# Opcional: pkg remove glibc-runner patchelf glibc-repo file
```

## Limitaciones conocidas

### 1. Shebangs rotos en procesos hijos (por `unset LD_PRELOAD`)

El wrapper hace `unset LD_PRELOAD` antes de ejecutar opencode (necesario: `libtermux-exec.so` es bionic y crashea procesos glibc). Eso desactiva el interceptor de `execve()` que reescribe shebangs.

No es un problema de W^X. `termux-exec` intercepta `execve()` para reescribir shebangs estándar (`#!/bin/bash`, `#!/usr/bin/env node`) hacia las rutas absolutas de Termux. Sin `LD_PRELOAD`, cualquier script con shebang estándar que opencode intente ejecutar como hijo falla con `ENOENT`, porque rutas como `/bin/bash` no existen en Android.

**Mitigaciones**:
- opencode ejecuta comandos vía `bash -c "comando"`; `bash` es un ELF en Termux, no un script. Funciona.
- Herramientas ELF como `git`, `node`, `rg` funcionan (no dependen de shebang).
- Si opencode ejecuta un script inline o un hook de git con shebang estándar, va a fallar. Solución: `termux-fix-shebang` sobre esos scripts.

### 2. Colisión de `LD_LIBRARY_PATH`

Una `LD_LIBRARY_PATH` heredada apuntando a librerías bionic provoca segfaults al enlazar contra glibc. El wrapper hace `unset LD_LIBRARY_PATH`. Si un subproceso necesita rutas propias, definilas dentro de ese subproceso.

### 3. DNS

glibc resuelve nombres vía `nsswitch.conf`. `install.sh` crea `$PREFIX/glibc/etc/nsswitch.conf` con `hosts: files dns` si no existe. Si tenés problemas de resolución, confirmá que el archivo esté presente.

## Por qué no otras alternativas

| Alternativa | Problema |
|---|---|
| **proot-distro** | Virtualización completa, overhead de filesystem, innecesario |
| **npm i -g opencode-ai** | El paquete npm descarga el mismo binario glibc. Mismo problema de base |
| **Build musl (`opencode-linux-arm64-musl.tar.gz`)** | Parecía evitar glibc, pero **también es dinámico**: requiere `ld-musl-aarch64.so.1`, `libstdc++.so.6` y `libgcc_s.so.1`, que Termux no provee. No simplifica nada |
| **Compilar Bun + opencode para Android** | Extremadamente complejo (NDK, decenas de parches), mantenimiento continuo |
| **Fork con builds bionic nativos** | `guysoft/opencode-termux` existe, pero con releases desactualizados |
| **`opencode-ai/opencode` (proyecto Go distinto)** | Otro proyecto homónimo en Go, sin relación con `anomalyco/opencode`. Ambos publican un binario `opencode`; verificá que el repo sea `anomalyco/opencode` (ex-`sst/opencode`) |

## Referencias

- [OpenCode GitHub](https://github.com/anomalyco/opencode)
- [OpenCode Docs](https://opencode.ai/docs)
- [glibc-packages de Termux](https://github.com/termux/glibc-packages)
- [glibc-runner (grun)](https://github.com/termux-pacman/glibc-packages/wiki/About-glibc-runner-(grun))
- [GitHub Artifact Attestations](https://docs.github.com/en/actions/security-guides/using-artifact-attestations)
- [gh release verify-asset](https://cli.github.com/manual/gh_release_verify-asset)
- [Termux-exec — reescritura de shebangs](https://wiki.termux.com/wiki/Termux-exec)
