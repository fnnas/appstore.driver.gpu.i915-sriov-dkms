# Repository Guide

## Purpose

This repository packages `appstore.driver.gpu.i915-sriov-dkms` for the fnOS app store. It does not contain the upstream DKMS driver source. GitHub Actions clones `GreenDamTan/i915-sriov-dkms`, builds modules in fnOS kernel-header containers, and assembles the application package.

## Key Files

- `.github/workflows/test_release.yml`: release orchestration, package/upstream versions, kernel matrix, artifact assembly, and optional GitHub Release.
- `.github/workflows/kernel-build.yml`: reusable DKMS build workflow. Artifact names and payload directories are derived from `kernel_name`.
- `.github/workflows/get_firmware.yml`: fetches and uploads the pinned `linux-firmware/i915` tree.
- `i915-sriov-dkms_driver/cmd/main`: runtime kernel detection, payload selection, module/firmware installation, and diagnostics.
- `i915-sriov-dkms_driver/cmd/build_module_chroot`: optional on-device fallback build.
- `i915-sriov-dkms_driver/cmd/i18n.sh`: shared runtime message loader, including inside the chroot.
- `i915-sriov-dkms_driver/manifest`: app-store metadata and localized text references.
- `i915-sriov-dkms_driver/i18n/{zh,en}`: Chinese and English manifest, wizard, and runtime strings.
- `i915-sriov-dkms_driver/wizard/install`: selects prebuilt-only or fallback local-build mode.

## Change Rules

When adding kernel support:

1. Add a complete entry to the appropriate matrix in `test_release.yml`: `kernel_name`, `kernel_ver`, `container_image`, `target_commit_sha`, `target_dkms_version`, and `patch_mode`. `build_kernel` is for current kernels with a `.c<number>` suffix. All kernels without that suffix belong to the unsupported old-kernel matrix `build_old_kernels`, enabled only by the `build_old_kernels` input (default `false`).
2. Keep the generated payload name `${proj_name}_${kernel_name}` identical to the directory selected by `cmd/main`. For example, `kernel_name: 6.18.18.c1168-trim-amd64` produces `i915-sriov-dkms_6.18.18.c1168-trim-amd64`.
3. Update `cmd/main` when the new `uname -r` needs a dedicated prebuilt payload.
4. Update the kernel descriptions and changelog in both `i18n/zh` and `i18n/en`. Keep current and unsupported old kernels separate, and keep `manifest` text references intact.
5. Increment `this_pack_manifest_version` in `test_release.yml`.

When updating upstream DKMS or firmware, keep the related version and commit pins together in the `env` block. Preserve old-kernel matrix-specific overrides.

Keep `manifest` version as the literal build-time placeholder `this_pack_manifest_version`. Keep `arch="x86_64"` and `platform="x86"`. Command scripts must retain LF line endings.

Do not remove the packaged source staging or wizard/local-build path without updating `cmd/main`, `build_module_chroot`, the wizard, and manifest copy together.

## Localization

Maintain matching keys in `i18n/zh` and `i18n/en`: `[manifest]` for app information, `[wizard]` for installation UI, and `[runtime]` for script messages. Use `${section.key}` references in metadata and wizard files. Keep command names, paths, and kernel identifiers untranslated. Use `社区用户` in Chinese descriptions.

Runtime messages use `i915_message <key> [arguments...]` and `%s` placeholders. The release workflow copies both catalogs into `app/app/i18n/` for use under `${TRIM_APPDEST}/app/i18n/`; the loader can also read the source-tree catalogs. It prioritizes the documented `TRIM_SYS_LANGUAGE`, then standard locale variables, maps Chinese variants to `zh`, and otherwise falls back to `en`. Never source or evaluate translation files as shell code. Keep the chroot build connected to the same loader and resources.

Official references: [Manifest](https://developer.fnnas.com/docs/core-concepts/manifest/), [environment variables](https://developer.fnnas.com/docs/core-concepts/environment-variables/), and [wizard](https://developer.fnnas.com/docs/core-concepts/wizard/).

## Validation

There is no unit-test suite. After changing command scripts, run:

```bash
for script in i915-sriov-dkms_driver/cmd/*; do
  bash -n "$script" || exit 1
done
```

For workflow changes, run `actionlint` on the modified workflow. Always run `git diff --check` and verify that matrix `kernel_name`, runtime payload directory, and localized kernel descriptions agree. Check that both languages define every referenced key and use matching format placeholders.

When CI artifacts already exist under `app/app/`, a local package structure check can reuse:

```bash
cd app && tar zcvf app.tgz app ui && mv app.tgz ../i915-sriov-dkms_driver/
tar zcvf appstore.driver.gpu.i915-sriov-dkms-<version>-<commit>.tgz i915-sriov-dkms_driver
tar tzf appstore.driver.gpu.i915-sriov-dkms-<version>-<commit>.tgz
```

## Remote Actions

Do not trigger GitHub Actions or create/upload a Release unless explicitly requested. `make_release=false` builds and uploads an artifact; `make_release=true` also creates a prerelease.

Follow the existing commit style, such as `feat(driver): add support for <kernel>` or `ci(release): <change>`.

## Handoff and Commit Text

Every completed change and requested commit message must include:

1. A concise commit-style title.
2. A short overall description of the change.
3. A description for every changed file, using its actual repository path and the format `- <area> 修改：<description>`.

Use this structure:

```text
feat(driver): 适配 <kernel> 内核

新增目标内核的预构建模块支持，同步构建产物与运行时安装映射，并递增应用版本。

.github/workflows/test_release.yml
- 内核构建 修改：新增对应镜像的构建矩阵，同步升级应用版本。

i915-sriov-dkms_driver/cmd/main
- 模块映射 修改：为目标内核添加对应预构建模块目录的选择分支。
```
