# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目定位

这个仓库是飞牛应用商店包 `appstore.driver.gpu.i915-sriov-dkms` 的包装仓库，不包含完整的 i915 SR-IOV DKMS 内核源码。实际 DKMS 源码在 GitHub Actions 中从 `GreenDamTan/i915-sriov-dkms` 克隆，按指定提交和版本在对应飞牛内核头容器里构建 `.ko` 产物；本仓库负责保存应用商店元数据、安装/卸载脚本、发布工作流，以及把 CI 产物组装成最终应用包。

## 常用命令

### 脚本语法检查

仓库没有配置单元测试框架或专用 lint 配置。修改 `i915-sriov-dkms_driver/cmd/*` 后，至少运行 Bash 语法检查：

```bash
for script in i915-sriov-dkms_driver/cmd/*; do
  bash -n "$script" || exit 1
done
```

检查单个脚本时，例如：

```bash
bash -n i915-sriov-dkms_driver/cmd/main
```

### 本地打包结构检查

当 `app/app/` 下已经放好 kernel artifact、firmware artifact 和 `i915-sriov-dkms-source/` 上游源码目录后，可以复用发布工作流里的打包步骤：

```bash
cd app && tar zcvf app.tgz app ui && mv app.tgz ../i915-sriov-dkms_driver/
tar zcvf appstore.driver.gpu.i915-sriov-dkms-<版本>-<DKMS提交>.tgz i915-sriov-dkms_driver
```

检查最终包内容：

```bash
tar tzf appstore.driver.gpu.i915-sriov-dkms-<版本>-<DKMS提交>.tgz
```

### CI 构建与发布

主入口工作流是 `.github/workflows/test_release.yml`，通过 `workflow_dispatch` 触发。默认仅构建版本号带 `.c数字` 的当前内核；所有不带该后缀的内核均归档到已放弃支持的旧内核矩阵，仅在 `build_old_kernels=true` 时额外构建。工作流还会获取 firmware、暂存上游 DKMS 源码，并组装 `app.tgz` 和最终外层包。`make_release=false` 只上传 artifact，不创建 GitHub Release。`enable_ccache` 默认开启；传 `false` 时会跳过 ccache 的恢复、安装、统计和保存步骤。

```bash
gh workflow run test_release.yml -f make_release=false
```

需要发布预发布版本时才使用：

```bash
gh workflow run test_release.yml -f make_release=true
```

注意：触发 GitHub Actions 或创建 Release 会影响远端仓库状态；除非用户明确要求，否则不要代替用户执行这些命令。

## 构建流水线架构

`.github/workflows/test_release.yml` 是编排入口，关键版本变量集中在 `env` 中：

- `target_dkms_version`：传给 `dkms install i915-sriov-dkms/<version>` 的 DKMS 版本。
- `target_commit_sha`：构建新内核产物时检出的 `GreenDamTan/i915-sriov-dkms` 提交。
- `linux_firmware_commit_sha`：从 `kernel-firmware/linux-firmware` 取 `i915/` firmware 的提交。
- `this_pack_manifest_version`：打包前写入 `i915-sriov-dkms_driver/manifest`，同时作为最终外层应用包文件名和 Release tag 使用的版本。

`i915-sriov-dkms_driver/manifest` 中的 `arch` 是飞牛已废弃字段，按文档固定保留为 `x86_64`；`platform` 是当前架构声明字段，本项目为 x86 应用，固定为 `x86`。

`.github/workflows/kernel-build.yml` 是唯一的内核构建 reusable workflow。`test_release.yml` 中的 `build_kernel` 保存默认构建的 `.c数字` 当前内核矩阵，`build_old_kernels` 保存由同名输入控制的旧内核矩阵，包括 `6.18.18-trim` 的 `427`、`570`、`587`、`717` 及更早内核。每个条目都要完整声明 `container_image`、`kernel_name`、`kernel_ver`、`target_commit_sha`、`target_dkms_version` 和 `patch_mode`。旧内核的固定提交、固定 DKMS 版本，以及 `6.6.38` 的 `legacy_6_6_38` patch 模式应保留在旧内核矩阵中。

