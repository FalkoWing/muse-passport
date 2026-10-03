# 第三方来源与许可证

Muse Passport 基于 Muse Gadget SDK，保留原作者的版权、许可证与来源。本文件补充根目录 `LICENSE`；不会把所有第三方资源重新许可为 Apache-2.0。

| 内容 / 路径 | 来源 | 许可证 / 说明 |
|---|---|---|
| 官方 SDK 基础：`esp32/`、`linux/`、上游工具和测试 | [facebookincubator/muse-gadget-sdk](https://github.com/facebookincubator/muse-gadget-sdk)，本地基础提交 `b9008ab` | Apache-2.0；保留源码版权说明 |
| 新增 Android 伴侣应用与 Passport 集成 | Muse Passport 社区修改 | Apache-2.0，见根目录 `LICENSE` |
| `esp32/components/passport_bsp/`、相关厂商测试桩 | [FoloToy/ai-passport](https://gitee.com/FoloToy/ai-passport)，固定版本见 BSP `UPSTREAM.md` | MIT，保留目录内 `LICENSE` 和来源记录 |
| `esp32/components/muse/fonts/` 字库 | [Adobe Source Han Sans](https://github.com/adobe-fonts/source-han-sans) | SIL Open Font License 1.1，见 `SOURCE_HAN_LICENSE.txt`；生成方式见字库 README |
| `esp32/components/minimp3/` | [lieff/minimp3](https://github.com/lieff/minimp3) | CC0-1.0，见目录内 `LICENSE` |
| `esp32/main/pixel_font.c` | Adafruit GFX `glcdfont.c` | BSD-2-Clause，见源码文件头 |
| Android 打包运行时与依赖 | Chaquopy、CPython、OpenSSL、OkHttp、Okio、Kotlin、cryptography 等 | 各自许可，见 `android/notices/` 与实际依赖包里的许可证；公开打包脚本保留相关文件 |
| 构建时获取的 ESP-IDF、LVGL、NimBLE 等依赖 | 各上游项目 | 各自许可；不提交 `managed_components/` 或本地工具链 |
| UI 模拟器依赖 | LVGL、SDL 等 | 见 `esp32/simulator/THIRD_PARTY.md` |

## 上游资源例外

上游 README 明确指出 **Jollybot avatar 不在 Apache-2.0 许可范围内**。`esp32/avatar/` 中的原始图像与相关生成素材应保留上游版权说明，不能根据根目录 LICENSE 推断可自由复用。保留在 Fork 的上游文件不意味着本项目重新授权这些素材。社区 App 使用 `android/assets/muse-passport-icon.svg` 和对应 Android 矢量资源；Passport 界面采用文字状态，宣传素材不使用 Jollybot。

## 共享开发签名密钥

`esp32/dev_signing_key.pem` 是官方 SDK 原本公开提交的 **shared development key**，不是本项目的发行私钥。保留它是为了保持上游默认固件构建可用；不要把它用于安全启动或声称设备拥有独立的可信发行签名。当前 Passport 配置不启用硬件 Secure Boot 或烧写 eFuse。

Android 发行签名密钥、密码以及个人 SDK token 属于私人配置，必须排除在源码和附件之外。

## Muse 服务条款

[SDK token 条款](https://gadgets.muse.ai/sdk-terms) 管理访问 Muse 服务，源码 Apache-2.0 许可不授予 token、账号或服务访问权。每位使用者设置自己的 token；当前条款规定个人、非商业使用，并禁止将个人 token 公开分享。不要把本项目开源描述为 Meta/Muse 的商业使用授权。
