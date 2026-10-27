# Doleo

Sileo 的 DEB 下载与本地仓库工具。将插件安装包保存在本地，按需选择版本下载、备份和重新安装。

[官网](https://doleo.goforit.si/) · [下载安装包](https://github.com/5hux1n/Doleo/releases/latest) · [插件源](https://apt.mjh.im/) · [反馈](https://pingme.pm/doleo)

## 功能

- **仅下载不安装**：选择软件源中可用的版本，支持连同依赖下载。
- **本地仓库**：集中管理 DEB，查看版本与下载来源，支持导出及交给 Sileo 安装。
- **自动备份**：Sileo 下载 DEB 后立刻留存一份原始文件，装完再收进仓库（Sileo 装完会清空 APT 缓存，所以要在下载时留存）；没留存到的再按版本号从软件源重新下载。不参与 APT 的安装过程，rootless / RootHide 都能用。
- **已购插件下载**：使用 Sileo 当前商店账户验证购买状态，获取授权后下载入仓。
- **来源与校验**：醒目标记其他源版本；索引提供 SHA256 时校验下载文件。
- **仓库管理**：设置版本保留数量，标记当前源中已不可用的版本。

## Rootless 1.0.0 更新须知

**仅在 Rootless 1.0.0 更新时报 APT 钩子错误时操作；新版不再使用 APT 钩子，这一步是一次性的。**

1. 用 **Filza** 打开目录：

   `/var/jb/etc/apt/apt.conf.d/`

2. 找到 **99doleo**，改名为 **99doleo.disabled**。

3. 返回 **Sileo**，刷新软件源后更新至 **1.0.2**。

更新后会清理旧钩子配置，**已保存的 DEB 和设置会保留**。

## 安装与使用

添加源 `https://apt.mjh.im/`，搜索并安装 Doleo，随后重新打开 Sileo。也可以从 GitHub Release 下载对应安装包：

| 环境 | 安装包 |
| --- | --- |
| Rootless，iOS 15 及以上 | `Doleo_1.0.2_arm64.deb` |
| RootHide，iOS 15 及以上 | `Doleo_1.0.2_arm64e.deb` |

软件包页顶部的 **Doleo** 可打开仓库；插件详情页安装按钮旁的图标提供下载与仓库入口。自动备份两项都默认关闭，需在设置中手动开启。

下载已购插件前，请先在 Sileo 登录对应软件源账户，并打开该插件详情页。账户请求参数仅保存在内存，不写入仓库文件。

依赖下载采用简化解析，不处理版本约束与 Provides；安装仓库版本时，由 Sileo 处理安装依赖和队列。自动备份优先使用下载时留存的原始 DEB，没有留存时按版本号从软件源补下载；两者都不可用时跳过，并记录到自动备份日志。旧版本需要曾经留存过，或仍可从软件源下载；通过 Zebra、apt 或 Filza 安装的包还取决于 APT 缓存是否仍在。

仓库保存在越狱根目录下的 `/var/lib/doleo/archive`，可从设置中用 Filza 或 Fila 打开。普通卸载保留仓库，执行 purge 会删除数据。

## 构建

需要 macOS、Xcode 和 Theos；RootHide 需要对应的 Theos 分支。

```sh
THEOS=/path/to/theos make clean
LC_ALL=C THEOS=/path/to/theos make package THEOS_PACKAGE_SCHEME=rootless PACKAGE_VERSION=1.0.2 FINALPACKAGE=1

THEOS=/path/to/theos-roothide make clean
LC_ALL=C THEOS=/path/to/theos-roothide make package THEOS_PACKAGE_SCHEME=roothide PACKAGE_VERSION=1.0.2 FINALPACKAGE=1
```

最终 DEB 输出至 `dist/`。

作者：[Junhong](https://mjh.im/) · [Ko-fi](https://ko-fi.com/manjunhong)