`kernel-build.yml` 在 `makedie/fnos:kernHead-...` 容器中克隆 DKMS 源码、检出矩阵传入的提交、按需应用旧内核 patch、执行 DKMS 构建，然后把 `/lib/modules/<kernel>/updates/dkms/*` 复制成 artifact。`test_release.yml` 的 `workflow_dispatch` 提供中文布尔输入 `enable_ccache`，默认开启；关闭时会跳过 ccache 的恢复、安装、统计和保存步骤。开启时，每个内核矩阵项会使用独立的 ccache 目录，并显式执行 restore/save：恢复时按 `kernel_name` 维度尽量复用最近缓存，保存时用当前 workflow run 的唯一 key 回写新缓存。编译器 wrapper 会按 PATH 自动发现 `gcc`、`g++`、`cc`、`c++` 以及任意 triplet 前缀的 `*-gcc` / `*-g++`，不写死 `x86_64-linux-gnu-*`。artifact 名称由 `${proj_name}-${kernel_name}` 合成，artifact 内部目录由 `${proj_name}_${kernel_name}` 合成；这些命名规则必须和 `cmd/main` 的运行时路径保持一致。

`get_firmware.yml` 按 `linux_firmware_commit_sha` 缓存最终的 `linux-firmware/i915/` 目录。命中缓存时直接上传 firmware artifact；未命中时使用 partial clone 和 sparse checkout，仅检出 `i915/` 后写入新缓存，避免下载无关固件内容。`test_release.yml` 等待 firmware、默认内核矩阵和按需启用的旧内核矩阵完成后，单独下载 firmware 到 `app/app/firmware`，再用 `${proj_name}-6*` pattern 和 `merge-multiple: true` 将所有内核 artifact 合并下载到 `app/app/`，然后执行：

1. 从 `target_commit_sha` 导出上游 DKMS 源码到 `app/app/i915-sriov-dkms-source/`，供安装向导选择本机 chroot 编译时使用。
2. 用 `sed` 替换 `i915-sriov-dkms_driver/manifest` 中的 `this_pack_manifest_version` 占位符。`manifest` 不展示单个 `target_commit_sha`，因为一次打包会包含多个来源提交。
3. 在 `app/` 下生成内部 `app.tgz`，内容为运行时的 `app/` 和 `ui/`。
4. 把 `app.tgz` 移到 `i915-sriov-dkms_driver/`。
5. 将整个 `i915-sriov-dkms_driver/` 打成最终 `.tgz.fpk` 应用商店包。

## 运行时安装架构

`i915-sriov-dkms_driver/manifest` 定义飞牛应用商店元数据、版本、显示名、维护者、最低系统版本和安装类型，显示名、描述和更新日志通过 `${manifest.key}` 引用中英文语言资源。`config/privilege` 指定默认以 root 运行；`config/resource` 当前只声明空的 `systemd-unit` 配置。

`i915-sriov-dkms_driver/cmd/main` 是运行时核心脚本：

- `start` 分支读取 `uname -r` 和 `uname -v` 中的构建号，根据显式映射或内核同名目录选择预构建模块。
- 找不到预构建模块且安装向导选择 `allow_local_build` 时，调用 `build_module_chroot` 使用包内上游源码构建当前内核模块；锁文件会阻止失败或中断后的自动重试。
- 将选中的模块复制到 `/lib/modules/<kernel>/updates/dkms/i915-sriov-dkms/`。
- 复制 `${TRIM_APPDEST}/app/firmware/*` 到 `/usr/lib/firmware/i915/`。
- 执行 `depmod`，在 `grub-mkconfig -o /dev/null` 成功时执行 `update-initramfs -u`。
- 尝试卸载并重新加载 `i915`，然后重启 `mediasrv.service` 和 `resmon_service.service`。
- 输出 `/proc/cmdline`、i915 相关 `dmesg` 和 GPU PCI 信息，便于用户反馈问题。
- `status` 分支检查当前内核的 `/lib/modules/$(uname -r)/updates/dkms/i915-sriov-dkms` 是否存在；不存在时输出诊断并返回 `3`。

`uninstall_init` 和 `upgrade_init` 会移除 chroot 构建锁，删除 `/lib/modules/*/updates/dkms/i915-sriov-dkms` 下所有已安装的本包模块并执行 `depmod`。`install_init`、`install_callback`、`uninstall_callback`、`upgrade_callback` 当前只记录调用日志。

## 支持内核与产物映射

默认打包的当前内核为带 `.c数字` 后缀的版本；不带该后缀的内核已放弃支持，仅保留可选归档构建和现有运行时映射。运行时选择逻辑以 `cmd/main` 为准：

