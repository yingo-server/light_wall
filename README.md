# LightWall · 光墙

> Windows 桌面壁纸引擎：把一面**平光材质墙**实时重打成**真实窗光**，
> 每 3 分钟重新渲染并设为壁纸 —— 太阳位置由经纬度与时刻算出，
> 光斑随季节、钟点、朝向自然流转，墙上叠着朱红题字（支持变量与倒计时）。

![platform](https://img.shields.io/badge/platform-Windows-0078D4)
![flutter](https://img.shields.io/badge/Flutter-3.47%2B-02569B)
![license](https://img.shields.io/badge/license-AGPL--3.0-blue)

---

## 它做什么

```
平光材质底图 ──► Retinex 分解 ──► PBR 材质提取 ──► 3D 房间 + 窗光追踪
              ──► ACES 色调映射 ──► 相机效果 ──► 朱红叠字 ──► 壁纸
```

- **真实天文**：太阳/月亮位置由经纬度与 UTC 时刻算出，日出日落、暮光、月相都在
- **分波长大气**：`T(λ)=exp(-(τ_R(λ)+τ_M)·AM)` —— 低太阳角自动偏橙红
- **窗格光斑**：位置/拉伸/剪切由太阳方位与高度驱动，窗框投影真实存在
- **室内物理**：窗户当**矩形面光源**做面积分，叠加室内互反射底，明暗过渡自然
- **文字是颜料不是贴纸**：乘性反射合成 `L = L_wall·(1−occ·s)·[(1−α)+α·ρ]`，
  字会随光斑变亮、在暗处变沉
- **变量与倒计时**：`{time}` `{date}` `{countdown:2026-01-01}` …
  见 [文字变量](docs/variables.md)

**只允许晴天**：本产品刻意去掉天气系统（云/雨/雪/雾），只保留晴空物理 ——
参数更少、结果更可预测、画面更干净。

---

## 快速开始

1. 从 [Releases](https://github.com/yingo-server/light_wall/releases) 下载
   `LightWall-windows-x64.zip`，解压到任意目录
2. 双击 `light_wall.exe`，程序驻留托盘，每 3 分钟自动更新壁纸
3. 右键托盘图标 → **打开面板**，即可改文字与底图

> 首次运行会在 `%APPDATA%\LightWall\` 生成配置与输出目录。

---

## 面板

| 页面 | 作用 |
|---|---|
| **概览** | 当前光照信息（太阳高度/方位、辐照度）、预览、立即渲染 |
| **文字** | 文案模板（支持变量）、字体、字号、位置、年代感强度 |
| **底图** | 内置材质 + 导入自己的图片（自动转成平光输入） |
| **设置** | 开机自启、隐藏到托盘、渲染间隔说明、日志 |

界面遵循 Material 3，简洁大气；除上述内容外**不暴露多余参数**。

---

## 命令行（调试/批处理）

```powershell
# 渲染一张并存到指定路径（不驻留托盘）
light_wall.exe --render --out out.png --time "2025-12-21T08:30:00+08:00" `
               --lat 39.9042 --lon 116.4074 --window east --text "朝闻道"

# 输出界面截图（CI 用来做 UI 回归）
light_wall.exe --shot ui_home.png --ui-page home
```

---

## 仓库结构

```
light_wall/
├── packages/lightwall_core/   纯 Dart 渲染内核（无 Flutter 依赖，可独立测试/CLI）
│   ├── lib/src/astro.dart         天文与大气
│   ├── lib/src/scene3d.dart       3D 房间与窗户
│   ├── lib/src/tracer.dart        逐像素着色
│   ├── lib/src/retinex.dart       光照/反射率分解
│   ├── lib/src/material.dart      PBR 材质提取
│   ├── lib/src/compose.dart       ACES 与相机效果
│   ├── lib/src/textlayer.dart     年代感与叠字
│   ├── lib/src/codec.dart         PNG / BMP 编解码
│   └── bin/render.dart            命令行渲染器
└── app/                       Flutter Windows 外壳（托盘 / 壁纸 / 面板）
```

**为什么内核是纯 Dart**：物理与图像算法可以脱离 Flutter 独立单元测试、
独立跑 CI、独立出图；外壳只负责"什么时候渲染、渲染结果给谁用"。

```bash
# 不装 Flutter 也能跑：
cd packages/lightwall_core
dart pub get && dart test
dart run bin/render.dart --bg wall.png --out out.png --window east
```

---

## 许可

**GNU Affero General Public License v3.0**（见 [LICENSE](LICENSE)）。
商业授权请联系作者。

Copyright (C) 2025 yingo-server and LightWall contributors
