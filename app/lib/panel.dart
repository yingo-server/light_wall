// LightWall · 设置面板（Material 3）
//
// 布局刻意保持简洁：四个页签，每页只放必要项。
//   概览 —— 当前光照、预览、立即渲染
//   文字 —— 模板（含变量）、字体、位置、年代感
//   底图 —— 内置三张 + 导入自己的图片
//   设置 —— 位置、窗户朝向、开机自启、隐藏托盘
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lightwall_core/lightwall_core.dart';

import 'scheduler.dart';
import 'settings.dart';
import 'variables.dart';
import 'win32.dart';

class PanelPage extends StatefulWidget {
  const PanelPage({
    super.key,
    required this.settings,
    required this.scheduler,
    required this.onExit,
    this.initialTab = 0,
    this.tabController,
  });

  final AppSettings settings;
  final RenderScheduler scheduler;
  final VoidCallback onExit;

  /// `--shot` 用：直接指定初始页签。
  final int initialTab;

  /// `--shot` 用：暴露页签控制器，让外部在树建好后切换页签。
  ///
  /// 【真 bug 修复】此前 --shot 靠"合成一次点击 NavigationRail"来切页，
  /// 假设导航栏 4 等分。实际 NavigationRail 的 destination 会随内容
  /// 伸展、等分假设不成立 → bg / settings 两页点空，截图退回 home，
  /// 回归对比形同虚设（4 张图里 3 张是同一张）。
  final ValueNotifier<int>? tabController;

  @override
  State<PanelPage> createState() => _PanelPageState();
}