- `6.12.5-trim`：构建号小于等于 9 不支持；构建号大于等于 10 时使用 `app/i915-sriov-dkms_6.12.5-trim_10/`。
- `6.12.18-trim`：使用 `app/i915-sriov-dkms_6.12.18-trim_3/`。
- `6.18.6-trim`：使用 `app/i915-sriov-dkms_6.18.6-trim-297-amd64/`。
- `6.18.18-trim`：构建号小于 570 使用 `427` 产物；小于 587 使用 `570` 产物；小于 717 使用 `587` 产物；大于等于 717 使用 `717` 产物。
- 显式列出的 `6.18.18.cXXX-trim` 内核使用同版本的 `i915-sriov-dkms_6.18.18.cXXX-trim-amd64/` 产物；准确列表以 `cmd/main` 和 `build_kernel` 矩阵为准。
- 其他内核默认查找 `app/i915-sriov-dkms_<uname -r>/`；缺少该目录时仅在用户允许的情况下尝试本机 chroot 编译。

启用旧内核矩阵时，发布工作流仍会构建并打包 `6.6.38-trim_92` artifact；但 `cmd/main` 没有对应的显式映射，默认查找的 `i915-sriov-dkms_6.6.38-trim` 与 artifact 目录名不一致，因此运行时不会自动选择该预构建产物。修改支持矩阵时，要同时检查 `cmd/main`、中英文语言资源中的内核描述和 `.github/workflows/test_release.yml` 的矩阵、依赖及下载规则。

## 中英文国际化

`i915-sriov-dkms_driver/i18n/zh` 和 `i18n/en` 必须维护相同的节和键：`[manifest]` 保存显示名、应用描述和更新日志；`[wizard]` 保存安装向导文案；`[runtime]` 保存运行时及本机编译提示。元数据和向导使用 `${section.key}` 引用。中文说明统一使用“社区用户”，命令、路径和内核标识保持原样。

发布工作流将两份语言资源复制到 `app/app/i18n/`，安装后通过 `${TRIM_APPDEST}/app/i18n/` 访问；源码目录下也可直接读取包根目录中的资源。`cmd/i18n.sh` 将语言文件作为数据读取，禁止 `source` 或 `eval` 语言文件。运行时优先读取官方提供的 `TRIM_SYS_LANGUAGE`，缺失时依次读取 `LC_ALL`、`LC_MESSAGES`、`LANG`；中文语言变体使用 `zh`，其他语言回退到 `en`。脚本通过 `i915_message <key> [参数...]` 输出文本，动态值使用 `%s`，中英文占位符数量和顺序必须一致。`build_module_chroot` 在宿主和 chroot 内均使用该加载器。第三方工具的原始诊断输出保留原样。

官方参考：[Manifest](https://developer.fnnas.com/docs/core-concepts/manifest/)、[环境变量](https://developer.fnnas.com/docs/core-concepts/environment-variables/)、[用户向导](https://developer.fnnas.com/docs/core-concepts/wizard/)。

## 修改版本或上游 DKMS 时的注意点

更新上游 DKMS 版本时，通常需要同步修改 `.github/workflows/test_release.yml` 中的 `target_dkms_version`、`target_commit_sha`、必要的单独旧内核覆盖值，以及 `this_pack_manifest_version`。`manifest` 应保留版本构建期占位符和国际化引用，更新说明在 `i18n/zh`、`i18n/en` 中同步修改。

新增内核支持时，应在 `.github/workflows/test_release.yml` 的对应矩阵中增加完整条目；带 `.c数字` 后缀的版本进入默认矩阵，其他版本进入已放弃支持的旧内核矩阵。同步更新 `cmd/main` 的 payload 映射、中英文语言资源中的内核说明和更新日志，并递增 `this_pack_manifest_version`。`kernel-build.yml` 会按 `${proj_name}-${kernel_name}` 合成 artifact 名称，并按 `${proj_name}_${kernel_name}` 合成包内模块目录；新增条目的 `kernel_name` 必须能生成 `cmd/main` 运行时会查找的目录名，否则应用安装时会找不到已打包的模块产物。

## 交付与 Commit 文案格式

每次完成修改或提供 commit 文案时，必须依次包含：

1. 简洁的 commit 风格标题。
2. 本次改动的整体内容描述。
3. 每个已修改文件的独立描述，使用仓库真实路径，格式为 `- <改动领域> 修改：<具体内容>`。

使用以下结构：

```text
feat(driver): 适配 <kernel> 内核

新增目标内核的预构建模块支持，同步构建产物与运行时安装映射，并递增应用版本。

.github/workflows/test_release.yml
- 内核构建 修改：新增对应镜像的构建矩阵，同步升级应用版本。

i915-sriov-dkms_driver/cmd/main
- 模块映射 修改：为目标内核添加对应预构建模块目录的选择分支。
```
