# LightWall · 光墙

> 一窗之光，四时流转。
> 把一面平光材质墙，交给真实的太阳。

![platform](https://img.shields.io/badge/platform-Windows%20%7C%20CLI-0078D4)
![arch](https://img.shields.io/badge/arch-x64%20%7C%20arm64-555)
![release](https://img.shields.io/github/v/release/yingo-server/light_wall)
![license](https://img.shields.io/badge/license-AGPL--3.0-blue)

---

## 提要

LightWall 是**桌面壁纸引擎**，亦是一部**可执行的室内光照物理**。

它取经纬度与时刻，算出太阳与月亮的方位与高度，复演其穿过大气之途；
再以一间三维房间为器，以窗为口，令光落于墙上、折于窗格、弹于四壁。
所出之画，非滤镜之工，乃**渲染方程之解**。

> 本文体例，参照 Google 技术白皮书的写法：
> 先陈提要，次明范围，再列公理、模型、实现与验证，末言已知局限。
> 凡涉物理之处，皆给依据；凡为工程所设之常数，皆注明其不得已。

---

## 一、所为

```
平光底图 ─► 反射率分解 ─► 材质 ─► 三维房间与窗光追踪 ─► 室内互反射
          ─► 线性域求和 ─► ACES 影调映射 ─► 显示编码 ─► 朱红题字 ─► 壁纸
```

- **真实天文**：日、月之位，由经纬度与 UTC 推得；日出日没、暮光、月相俱在。
- **分波长大气**：`T(λ)=exp(−[τ_R(λ)+τ_O₃(λ)+τ_M(λ)]·m)`，低日自暖，无须调色。
- **窗格光斑**：形、位、明暗，皆由日之方位与高度所驱；窗框投影，实有其影。
- **室内物理**：窗作**矩形面光源**，行双余弦积分；叠加一阶互反射。
- **文字是颜料，非贴纸**：乘性反射合成 `L = L_wall·(1−occ·s)·[(1−α)+α·ρ]`，
  光斑之下字亦明，幽暗之中字亦沉。

**只做晴天**。云雨雪雾，一概去之。参数愈少，物性愈显。

---

## 二、取用

### 桌面版（Windows）

自 [Releases](https://github.com/yingo-server/light_wall/releases) 取
`LightWall-windows-x64.zip` 或 `…-arm64.zip`，解压即用。
双击 `light_wall.exe`，栖于托盘，每三刻自新其壁。

### 命令行版（Windows / Linux，x64 / arm64）

内核为**纯 Dart**，可 AOT 编译为独立可执行文件，不倚 Flutter、不需 GPU。
凡无图形之境（远程会话、无显卡之虚机），皆可出图。

```bash
lightwall_render --bg wall.png --time 2025-12-21T08:30:00+08:00 \
                 --lat 39.9042 --lon 116.4074 --window east --out out.png
```

---

## 三、要义

其一，**内核离乎界面**。物理与成像在 `packages/lightwall_core`，无 Flutter 之
依赖，可独测、独跑、独出图。外壳但司其时与用。

其二，**常数必有其出**。凡物理常数，皆注其源（IAU、CIE、ISO、Bodhaine、
Meeus、Saemundsson、Fisher）。凡拟合之数，则明标其为权宜，且尽量去之。

其三，**简而不失其真**。晴空一种，云量恒零，能见度二十里；非不能繁，而是
刻意取其可验、可复、可预期。

---

## 四、验证

物理的正确，不凭观感，凭数。

- **九十七则单元测试**：天文、大气、几何、色彩、编解码。
- **十一景回归门禁**（`tools/light_diag.dart`）：判过曝、死黑、昼夜之序、
  直射之有无、逐字节之确定性。凡算法一动而失衡，立现。
- **全天延时**：一日六十帧，并为一刻一秒之影，见光之流转。

```bash
cd packages/lightwall_core
dart pub get
dart test                       # 单元测试
dart run tools/light_diag.dart  # 光照合理性门禁
```

---

## 五、目录

```
light_wall/
├── packages/lightwall_core/    纯 Dart 渲染内核（可独立测试与命令行出图）
│   ├── lib/src/astro.dart          天文与大气
│   ├── lib/src/spectrum.dart       太阳光谱 → 线性 sRGB
│   ├── lib/src/sky.dart            天空亮度分布（CIE 标准晴空）
│   ├── lib/src/atmosphere.dart     窗面照度、互反射、曝光适应
│   ├── lib/src/scene3d.dart        三维房间、相机、窗与半影
│   ├── lib/src/tracer.dart         逐像素着色（Cook–Torrance）
│   ├── lib/src/retinex.dart        光照与反射率之分解
│   ├── lib/src/material.dart       材质
│   ├── lib/src/compose.dart        ACES 影调映射与成像链
│   ├── lib/src/textlayer.dart      年代感与叠字
│   └── bin/render.dart             命令行渲染器
├── app/                        Flutter Windows 外壳（托盘 / 壁纸 / 面板）
└── docs/                       白皮书与说明
```

---

## 六、致歉与自省

物理之墙，非一蹴可及。项目曾以"高度角→色温→黑体"之拟合上色，以"写死之
互反射底"充室内，以"经验幂律"拟日轮之大小 —— 皆为自欺。

今已尽数改易：太阳之色，由**光谱积分**得之；室内之光，由**双余弦积分**
得之；日轮之径，回归其几何本值，散射之晕另计其事。法度既明，画自随之。

此为**首个正式公开之版**，仍有所不逮，悉数列于
[`docs/whitepaper.md`](docs/whitepaper.md) 之"已知局限"与"待决之事"。

---

## 七、许可

**GNU Affero General Public License v3.0**，见 [LICENSE](LICENSE)。
商业授权，请洽作者。

Copyright © 2025–2026 yingo-server · LightWall contributors