class _PanelPageState extends State<PanelPage> {
  int _tab = 0;
  late final TextEditingController _textCtrl;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _textCtrl = TextEditingController(text: widget.settings.template);
    _tab = widget.initialTab.clamp(0, 3);
    widget.tabController?.addListener(_onExternalTab);
  }

  void _onExternalTab() {
    final v = widget.tabController?.value ?? _tab;
    if (v != _tab && mounted) setState(() => _tab = v);
  }

  @override
  void dispose() {
    widget.tabController?.removeListener(_onExternalTab);
    _textCtrl.dispose();
    super.dispose();
  }

  AppSettings get s => widget.settings;

  void _save() {
    s.template = _textCtrl.text;
    s.save();
    setState(() => _dirty = false);
  }

  Future<void> _pickBackground() async {
    try {
      final res = await _pickFile();
      if (res != null) {
        setState(() {
          s.backgrounds.add(res);
          s.save();
        });
      }
    } catch (_) {}
  }

  Future<String?> _pickFile() async {
    // 用 file_selector 的原生对话框；不可用时回落到手动输入路径
    try {
      const fs = _FileSelectorShim();
      return await fs.pickPng();
    } catch (_) {
      return null;
    }
  }

  void _applyAndRender() {
    _save();
    widget.scheduler.render();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF7A5B3A));
    return MaterialApp(
      title: 'LightWall 光墙',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        visualDensity: VisualDensity.standard,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('LightWall 光墙', style: TextStyle(fontSize: 18)),
          actions: <Widget>[
            IconButton(
              tooltip: '立即渲染',
              onPressed: () => widget.scheduler.render(),
              icon: const Icon(Icons.wb_sunny_outlined),
            ),
            IconButton(
              tooltip: '隐藏到托盘',
              onPressed: widget.onExit,
              icon: const Icon(Icons.close),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: Row(
          children: <Widget>[
            NavigationRail(
              selectedIndex: _tab,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: const <NavigationRailDestination>[
                NavigationRailDestination(
                    icon: Icon(Icons.wb_sunny_outlined), label: Text('概览')),
                NavigationRailDestination(
                    icon: Icon(Icons.text_fields), label: Text('文字')),
                NavigationRailDestination(
                    icon: Icon(Icons.wallpaper), label: Text('底图')),
                NavigationRailDestination(
                    icon: Icon(Icons.settings_outlined), label: Text('设置')),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: <Widget>[
                  _overview(),
                  _textPage(),
                  _backgroundPage(),
                  _settingsPage(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ───────────────────────── 概览 ─────────────────────────
  Widget _overview() {
    return ValueListenableBuilder<RenderOutcome?>(
      valueListenable: widget.scheduler.last,
      builder: (context, out, _) {
        return ListView(
          padding: const EdgeInsets.all(24),
          children: <Widget>[
            _card(
              '当前光照',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _kv('状态', out == null ? '—' : (out.ok ? '正常' : '失败')),
                  _kv('文案', out?.text.isNotEmpty == true ? out!.text : '—'),
                  _kv('光源', _sourceLabel(out?.source)),
                  _kv('太阳高度',
                      out == null ? '—' : '${out.sunAlt.toStringAsFixed(1)}°'),
                  _kv('太阳方位',
                      out == null ? '—' : '${out.sunAz.toStringAsFixed(0)}°'),
                  _kv('辐照度', out == null ? '—' : out.beam.toStringAsFixed(3)),
                  _kv(
                      '直射光斑',
                      out == null
                          ? '—'
                          : '${(out.visibleRatio * 100).toStringAsFixed(1)}%'),
                  _kv('渲染耗时', out == null ? '—' : '${out.elapsedMs} ms'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _diagnostics(out),
            const SizedBox(height: 16),
            _preview(out),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                ValueListenableBuilder<String>(
                  valueListenable: widget.scheduler.status,
                  builder: (context, st, _) => Text(
                    st,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const Spacer(),
                ValueListenableBuilder<DateTime?>(
                  valueListenable: widget.scheduler.nextRun,
                  builder: (context, next, _) => Text(
                    '下次更新：${next == null ? '—' : '${next.hour.toString().padLeft(2, '0')}:${next.minute.toString().padLeft(2, '0')}'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: 12),
                ValueListenableBuilder<bool>(
                  valueListenable: widget.scheduler.busy,
                  builder: (context, busy, _) => FilledButton.icon(
                    onPressed: busy ? null : () => widget.scheduler.render(),
                    icon: busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh),
                    label: const Text('立即渲染'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _preview(RenderOutcome? out) {
    if (out == null || out.pngBytes.isEmpty) {
      return Container(
        height: 200,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        child: const Text('首次渲染后显示预览'),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child:
          Image.memory(out.pngBytes, fit: BoxFit.cover, width: double.infinity),
    );
  }

  static String _sourceLabel(String? s) {
    switch (s) {
      case 'sun':
        return '日光';
      case 'moon':
        return '月光';
      case 'twilight':
        return '暮光';
      case 'night':
        return '夜空';
      default:
        return '—';
    }
  }

  /// 光照诊断卡：把"为什么是这样"讲清楚，而不是只丢一串数字。
  ///
  /// 用户最常见的困惑是"我选了南窗，怎么没有光斑"——答案几乎总是
  /// 「太阳此刻与窗面夹角太大/太阳在窗背面」。这里直接给出结论 + 依据。
  Widget _diagnostics(RenderOutcome? out) {
    if (out == null) return const SizedBox.shrink();
    final sunAz = out.sunAz;
    final winAz = s.windowAz;
    final rel = ((sunAz - winAz + 540) % 360) - 180;
    final behind = rel.abs() > 90;
    // 相对夹角越小 → 入射越正 → 光斑越亮（用 cos 作粗略估计）
    final double cosEst = behind ? 0.0 : (1 - rel.abs() / 90).clamp(0.0, 1.0);

    final (verdict, detail, color) = behind
        ? (
            '此刻太阳在窗背面',
            '太阳方位 ${sunAz.toStringAsFixed(0)}°，窗户朝向 '
                '${_compass(winAz)}（${winAz.toStringAsFixed(0)}°），'
                '相对方位 ${rel.toStringAsFixed(0)}° > 90°，'
                '直射光进不来，墙上只有天光漫射。',
            Colors.orange.shade800,
          )
        : out.visibleRatio < 0.005
            ? (
                '此刻没有直射光斑',
                '太阳方位 ${sunAz.toStringAsFixed(0)}°，与窗面夹角约 '
                    '${rel.abs().toStringAsFixed(0)}°，高度 '
                    '${out.sunAlt.toStringAsFixed(1)}°。'
                    '入射过掠（cos≈${cosEst.toStringAsFixed(2)}），'
                    '投影面积极小，光斑几乎不可见。',
                Colors.blueGrey.shade700,
              )
            : (
                '直射光斑已生成',
                '太阳方位 ${sunAz.toStringAsFixed(0)}°，与窗面夹角约 '
                    '${rel.abs().toStringAsFixed(0)}°，'
                    '直射 ${out.beam.toStringAsFixed(3)}，'
                    '覆盖墙面 ${(out.visibleRatio * 100).toStringAsFixed(1)}%。',
                Colors.green.shade700,
              );

    return _card(
      '光照诊断',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.35)),
            ),
            child: Text(
              verdict,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
          const SizedBox(height: 10),
          Text(detail, style: const TextStyle(fontSize: 12, height: 1.5)),
          const SizedBox(height: 10),
          _sunDial(sunAz, winAz),
        ],
      ),
    );
  }

  /// 罗盘小图：直观显示太阳方位与窗户朝向的关系。
  Widget _sunDial(double sunAz, double winAz) {
    const size = 132.0;
    return SizedBox(
      height: size,
      child: Center(
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _SunDialPainter(sunAz: sunAz, winAz: winAz),
          ),
        ),
      ),
    );
  }

  String _compass(double az) {
    const names = <String>[
      '北',
      '东北',
      '东',
      '东南',
      '南',
      '西南',
      '西',
      '西北',
    ];
    final idx = (((az % 360) + 22.5) ~/ 45).toInt() % 8;
    return names[idx];
  }

  // ───────────────────────── 文字 ─────────────────────────
  Widget _textPage() {
    final preview = TemplateEngine(Variables.build(
      now: DateTime.now(),
      lat: s.lat,
      lon: s.lon,
      windowAz: s.windowAz,
    )).render(_textCtrl.text);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: <Widget>[
        _card(
          _dirty ? '文字模板 · 未保存' : '文字模板',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextField(
                controller: _textCtrl,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: '例：{greeting}，{season}天 · {sun_alt}°',
                ),
                onChanged: (_) => setState(() => _dirty = true),
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  const Text('现在显示：'),
                  Expanded(
                    child: Text(preview.isEmpty ? '（空）' : preview,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          '字体与位置',
          Column(
            children: <Widget>[
              _dropdown<String>(
                label: '字体',
                value: s.fontFamily,
                items: const <String>[
                  'KaiTi',
                  'STKaiti',
                  'SimSun',
                  'SimHei',
                  'Microsoft YaHei',
                  'FangSong',
                  'LiSu',
                ],
                itemLabel: (e) => e,
                onChanged: (v) => setState(() {
                  s.fontFamily = v ?? s.fontFamily;
                  s.save();
                }),
              ),
              _slider(
                label: '字号',
                value: s.fontRatio,
                min: 0.08,
                max: 0.36,
                display: '${(s.fontRatio * 100).toStringAsFixed(0)}%',
                onChanged: (v) => setState(() => s.fontRatio = v),
              ),
              _slider(
                label: '水平位置',
                value: s.posX,
                min: 10,
                max: 90,
                display: '${s.posX.toStringAsFixed(0)}%',
                onChanged: (v) => setState(() => s.posX = v),
              ),
              _slider(
                label: '垂直位置',
                value: s.posY,
                min: 10,
                max: 90,
                display: '${s.posY.toStringAsFixed(0)}%',
                onChanged: (v) => setState(() => s.posY = v),
              ),
              _dropdown<AgedStyle>(
                label: '年代感',
                value: s.agedStyle,
                items: AgedStyle.values,
                itemLabel: (e) => switch (e) {
                  AgedStyle.clean => '清晰（现代印刷）',
                  AgedStyle.normal => '适度（默认）',
                  AgedStyle.aged => '斑驳（旧标语）',
                },
                onChanged: (v) => setState(() {
                  s.agedStyle = v ?? s.agedStyle;
                  s.save();
                }),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          '画面微调',
          Column(
            children: <Widget>[
              _slider(
                label: '曝光',
                value: s.exposure,
                min: 0.6,
                max: 1.6,
                display: '×${s.exposure.toStringAsFixed(2)}',
                onChanged: (v) => setState(() => s.exposure = v),
              ),
              _slider(
                label: '饱和度',
                value: s.saturation,
                min: 0.6,
                max: 1.5,
                display: '×${s.saturation.toStringAsFixed(2)}',
                onChanged: (v) => setState(() => s.saturation = v),
              ),
              _slider(
                label: '材质耦合',
                value: s.materialCoupling,
                min: 0.0,
                max: 1.0,
                display: s.materialCoupling.toStringAsFixed(2),
                onChanged: (v) => setState(() => s.materialCoupling = v),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '材质耦合让字随墙面起伏或实或虚（0 = 关闭）。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        ExpansionTile(
          title: const Text('变量速查'),
          subtitle: const Text('点右侧按钮复制'),
          children: <Widget>[
            Container(
              constraints: const BoxConstraints(maxHeight: 260),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: SelectableText(
                  Variables.help(),
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            TextButton(
                onPressed: () => setState(() => _dirty = false),
                child: const Text('放弃')),
            const SizedBox(width: 8),
            FilledButton(
                onPressed: _applyAndRender, child: const Text('保存并渲染')),
          ],
        ),
      ],
    );
  }

  // ───────────────────────── 底图 ─────────────────────────
  Widget _backgroundPage() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: <Widget>[
        _card(
          '内置底图',
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: <Widget>[
              for (var i = 0; i < kBuiltinBackgrounds.length; i++)
                _bgTile('内置 ${i + 1}', kBuiltinBackgrounds[i],
                    selected: s.backgrounds.isEmpty && s.builtinIndex == i,
                    onTap: () => setState(() {
                          s.builtinIndex = i;
                          s.save();
                        })),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          '我的底图（每次渲染轮换一张）',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (s.backgrounds.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('还没有导入图片'),
                ),
              for (var i = 0; i < s.backgrounds.length; i++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.image_outlined),
                  title: Text(s.backgrounds[i].split(RegExp(r'[\\/]')).last),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => setState(() {
                      s.backgrounds.removeAt(i);
                      s.save();
                    }),
                  ),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _pickBackground,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('导入图片'),
              ),
              const SizedBox(height: 8),
              const Text(
                '建议使用「平光」材质图：中心与四角的亮度差越小越好。',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: () => widget.scheduler.render(),
            child: const Text('用当前底图渲染'),
          ),
        ),
      ],
    );
  }

  Widget _bgTile(String label, String asset,
      {required bool selected, required VoidCallback onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        width: 180,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          children: <Widget>[
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset(asset, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  // ───────────────────────── 设置 ─────────────────────────
  Widget _settingsPage() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: <Widget>[
        _card(
          '位置与朝向',
          Column(
            children: <Widget>[
              _dropdown<int>(
                label: '城市',
                value: s.cityIndex.clamp(0, kCities.length - 1),
                items: <int>[for (var i = 0; i < kCities.length; i++) i],
                itemLabel: (i) =>
                    '${kCities[i].name}  ${kCities[i].lat.toStringAsFixed(2)}, ${kCities[i].lon.toStringAsFixed(2)}',
                onChanged: (v) => setState(() {
                  s.cityIndex = v ?? 0;
                  s.save();
                }),
              ),
              _dropdown<double>(
                label: '窗户朝向',
                value: kWindowPresets
                    .firstWhere((e) => e.azimuth == s.windowAz,
                        orElse: () => kWindowPresets.first)
                    .azimuth,
                items: kWindowPresets.map((e) => e.azimuth).toList(),
                itemLabel: (az) => kWindowPresets
                    .firstWhere((e) => e.azimuth == az,
                        orElse: () => kWindowPresets.first)
                    .label,
                onChanged: (v) => setState(() {
                  s.windowAz = v ?? s.windowAz;
                  s.save();
                }),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '朝向决定什么时候有直射光斑：东窗上午有光斑，南窗冬季全天有，北窗没有直射。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              const Divider(height: 24),
              _slider(
                label: '窗格行数',
                value: s.gridRows.toDouble(),
                min: 1,
                max: 6,
                display: '${s.gridRows}',
                onChanged: (v) => setState(() {
                  s.gridRows = v.round();
                  s.save();
                }),
              ),
              _slider(
                label: '窗格列数',
                value: s.gridCols.toDouble(),
                min: 1,
                max: 6,
                display: '${s.gridCols}',
                onChanged: (v) => setState(() {
                  s.gridCols = v.round();
                  s.save();
                }),
              ),
              _slider(
                label: '窗框宽度',
                value: s.gridFrameRatio,
                min: 0.02,
                max: 0.30,
                display: '${(s.gridFrameRatio * 100).toStringAsFixed(0)}%',
                onChanged: (v) => setState(() {
                  s.gridFrameRatio = v;
                  s.save();
                }),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          '系统',
          Column(
            children: <Widget>[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('开机自动启动'),
                subtitle: const Text('登录 Windows 后在后台运行'),
                value: s.autostart,
                onChanged: (v) => setState(() {
                  s.autostart = v;
                  s.save();
                  Win32.setAutostart(v, Win32.executablePath());
                }),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('关闭面板时隐藏到托盘'),
                subtitle: const Text('壁纸继续每 3 分钟更新'),
                value: s.hideToTray,
                onChanged: (v) => setState(() {
                  s.hideToTray = v;
                  s.save();
                }),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启动时立即渲染一次'),
                value: s.renderOnStart,
                onChanged: (v) => setState(() {
                  s.renderOnStart = v;
                  s.save();
                }),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.folder_outlined),
                title: const Text('打开壁纸输出目录'),
                onTap: () =>
                    Win32.openPath('${Win32.dataDir().path}\\wallpapers'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'LightWall · 每 3 分钟自动重打一次窗光',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  // ───────────────────────── 小组件 ─────────────────────────
  Widget _card(String title, Widget child) => Card(
        elevation: 0,
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              child,
            ],
          ),
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: <Widget>[
            SizedBox(
                width: 90,
                child: Text(k, style: const TextStyle(fontSize: 12))),
            Text(v),
          ],
        ),
      );

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String display,
    required ValueChanged<double> onChanged,
  }) =>
      Row(
        children: <Widget>[
          SizedBox(
              width: 80,
              child: Text(label, style: const TextStyle(fontSize: 12))),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(display,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12)),
          ),
        ],
      );

  Widget _dropdown<T>({
    required String label,
    required T value,
    required List<T> items,
    required String Function(T) itemLabel,
    required ValueChanged<T?> onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: <Widget>[
            SizedBox(
                width: 80,
                child: Text(label, style: const TextStyle(fontSize: 12))),
            Expanded(
              child: DropdownButton<T>(
                isExpanded: true,
                value: items.contains(value) ? value : null,
                items: <DropdownMenuItem<T>>[
                  for (final it in items)
                    DropdownMenuItem<T>(value: it, child: Text(itemLabel(it))),
                ],
                onChanged: onChanged,
              ),
            ),
          ],
        ),
      );
}

/// 罗盘小图：太阳方位 vs 窗户朝向。
///
/// 用极坐标把"太阳在哪"和"窗朝哪"画在同一张图上，比任何文字都直观：
/// 用户一眼就能看出太阳是不是落在窗户的那半边。
class _SunDialPainter extends CustomPainter {
  _SunDialPainter({required this.sunAz, required this.winAz});

  final double sunAz;
  final double winAz;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 8;

    // 底盘
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFFE8E2D9));
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = const Color(0xFFB9B0A2));

    // 八个方位刻度
    final tick = Paint()
      ..color = const Color(0xFF9A9083)
      ..strokeWidth = 1;
    for (var i = 0; i < 8; i++) {
      final a = (i * 45 - 90) * math.pi / 180;
      canvas.drawLine(
        Offset(c.dx + math.cos(a) * (r - 4), c.dy + math.sin(a) * (r - 4)),
        Offset(c.dx + math.cos(a) * r, c.dy + math.sin(a) * r),
        tick,
      );
    }

    // 窗户扇区（以窗法线为中心 ±60°）
    final winRad = (winAz - 90) * math.pi / 180;
    final rel = ((sunAz - winAz + 540) % 360) - 180;
    final facing = rel.abs() <= 90;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r - 3),
      winRad - math.pi / 3,
      math.pi * 2 / 3,
      true,
      Paint()
        ..color = (facing ? const Color(0xFF4CAF50) : const Color(0xFF9E9E9E))
            .withValues(alpha: 0.18),
    );

    // 窗户法线（短线）
    canvas.drawLine(
      c,
      Offset(c.dx + math.cos(winRad) * (r - 12),
          c.dy + math.sin(winRad) * (r - 12)),
      Paint()
        ..color = const Color(0xFF2E7D32)
        ..strokeWidth = 2.5,
    );

    // 太阳
    final sunRad = (sunAz - 90) * math.pi / 180;
    final sp = Offset(
        c.dx + math.cos(sunRad) * (r - 16), c.dy + math.sin(sunRad) * (r - 16));
    canvas.drawCircle(sp, 8, Paint()..color = const Color(0xFFFFB300));
    canvas.drawCircle(
        sp,
        13,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = const Color(0xFFFFB300).withValues(alpha: 0.55));

    // 中心十字
    canvas.drawLine(Offset(c.dx - 4, c.dy), Offset(c.dx + 4, c.dy), tick);
    canvas.drawLine(Offset(c.dx, c.dy - 4), Offset(c.dx, c.dy + 4), tick);
  }

  @override
  bool shouldRepaint(_SunDialPainter old) =>
      old.sunAz != sunAz || old.winAz != winAz;
}

/// 极简文件选择（优先原生对话框；不可用时提示手动路径）。
class _FileSelectorShim {
  const _FileSelectorShim();

  Future<String?> pickPng() async {
    try {
      final channel = const MethodChannel('lightwall/file_picker');
      final res = await channel.invokeMethod<String>('pickPng');
      return res;
    } catch (_) {
      return null;
    }
  }
}
