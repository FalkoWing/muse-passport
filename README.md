<!--
Copyright (c) Meta Platforms, Inc. and affiliates.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

<!-- Modified for Muse Passport community distribution, 2026-10-04. -->

# Muse Passport

<img src="android/assets/muse-passport-icon.svg" width="88" alt="Muse Passport 图标">

把随身设备变成 Muse 对话终端：按住 OK 说话，松开后阅读自己的语音转录与 Muse 文字回复；长内容可以上下翻页，也能回看本轮转录。设备通过蓝牙借用手机网络，目前已在 **FoloToy AI Passport** 实机验证。

这是基于 [Muse 官方 Gadgets 开源硬件方案](https://gadgets.muse.ai/) 与 [Muse Gadget SDK](https://github.com/facebookincubator/muse-gadget-sdk) 的社区衍生项目，包含设备固件、Android 伴侣 App 与 iOS 伴侣 App。与 Meta、Muse 或 FoloToy 官方没有隶属或背书关系。

## 为什么需要 Android 伴侣 App

ESP32 自己直连 Muse，要求它所在的 Wi-Fi 能访问 Muse 服务。Muse Passport 把联网交给手机：完成首次账号绑定后，设备日常只需 BLE 连接，无需设备 Wi-Fi、手机热点或随身电脑。在家、办公室或户外，都可以借用手机的 Wi-Fi 或移动网络；手机放在蓝牙连接范围内，即可用设备的实体按键提问、在小屏幕上读答案。**手机上的 Muse Passport App 必须能够正常访问 Muse 官方服务**，仅有蓝牙连接还不够。

App 使用 Android 系统网络，无需填写代理软件名称、地址或 SOCKS 端口。若手机 VPN 使用分应用规则，请包含 Muse Passport。官方 Muse App 负责账号绑定与完整聊天记录，本伴侣 App 负责连接设备、传输语音和返回文字。

```mermaid
flowchart LR
    P[随身设备：录音与阅读] <-->|绑定、加密 BLE| A[Muse Passport Android App]
    A <-->|手机网络| M[Muse 官方服务]
```

按住 OK 说话、松开发送；支持正常语速、本轮完整转录、Muse 文字回复和上下翻页。设备界面为中文，字库覆盖 GB2312 简体、标准 Big5 繁体及常用标点。App 可设置自己的 SDK token，断线后自动重试，连接期间提供常驻通知。

## 硬件和兼容范围

方案可以移植到其他合适的 ESP32 硬件，**不能把“能移植”理解为现成固件可以直接刷入**。当前桥接固件、引脚与 UI 仅适配并验证 FoloToy AI Passport；其他板型需要改 BSP、麦克风、显示和按键驱动并重新验证。上游 SDK 保留的其他板型支持不代表已验证本项目的手机桥接。

| 项目 | 当前实测 / 移植要求 |
|---|---|
| 芯片与无线 | 实测 ESP32-C3；其他设备需 ESP-IDF 支持且具备 BLE，首次官方初始化需 Wi-Fi。ESP32-S2 无蓝牙，不能直接采用本方案 |
| Flash / RAM | 当前分区要求至少 8 MB Flash；C3 实测无 PSRAM，使用内部 RAM。应用约 3.07 MiB，单个 3.875 MiB 槽剩余约 21%；换板仍需核对任务栈、音频队列和显示内存 |
| 麦克风 | 必需；能提供 16 kHz、16 bit、单声道 PCM。可适配 I2S 数字麦克风或音频 codec；Passport 使用 ES8311 音频接口，不能只更换 GPIO 而忽略采样格式与增益 |
| 屏幕 | 阅读功能必需；实测 ST7789P3 240×320 竖屏。其他尺寸/控制器需适配驱动、布局、字体与分页 |
| 按键 | 说话键与上下导航；实测三键 ADC 输入。替代 GPIO 按键需适配按下、松开及长按事件 |
| 可选硬件 | 电池与电量计适合随身使用；扬声器不是当前文字回复功能的必要条件，尚未实现 Muse 回复语音播放 |
| 手机 | Android 8.0+，arm64；实测 Pixel 10 Pro XL / Android 17。iOS 26+；实测 iPhone 14 Pro / iOS 27 |
| Muse | 自己的账号、官方 Muse App、[Gadget SDK token](https://gadgets.muse.ai/settings/sdk-tokens)，且手机 App 能访问 Muse 服务 |
| 刷机 | USB 数据线与电脑；发布固件只适用于 FoloToy AI Passport |

Passport BSP 来源与修改保留在 [UPSTREAM.md](esp32/components/passport_bsp/UPSTREAM.md)。GPIO21 是背光，控制台须使用原生 USB Serial/JTAG，不能用 UART0 抢占它。三键共享 ADC，音频与屏幕共享的外设由 BSP 管理。

## 下载与刷机

从 [1.0.2 Release 下载页](https://github.com/FalkoWing/muse-passport/releases/tag/v1.0.2) 获取 APK 与安装包，也可以在 [全部 Releases](https://github.com/FalkoWing/muse-passport/releases) 查看后续版本。1.0.2 为 Android 连接诊断修复预发布版，修正 API 协议版本并提供具体失败环节；其中设备固件与 1.0.1 相同。**已有 1.0.1 用户只需覆盖安装新的发行 APK，无需重新刷固件或配对。** 源码不存安装包，封面仅用于玩法社区。

| 文件 | 用途 |
|---|---|
| `Muse-Passport-1.0.2.apk` | 已签名、不可调试的 Android 1.0.2 App |
| `Muse-Passport-1.0.2.zip` | 新版 APK、原 1.0.1 四段固件、刷机参数、本说明、许可证和校验和 |
| `Muse-Passport-1.0.2-full.bin` | 原 1.0.1 固件的完整初始化镜像；社区刷机使用，**覆盖已有配置/配对，需要重新设置** |
| `SHA256SUMS` | Release 附件校验和；ZIP 内另有逐文件校验和 |

发行 APK 证书 SHA-256：`0d304c4229c97b19fbaffe5423e294eb0a04ae38c029a453acfd41d4cadaf11c`。

首次替换厂商固件前，确认是 FoloToy AI Passport 并保存完整 8 MB 原机备份。备份含私人凭据，请留在自己的电脑，不上传。

```sh
python -m pip install 'esptool>=5,<6'
# PORT 替换成设备串口，macOS /dev/cu.usbmodem…、Linux /dev/ttyACM…、Windows COM…
python -m esptool --chip esp32c3 -p PORT chip-id
python -m esptool --chip esp32c3 -p PORT -b 460800 read-flash 0 0x800000 passport-backup.bin
```

芯片检查会重启设备，不能代替板型确认。首次安装可用完整镜像：

```sh
python -m esptool --chip esp32c3 -p PORT -b 460800 write-flash 0 Muse-Passport-1.0.2-full.bin
```

FoloToy AI Passport 也可以不用命令行，直接在 [AI Passport 玩法社区](https://ai-passport.folotoy.cn/plays/919) 的 Muse Passport 页面按提示写入固件。社区提供的是同一份完整镜像，同样会覆盖已有配置与配对。

**已有 Muse 固件且确需更新固件时，用四段方式升级，保留 NVS 中的 token 和配对**；从 1.0.1 升级到本次版本只需更新 App。需要刷机时解压 ZIP，进入 `muse-passport-1.0.2/firmware/`，执行：

```sh
python -m esptool --chip esp32c3 -p PORT -b 460800 \
  --before default-reset --after hard-reset write-flash @flash_args
```

四段地址为 bootloader `0x0`、分区表 `0x10000`、OTA 元数据 `0x1d000`、应用 `0x20000`。不必擦除整个 Flash，不烧写 eFuse；完整镜像会写入这些段之间的空白，覆盖 NVS，不能当作保留配置的升级。恢复厂商系统使用自己的原机备份。连接失败时确认数据线、端口与串口权限，再按设备厂商的下载模式操作。

## 安装 App、设置 token 与绑定账号

1. 先在手机登录官方 **Muse App**，确认网络可访问 Muse 服务。从上方 Release 下载页安装 APK，打开 **Muse Passport**、开启蓝牙并允许所需权限。发行版与旧调试版签名不同，不能覆盖安装；切换须先卸载旧 App，会清除手机设置与本轮缓存，但不会清除设备配对。以后发行更新可以覆盖安装。
2. 点击“选择设备”，选择 `MuseGadget-XXXXXX`，点击“连接 Passport”。系统蓝牙配对弹窗要求 PIN 时，输入 Passport 屏幕上的六位数字。
3. 用自己的 Muse 账号登录 [Muse Gadgets 的 SDK token 页面](https://gadgets.muse.ai/settings/sdk-tokens)，创建个人 SDK token。回到伴侣 App，打开“设备设置 → 设置 SDK token”，粘贴自己的 `mgst_…` token，点击“保存到设备”。设备保存后重启，App 重连后检查“SDK token 已设置”。公开固件不包含维护者或其他用户的 token。
4. 若设备已绑定 Muse 账号，等待“Muse 已连接”即可，跳过首次绑定。全新设备先在伴侣 App 点“断开连接”；打开官方 Muse App，在设置中进入设备页面，开启开发者模式，点右上角“＋”添加同名 `MuseGadget-XXXXXX` 设备。按提示选择 Wi-Fi、输入密码并确认；设备要求确认时按 OK。初始化完成后退出官方 App 的设备设置页，再回到 Muse Passport 点“连接 Passport”，等待“Muse 已连接”。这对应[官方指南](https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/README.md#4-set-it-up-with-muse)的 Settings → Devices → Developer mode / Add Device 流程；不同版本的界面文案可能略有差异。
5. **首次官方账号初始化仍需 Wi-Fi 设置步骤，尚未实现纯 BLE 首次配对**；官方流程连接失败时回到设备设置，重新选择网络、输入密码并重试。账号初始化完成后的日常对话才可以只使用手机网络。SDK token 设置不是账号绑定，系统蓝牙绑定也不是 Muse 账号绑定。

Passport 同时只能被一个 App 连接，官方 Muse App 的设备设置页与伴侣 App 不能同时占用它。普通聊天页可以查看对话。公开包不继承编译时的私有 token：从旧开发固件升级前，请先通过新 App 保存自己的 token。

## 在 iPhone 上使用

iOS 伴侣 App 以源码提供，需要用 Mac 自行构建并安装到自己的 iPhone；固件与 Android 相同，按“下载与刷机”刷入。需要 Xcode 26 或更新、iOS 26 或更新和一个 Apple ID。免费 Apple ID 也可以，签名 7 天后过期，届时用 Xcode 重新运行一次。

1. 克隆本仓库，用 Xcode 打开 `ios/MusePassport/MusePassport.xcodeproj`。在 MusePassport target 的 Signing & Capabilities 里把 Team 换成自己的，把 Bundle Identifier 改成自己的唯一标识，然后选择自己的 iPhone 运行。
2. 打开 **Muse Passport**，点“添加设备”，在系统配件面板里选中 Passport，输入设备屏幕上的六位数字完成配对。
3. 点“设置 SDK token”，粘贴自己的 `mgst_…` token，点“保存到设备”；设备重启并重连后显示“SDK token 已设置”。token 的创建方法见上一节第 3 步，App 不保存也不回显 token。
4. 若设备已绑定 Muse 账号，等待“Muse 已连接”即可。全新设备先关闭“桥接”开关，按上一节第 4、5 步在官方 Muse App 里完成账号绑定与 Wi-Fi 初始化，再回到 Muse Passport 打开“桥接”。

桥接默认常开：保持蓝牙和手机网络开启，锁屏、App 被系统回收或被手动划掉后仍可对话，设备重新开机后自动恢复，不必再打开 App。要在官方 Muse App 里设置设备时，先关闭“桥接”。“移除设备”会同时删除系统蓝牙配对，不影响设备上的账号绑定和 SDK token。下一节的按键操作同样适用；iOS 没有常驻通知，用“桥接”开关代替“断开连接”。

已在 iPhone 14 Pro / iOS 27 实测前台对话、锁屏空闲 10 分钟后对话、设备断电重开后自动恢复、Wi-Fi 与蜂窝网络切换，以及 App 被系统回收或手动划掉后的对话；全新设备完整初始化和在 iOS App 里保存 token 仍需进一步实测。

## 日常对话与按键

看到“Muse 已连接”后，按住 OK 自然说话，松开发送，等待转录与文字回复。手机需留在蓝牙连接范围内，伴侣 App 需保持网络可用。每次新录音替换设备上的上一轮内容；完整聊天记录请在同一账号的官方 Muse App 查看。

| 操作 | 效果 |
|---|---|
| 按住 OK / 松开 | 录音 / 发送新一轮语音 |
| 短按上键 / 下键 | 上一页 / 下一页 |
| 回复第一页短按上键 | 回看自己本轮的完整转录；从转录末页向下进入回复 |
| 长按下键约 0.8 秒 | 打开设备菜单 |
| 菜单中下键 / OK | 选择 / 确认；选择关闭可退出菜单 |
| 熄屏后按上下键 | 先唤醒，首次不翻页 |
| App 点“断开连接”，或常驻通知点“断开” | 结束桥接；续用时打开 App 重新连接设备 |

## 常见问题与当前边界

- **蓝牙已连接，Muse 未连接**：先升级到 App 1.0.2 并查看具体失败环节。DNS、超时、TLS 或网络连接错误需检查本应用的网络与 VPN 分应用规则；API HTTP 状态、账号无可用 VM、设备注册或回复订阅错误需按提示检查账号、配对或 Muse 服务。官方 Muse App 能访问服务，不代表所有连接错误都来自手机网络。无需添加代理端口；可在 App 断开后重新连接。
- **能看转录但没回复**：确认使用 App 1.0.2 与兼容的 1.0.1 固件，并等待手机 Muse App 的回复；重新连接后再发新一轮。本轮阅读缓存不是长期聊天历史，App 进程结束或会话重建可能丢失。
- **繁体或方块**：Muse 服务端决定识别文字与语言。扩展字库解决标准 Big5 显示，不强制服务端输出简体，也不提高识别准确率；生僻字、HKSCS 和 emoji 仍可能缺字。
- **特别长的内容**：上下键按屏幕页码翻页；单条及本轮合并回复各有 64 KiB UTF-8 上限，手机最多缓存 32 条。超限全文看官方 Muse App。
- **清除与转交设备**：App 可单独清除 SDK token；设备账号/Wi-Fi 重置不自动清除它。转交前分别清除 token 和账号配对。保存中断时重连检查状态，不把断线当作保存成功。

当前不提供回复语音播放或设备 OTA。熄屏只关闭背光，不代表完整低功耗休眠。已验证正常语速语音、简繁中文显示、本轮转录、回复及分页；全新设备完整初始化、App 写入真实 token 后重启重连、长期锁屏、跨手机与网络切换、续航仍需进一步实测，因此首次发行标记为预发布。

## 开发与构建

固件固定 **ESP-IDF 6.0.1**；Android 使用 **JDK 17**、Android SDK 36 / Build Tools 35.0.0、Python 3.13，Gradle 8.13、AGP 8.13.2、Chaquopy 17.0.0；iOS 使用 **Xcode 26** 或更新，只依赖系统框架。构建脚本默认 macOS Homebrew 路径；其他安装设置 `JAVA_HOME`、`ANDROID_HOME`、`PASSPORT_BUILD_PYTHON`；Windows 可直接用 `gradlew.bat`。IDF 自定义路径设置 `IDF_EXPORT` 或先激活该版本。

```sh
git clone --branch passport https://github.com/FalkoWing/muse-passport.git
cd muse-passport/esp32
./tools/passport.sh release-build        # 独立空 token 的公开 BLE 配置
cd ../android
./tools/build.sh assembleDebug lintDebug
# 发行签名仅首次创建；已有密钥必须保留、另行安全备份。
python3 tools/setup_signing.py
./tools/build.sh assembleRelease lintRelease
python3 tools/package_release.py
```

发行密钥在忽略目录 `.private/`，不要上传私钥、密码或个人路径配置。自己构建的 APK 与本项目 Release 签名不同。固件私有开发可用 `./tools/passport.sh menuconfig`、`build`、`ble-build`；这些二进制可能含个人 token，**不可公开分发**。发布必须使用 `release-build` 并运行公开包校验。

```sh
# 固件主机测试，在 esp32/ 下执行
python3 -m unittest discover -s tests -p 'test_*.py'
# Android 后端和跨语言测试，在 android/ 下执行
PYTHONPATH=../linux/src:app/src/main/python python3 -m unittest discover -s tests -v
javac -d /tmp/passport-protocol app/src/main/java/ai/muse/passport/BridgeProtocol.java tests/ProtocolTest.java
java -cp /tmp/passport-protocol ProtocolTest
# iOS 桥接核心测试，在 ios/PassportBridge/ 下执行，不需要模拟器
swift test
```

测试中的生产 C 阅读解析器需要 ESP-IDF 已获取的 cJSON 组件。主机测试覆盖音频编码、协议、回复关联、分页、字库、按键和 token 存储；不能代替真实 BLE、Muse 服务和续航测试。修改共享 SDK/UI 时，还需构建其他板型做回归。

| 路径 | 内容 |
|---|---|
| `android/` | 伴侣 App、自有图标、构建和测试 |
| `ios/` | iOS 伴侣 App：Swift 桥接核心、App 工程和测试向量生成脚本 |
| `esp32/` | 官方 SDK 基础、Passport BSP/固件/字库和测试 |
| `linux/src/musegadget/` | Android 依赖的上游 Noise/API 协议模块，必须随源码保留 |
| `NOTICE`、`THIRD_PARTY.md` | 来源、第三方许可与资源例外，须保留 |

`passport` 分支为本项目开发与发行分支；上游 SDK 的更新按需从[官方仓库](https://github.com/facebookincubator/muse-gadget-sdk)合并。上游板型文档、许可和开发规范保留原结构；使用说明集中在本文。构建输出、个人需求/开发经验文档、原机/NVS 备份、凭据和社区封面均不进入源码仓库。

## 隐私与许可证

公开固件没有预置个人 token，每位用户使用自己的账号和 token。凭据通过已认证、加密的 BLE 通道传输，当前设备 NVS **没有静态加密**。手机只在会话内存中持有设备凭据和本轮文本，不把账号/token 存为配置文件；App 备份已禁用。语音与文本发送至 Muse 服务用于对话。

代码沿用 [Apache-2.0](LICENSE)，不是把官方 SDK 改为 MIT。厂商 BSP 与测试桩保留 MIT、Source Han 字库保留 SIL OFL 1.1，其他文件和依赖依照各自许可；见 [第三方说明](THIRD_PARTY.md)。上游 Jollybot 角色不属于 Apache-2.0 授权，不宣称本项目拥有或可重新授权角色形象；App 使用自有图标。

源码许可与 [Muse Gadget SDK Token 使用条款](https://gadgets.muse.ai/sdk-terms) 分开适用。当前 token 条款限个人、非商业使用；源码开源不提供服务授权，也不允许公开分享维护者的 token。感谢 Muse Gadget SDK、[FoloToy AI Passport](https://gitee.com/FoloToy/ai-passport)、ESP-IDF、LVGL 与 Source Han Sans。
