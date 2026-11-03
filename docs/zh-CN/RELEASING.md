# 发布

[English](../en/RELEASING.md) · **简体中文**

LanDetector 不走 App Store，用 Developer ID 签名并公证后分发：macOS 27 只向 Developer ID 签名的应用开放 ARP / NDP 表里的 MAC 地址。

## 发布一个版本

推送以 `v` 开头的 tag。tag 的说明就是发布说明，同时显示在 Release 页面与应用的更新窗口里；以 `- ` 开头的行显示为列表。

```bash
git tag -a v1.2.0 -m "- 新功能" -m "- 修复"
```

```bash
git push origin v1.2.0
```

随后 [`.github/workflows/release.yml`](../../.github/workflows/release.yml) 在 `xcode-27` 运行器上：

1. 运行 LanDetectorKit 的测试。
2. 构建通用（Apple 芯片 + Intel）Release，版本号取自 tag，构建号由版本推出（1.2.3 → 10203）。
3. 用 Developer ID 由内向外重签 Sparkle 的辅助程序与应用（`Scripts/resign.sh`；`xcodebuild build` 会让这些辅助程序保持 ad-hoc 签名）。
4. 公证并装订应用，打包 `LanDetector-<版本>.zip`（用于在线更新）与 `LanDetector-<版本>.dmg`（用于下载，`Scripts/make-dmg.sh`），再公证并装订磁盘映像。
5. 用 EdDSA 私钥给 zip 签名并生成 `appcast.xml`（`Scripts/make-appcast.sh`）。
6. 发布 GitHub Release，附带 DMG、zip、`SHA256SUMS.txt` 与 `appcast.xml`。

带后缀的 tag（如 `v1.2.0-beta.1`）发布为预发布版本，已安装的应用看不到它。在 Actions 页面手动运行该 workflow 会构建同样的文件并作为构件上传，但不发布，可用来验证流水线的改动。

## 在线更新

已安装的应用用 [Sparkle](https://sparkle-project.org) 每天读取一次 `https://github.com/lacdonlang/landetector/releases/latest/download/appcast.xml`（“LanDetector ▸ 检查更新…”可立即检查）。只有 zip 的 EdDSA 签名与 `project.yml` 中的 `SUPublicEDKey` 吻合、且新应用由同一团队签名时才会安装。Debug 构建不检查更新。仓库必须保持公开，应用要匿名下载更新。

## Secrets

仓库 Secrets 与 Fidget 同名。`Scripts/setup-release-secrets.sh` 按提示交互式配置，已存在的会跳过（`FORCE=1` 重新设置）：

| Secret | 内容 |
| --- | --- |
| `MACOS_CERTIFICATE_P12`、`MACOS_CERTIFICATE_PASSWORD` | 从“钥匙串访问”导出的 `Developer ID Application` 证书（含私钥）.p12 的 base64，及其密码 |
| `NOTARY_APPLE_ID`、`NOTARY_TEAM_ID`、`NOTARY_PASSWORD` | 公证用的 Apple ID、Team ID 与 App 专用密码 |
| `SPARKLE_ED_PRIVATE_KEY` | 给更新包签名的 EdDSA 私钥 |

Sparkle 私钥同时保存在维护者的登录钥匙串中（账号 `com.lacdon.LanDetector`）。**务必随钥匙串一起备份**：私钥丢失后，新签名对不上已安装版本内置的公钥，这些版本就再也无法更新。

缺少证书时，流水线构建 ad-hoc 签名的应用（不开启 Hardened Runtime，否则会拒绝加载 Sparkle），也不生成 appcast；缺少公证凭据时跳过公证。

## 检查构建产物

```bash
codesign -dv --verbose=4 LanDetector.app
```

```bash
spctl --assess --type execute -vv LanDetector.app
```

```bash
xcrun stapler validate LanDetector.dmg
```
