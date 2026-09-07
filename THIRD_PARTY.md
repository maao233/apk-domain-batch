# Third-party / redistribution compliance

This document records what may be shipped in this repository and what must not.

## Included in git (OK with notices)

### Android platform-tools (`tools/platform-tools/`)

- **What**: Google Android SDK Platform-Tools (adb, etc.), Windows build, Pkg.Revision 37.0.1
- **License**: Primarily Apache License 2.0 (see `tools/platform-tools/NOTICE.txt`)
- **Redistribution**: Allowed under Apache-2.0 when NOTICE and license terms are preserved
- **Action**: Keep `NOTICE.txt` and `source.properties` in the tree; do not strip copyright notices

### CaptureCli (`assets/CaptureCli.apk`)

- **What**: Project-built Android app `com.capturecli` for UID-based transparent proxy to host mitmproxy
- **Embedded binary**: `assets/gost` inside the APK (~go-gost / gost client)
- **gost license**: Typically MIT / Apache-2.0 family for go-gost projects — attribute in README; provide upstream link
- **Upstream (gost)**: https://github.com/go-gost/gost
- **Action**: Ship APK as an analysis helper; source for CaptureCli Java lives with the author (link in README if published separately)

### Skill scripts (`scripts/*.ps1`, `android_ca_hash.py`)

- **License**: MIT (see root `LICENSE`)
- Original workflow automation for this skill

## NOT included in git (do not upload)

### Magisk / Kitsune APK (`assets/Magisk.apk`)

| Issue | Detail |
|-------|--------|
| Package seen in lab | `io.github.huskydg.magisk` versionName `R6687BB53-kitsune` (Kitsune / Magisk Delta-style fork) |
| Base project | Magisk by topjohnwu — **GPL-3.0** |
| Problem | Shipping third-party Magisk **binaries** without corresponding GPL source offer is non-compliant; unofficial forks also discourage random mirrors |
| Risk | Copyright / GPL violation; malware risk from unofficial mirrors |

**Policy for this repo:**

1. **Do not commit** `assets/Magisk.apk`
2. Users obtain Magisk themselves:
   - **Official Magisk (recommended for compliance):** https://github.com/topjohnwu/Magisk/releases  
   - **Kitsune Mask (unofficial fork):** only from the maintainer’s official channel (historically HuskyDG Telegram / archived kitsune releases). Use at your own risk; not Magisk-supported.
3. Place downloaded APK as `assets/Magisk.apk` locally, or pass path to setup scripts
4. Emulator image must already support Magisk/root; the manager APK alone does not root a stock image

### mitmproxy

- Not bundled (Python version/wheel issues)
- Install via `pip install mitmproxy` — see README / SKILL.md

## Forensic / legal use note

This skill is for **authorized** lab / CTF / course analysis on devices and APKs you are allowed to test. Do not use against systems without permission.

## Checklist before `git push`

- [ ] `assets/Magisk.apk` is gitignored and not staged
- [ ] `tools/platform-tools/NOTICE.txt` present
- [ ] `THIRD_PARTY.md` (this file) and `LICENSE` present
- [ ] README states Magisk must be downloaded by the user
- [ ] No machine-specific absolute paths required to run (skill-relative paths only)
