# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目定位

这个仓库是飞牛应用商店包 `appstore.driver.gpu.i915-sriov-dkms` 的包装仓库，不包含完整的 i915 SR-IOV DKMS 内核源码。实际 DKMS 源码在 GitHub Actions 中从 `GreenDamTan/i915-sriov-dkms` 克隆，按指定提交和版本在对应飞牛内核头容器里构建 `.ko` 产物；本仓库负责保存应用商店元数据、安装/卸载脚本、发布工作流，以及把 CI 产物组装成最终应用包。

## 常用命令

### 脚本语法检查

仓库没有配置单元测试框架或专用 lint 配置。修改 `i915-sriov-dkms_driver/cmd/*` 后，至少运行 Bash 语法检查：

```bash
bash -n i915-sriov-dkms_driver/cmd/main \
  i915-sriov-dkms_driver/cmd/install_init \
  i915-sriov-dkms_driver/cmd/install_callback \
  i915-sriov-dkms_driver/cmd/uninstall_init \
  i915-sriov-dkms_driver/cmd/uninstall_callback \
  i915-sriov-dkms_driver/cmd/upgrade_init \
  i915-sriov-dkms_driver/cmd/upgrade_callback
```

检查单个脚本时，例如：

```bash
bash -n i915-sriov-dkms_driver/cmd/main
```

### 本地打包结构检查

当 `app/app/` 下已经放好 CI 下载的 kernel artifact 和 firmware artifact 后，可以复用发布工作流里的打包步骤：

```bash
cd app && tar zcvf app.tgz app ui && mv app.tgz ../i915-sriov-dkms_driver/
tar zcvf appstore.driver.gpu.i915-sriov-dkms-<版本>-<DKMS提交>.tgz i915-sriov-dkms_driver
```

检查最终包内容：

```bash
tar tzf appstore.driver.gpu.i915-sriov-dkms-<版本>-<DKMS提交>.tgz
```

### CI 构建与发布

主入口工作流是 `.github/workflows/test_release.yml`，通过 `workflow_dispatch` 触发。它会构建所有内核产物、获取 firmware、组装 `app.tgz` 和最终外层包；`make_release=false` 只上传 artifact，不创建 GitHub Release。

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

各 `kernel-*.yml` 工作流在 `makedie/fnos:kernHead-...` 容器中执行 DKMS 构建，然后把 `/lib/modules/<kernel>/updates/dkms/*` 复制成 artifact。`get_firmware.yml` 克隆 linux-firmware 并上传 `i915/` 目录。`test_release.yml` 下载这些 artifact 到 `app/app/`，再执行：

1. 用 `sed` 替换 `i915-sriov-dkms_driver/manifest` 中的 `this_pack_manifest_version` 占位符。`manifest` 不展示单个 `target_commit_sha`，因为一次打包会包含多个来源提交。
2. 在 `app/` 下生成内部 `app.tgz`，内容为运行时的 `app/` 和 `ui/`。
3. 把 `app.tgz` 移到 `i915-sriov-dkms_driver/`。
4. 将整个 `i915-sriov-dkms_driver/` 打成最终应用商店包。

## 运行时安装架构

`i915-sriov-dkms_driver/manifest` 定义飞牛应用商店元数据、版本、显示名、维护者、最低系统版本、安装类型和描述。`config/privilege` 指定默认以 root 运行；`config/resource` 当前只声明空的 `systemd-unit` 配置。

`i915-sriov-dkms_driver/cmd/main` 是运行时核心脚本：

- `start` 分支读取 `uname -r` 和 `uname -v` 中的构建号，判断当前飞牛内核是否在支持列表内。
- 根据内核版本和构建号，从 `${TRIM_APPDEST}/app/` 选择对应的已构建模块目录，复制到 `/lib/modules/<kernel>/updates/dkms/i915-sriov-dkms/`。
- 复制 `${TRIM_APPDEST}/app/firmware/*` 到 `/usr/lib/firmware/i915/`。
- 执行 `depmod`，在 `grub-mkconfig -o /dev/null` 成功时执行 `update-initramfs -u`。
- 尝试卸载并重新加载 `i915`，然后重启 `mediasrv.service` 和 `resmon_service.service`。
- 输出 `/proc/cmdline`、i915 相关 `dmesg` 和 GPU PCI 信息，便于用户反馈问题。
- `status` 分支检查当前内核的 `/lib/modules/$(uname -r)/updates/dkms/i915-sriov-dkms` 是否存在；不存在时输出诊断并返回 `3`。

`uninstall_init` 和 `upgrade_init` 会删除当前内核下的 `updates/dkms/i915-sriov-dkms` 并执行 `depmod`。`install_init`、`install_callback`、`uninstall_callback`、`upgrade_callback` 当前只记录调用日志。

## 支持内核与产物映射

运行时选择逻辑以 `cmd/main` 为准：

- `6.12.5-trim`：构建号小于等于 9 不支持；构建号大于等于 10 时使用 `app/i915-sriov-dkms_6.12.5-trim_10/`。
- `6.12.18-trim`：使用 `app/i915-sriov-dkms_6.12.18-trim_3/`。
- `6.18.6-trim`：使用 `app/i915-sriov-dkms_6.18.6-trim-297-amd64/`。
- `6.18.18-trim`：构建号小于 570 使用 `427` 产物；小于 587 使用 `570` 产物；大于等于 587 使用 `587` 产物。

发布工作流仍会构建并打包 `6.6.38-trim_92` artifact，但当前 `cmd/main` 的 `supportKernelList` 没有包含 `6.6.38-trim`，因此运行时不会选择该产物。修改支持矩阵时，要同时检查 `cmd/main`、`manifest` 描述和 `.github/workflows/test_release.yml` 的下载/依赖列表。

## 修改版本或上游 DKMS 时的注意点

更新上游 DKMS 版本时，通常需要同步修改 `.github/workflows/test_release.yml` 中的 `target_dkms_version`、`target_commit_sha`、必要的单独旧内核覆盖值，以及 `this_pack_manifest_version`；`i915-sriov-dkms_driver/manifest` 应保留版本构建期占位符，只在支持内核描述或文案变化时修改。

新增内核支持时，需要新增或复制对应的 `kernel-*.yml` 工作流，确保容器镜像、`kernel_name`、`kernel_ver`、artifact 名称、`test_release.yml` 的 job 依赖和下载路径、以及 `cmd/main` 的运行时目录名完全一致。目录名不一致会导致应用安装时找不到已打包的模块产物。
