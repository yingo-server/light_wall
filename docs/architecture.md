# 架构

## 一、分层

```
┌──────────────────────────────────────────────┐
│ app/            Flutter Windows 外壳          │
│   tray_host · scheduler · panel · settings    │  何时渲染、结果给谁用
└───────────────┬──────────────────────────────┘
                │  仅调用纯函数式渲染入口 render()
┌───────────────▼──────────────────────────────┐
│ packages/lightwall_core   纯 Dart 渲染内核     │
│   astro · spectrum · sky · atmosphere         │
│   scene3d · tracer · material · retinex       │
│   compose · textlayer · codec                 │
└──────────────────────────────────────────────┘
```

**内核无 Flutter 依赖**，故可脱离界面独立单元测试、独立跑 CI、独立出图
（`bin/render.dart`，AOT 编译为单文件可执行）。

## 二、一次渲染的次序

```
底图 sRGB 字节
  → 解码为线性光                                    codec
  → 逐通道 Retinex 分解：I_c = R_c · S_c             retinex
  → 材质（ρ = R_c）                                  material
  → 光源：日/月/暮光/夜 之照度与色                   astro · spectrum
  → 窗光追踪：直射 + 玻璃 Fresnel + 半影              scene3d · tracer
  → 窗面照度场（双余弦积分）+ 一阶互反射              atmosphere
  → 线性域求和 → 一次弹射 → 测光曝光 → 渐晕          compose · pipeline
  → ACES RRT+ODT（唯一一次非线性）
  → sRGB 编码 + 抖动
  → 朱红叠字（线性反射 + 接触阴影）                   textlayer
```

## 三、约定

- **坐标**：房间 $x\in[-W/2,W/2],\,y\in[0,H],\,z\in[0,D]$；观察墙 $z=0$，
  内法线 $+Z$；相机在 $z=+d$ 望向 $-Z$。规范方位角 $\text{canonical}(az)
  =(\sin az,0,-\cos az)$，地理角 $=$ 规范角 $-180^\circ+$ 观察墙方位。
- **量纲**：一切相对量以"天顶直射法向照度 $=1$"为准；线性显示值另行标明。
- **确证**：凡数值断言，必落于 `test/` 或 `tools/light_diag.dart`，可复可核。
