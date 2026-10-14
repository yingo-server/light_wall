/// `template.dart` 的交付验证测试（使用 package:test）。
///
/// 说明：正式产出 `template.dart` **不依赖** test 包；本文件仅作交付证明，
/// 覆盖变量 / 函数 / 过滤器 / 嵌套 / 条件 / 转义 / 容错 / 中文数字 /
/// 数字边界 / 运算优先级 / 性能（1 万次渲染 < 2 秒）等场景。
///
/// 运行：`dart test`
library;

import 'package:test/test.dart';
import 'package:lightwall_core/src/template.dart';

/// 固定时间，保证 `random` / `format_time` 结果可复现。
final DateTime fixedNow = DateTime(2026, 10, 14, 9, 5, 3);

TemplateEngine makeEngine([Map<String, Object?>? extra]) {
  return TemplateEngine(
    TemplateContext(
      now: fixedNow,
      values: <String, Object?>{
        'city': '上海',
        'temp': 23.5,
        'rain': false,
        'n': 7,
        'dayCount': 1234,
        'hum': 0.35,
        'name': '  bob  ',
        'now': fixedNow,
        'zero': 0,
        'neg': -3,
        'emptyStr': '',
        'blankStr': '   ',
        'nil': null,
        'list': <int>[1, 2, 3],
        'user': <String, Object?>{'name': '小明', 'age': 17},
        'a': 1,
        'b': 2,
        ...?extra,
      },
    ),
  );
}

void main() {
  late TemplateEngine engine;

  setUp(() => engine = makeEngine());

  // =========================================================================
  group('一、变量插值', () {
    test('基本变量', () {
      expect(engine.render('城市：{city}'), '城市：上海');
      expect(engine.render('{a}-{b}'), '1-2');
    });

    test('数字与浮点显示', () {
      expect(engine.render('{n}'), '7');
      expect(engine.render('{temp}'), '23.5');
      expect(engine.render('{zero}'), '0');
      expect(engine.render('{neg}'), '-3');
    });

    test('嵌套 Map 取值', () {
      expect(engine.render('{user.name}说'), '小明说');
      expect(engine.render('{user.age}'), '17');
    });

    test('null 值渲染为空串（变量存在）', () {
      expect(engine.render('[{}]'.replaceFirst('{}', '{nil}')), '[]');
    });

    test('同一模板重复渲染结果稳定（解析缓存不影响语义）', () {
      final t = '今天是 {city}，{a} + {b}';
      expect(engine.render(t), engine.render(t));
      expect(engine.render(t), '今天是 上海，1 + 2');
    });
  });

  // =========================================================================
  group('二、未定义与容错（永不抛异常）', () {
    test('未定义变量保留原文', () {
      expect(engine.render('{nope}'), '{nope}');
      expect(engine.render('前{nope}后'), '前{nope}后');
    });

    test('未定义的嵌套路径保留原文', () {
      expect(engine.render('{user.phone}'), '{user.phone}');
      expect(engine.render('{ghost.x}'), '{ghost.x}');
    });

    test('未知函数 / 未知过滤器保留原文', () {
      expect(engine.render('{unknownFn(1)}'), '{unknownFn(1)}');
      expect(engine.render('{city|unknownFilter}'), '{city|unknownFilter}');
    });

    test('求值失败（除零、类型错、缺引号）保留原文且不崩', () {
      expect(engine.render('{1 / 0}'), '{1 / 0}');
      expect(engine.render('{1 % 0}'), '{1 % 0}');
      // 数字 + 字符串：引擎按"拼接"处理（对文案模板更友好）
      expect(engine.render('{1 + "abc"}'), '1abc');
      expect(engine.render('{upper("未闭合)}'), '{upper("未闭合)}');
    });

    test('残缺语法（孤立括号、多余 else、未闭合 if）不抛异常', () {
      expect(engine.render('{'), '{');
      expect(engine.render('}{'), '}{');
      expect(engine.render('{else}'), '{else}');
      expect(engine.render('{/if}'), '{/if}');
      // 未闭合的 if 块：正文照常输出，不吞掉用户的文字
      expect(engine.render('{if a}没有闭合'), contains('没有闭合'));
      expect(() => engine.render('{if a}{if b}{if c}'), returnsNormally);
      expect(() => engine.render('{{{{{{'), returnsNormally);
    });

    test('render 对各种畸形输入都不抛异常', () {
      final weird = <String>[
        '{|}',
        '{a|}',
        '{a|:|:}',
        '{fn(,)}',
        '{fn((((}',
        '{1 + + 1}',
        '{if} {/if}',
        '{}',
        '{ }',
        '{{}}',
        '{if 1}{elseif}{else}{/if}',
        '{a b c}',
        '\\',
        '{',
      ];
      for (final t in weird) {
        expect(() => engine.render(t), returnsNormally, reason: t);
      }
    });
  });

  // =========================================================================
  group('三、内置函数', () {
    test('数值函数', () {
      expect(engine.render('{min(3, 5)}'), '3');
      expect(engine.render('{max(3, 5)}'), '5');
      expect(engine.render('{round(2.4)}'), '2');
      expect(engine.render('{round(2.5)}'), '3');
      expect(engine.render('{floor(1.9)}'), '1');
      expect(engine.render('{ceil(1.1)}'), '2');
      expect(engine.render('{abs(-4.2)}'), '4.2');
    });

    test('字符串函数', () {
      expect(engine.render('{upper("abc")}'), 'ABC');
      expect(engine.render('{lower("AbC")}'), 'abc');
      expect(engine.render('{trim("  x  ")}'), 'x');
      expect(engine.render('{pad(7, 2)}'), '07');
      expect(engine.render('{pad(7, 5)}'), '00007');
      expect(engine.render('{repeat("ab", 3)}'), 'ababab');
      expect(engine.render('{len("中文abc")}'), '5');
      expect(engine.render('{len(city)}'), '2');
    });

    test('判断函数', () {
      expect(engine.render('{empty("")}'), 'true');
      expect(engine.render('{empty(zero)}'), 'true');
      expect(engine.render('{empty(city)}'), 'false');
      expect(engine.render('{empty(nope)}'), 'true');
      expect(engine.render('{empty(list)}'), 'false');
      expect(engine.render('{defined(city)}'), 'true');
      expect(engine.render('{defined(nope)}'), 'false');
      expect(engine.render('{defined(user.name)}'), 'true');
    });

    test('随机函数（种子来自 now，同刻可复现）', () {
      expect(engine.render('{random(1, 1)}'), '1');
      final e1 = makeEngine();
      final e2 = makeEngine();
      expect(e1.render('{random(1, 100)}'), e2.render('{random(1, 100)}'));
      final v = int.parse(engine.render('{random(5, 9)}'));
      expect(v, inInclusiveRange(5, 9));
    });

    test('条件函数 if（惰性求值）', () {
      expect(engine.render('{if(true, "A", "B")}'), 'A');
      expect(engine.render('{if(false, "A", "B")}'), 'B');
      expect(engine.render('{if(zero, "A", "B")}'), 'B');
      // 惰性求值的证明：错误只出现在**未被选中**的分支里，
      // 因此整体照常求值成功；若引擎是急切求值，这里会抛错并保留原文。
      expect(engine.render('{if(true, "A", 1 / 0)}'), 'A');
      expect(engine.render('{if(false, 1 / 0, "B")}'), 'B');
      // 被选中的分支自身出错 → 保留原文（引擎的通用容错约定）
      expect(
          engine.render('{if(false, "A", 1 / 0)}'), '{if(false, "A", 1 / 0)}');
    });

    test('参数可以是字符串、数字、嵌套函数、表达式', () {
      expect(engine.render('{upper(city)}'), '上海');
      expect(engine.render('{min(1 + 2, 10)}'), '3');
      expect(engine.render('{max(len(city), 5)}'), '5');
    });

    test('自定义函数（同名覆盖内置、可访问上下文）', () {
      final e = TemplateEngine(
        TemplateContext(
          now: fixedNow,
          values: <String, Object?>{'city': '上海'},
          functions: <String, TemplateFn>{
            'shout': (args, ctx) => '${args[0]}!!',
            'upper': (args, ctx) => '覆盖后的${args[0]}',
          },
        ),
      );
      expect(e.render('{shout(city)}'), '上海!!');
      expect(e.render('{upper(city)}'), '覆盖后的上海');
    });

    test('自定义函数抛异常时保留原文', () {
      final e = TemplateEngine(
        TemplateContext(
          now: fixedNow,
          functions: <String, TemplateFn>{
            'boom': (args, ctx) => throw StateError('炸了'),
          },
        ),
      );
      expect(e.render('{boom()}'), '{boom()}');
    });
  });

  // =========================================================================
  group('四、过滤器', () {
    test('pad2 / padN', () {
      expect(engine.render('{n|pad2}'), '07');
      expect(engine.render('{n|padN}'), '07');
      expect(engine.render('{n|padN:3}'), '007');
      expect(engine.render('{0|pad2}'), '00');
      expect(engine.render('{123|pad2}'), '123');
    });

    test('大小写与去空白', () {
      expect(engine.render('{name|trim|upper}'), 'BOB');
      expect(engine.render('{"ABC"|lower}'), 'abc');
      expect(engine.render('{trim(name)}'), 'bob');
    });

    test('cn / percent / sign / round0', () {
      expect(engine.render('{1234|cn}'), '一千二百三十四');
      expect(engine.render('{hum|percent}'), '35%');
      expect(engine.render('{n|sign}'), '+7');
      expect(engine.render('{neg|sign}'), '-3');
      expect(engine.render('{temp|round0}'), '24');
      expect(engine.render('{0.5|percent}'), '50%');
    });

    test('default:x', () {
      expect(engine.render('{nope|default:"--"}'), '--');
      expect(engine.render('{emptyStr|default:"--"}'), '--');
      expect(engine.render('{blankStr|default:"--"}'), '--');
      expect(engine.render('{nil|default:"--"}'), '--');
      expect(engine.render('{city|default:"--"}'), '上海');
      expect(
          engine.render(
              '{nope|default:fallback}'.replaceFirst('fallback', 'city')),
          '上海');
    });

    test('过滤器链', () {
      expect(engine.render('{name|trim|upper|default:"x"}'), 'BOB');
      expect(engine.render('{nope|default:"7"|pad2}'), '07');
      expect(engine.render('{hum|percent|upper}'), '35%');
    });

    test('函数 + 过滤器组合', () {
      expect(engine.render('{pad(7, 2)|upper}'), '07');
      expect(engine.render('{len(city)|sign}'), '+2');
      expect(engine.render('{upper(city)|cn}'), '上海');
    });
  });

  // =========================================================================
  group('五、条件块', () {
    test('if / else', () {
      expect(engine.render('{if rain}带伞{else}不带伞{/if}'), '不带伞');
      expect(engine.render('{if a}Y{/if}'), 'Y');
      expect(engine.render('{if zero}Y{/if}'), '');
    });

    test('elseif 链', () {
      const t =
          '{if temp > 30}热{elseif temp > 20}舒适{elseif temp > 10}凉{else}冷{/if}';
      expect(engine.render(t), '舒适');
      expect(
        TemplateEngine(TemplateContext(now: fixedNow, values: {'temp': 35}))
            .render(t),
        '热',
      );
      expect(
        TemplateEngine(TemplateContext(now: fixedNow, values: {'temp': 5}))
            .render(t),
        '冷',
      );
    });

    test('块内文本与其它标签正常渲染', () {
      expect(
        engine.render('{if a}城市{city}温度{temp}{else}无{/if}'),
        '城市上海温度23.5',
      );
    });

    test('块内可换行（\\n）', () {
      expect(
        engine.render('{if a}第一行\\n第二行{/if}'),
        '第一行\n第二行',
      );
    });

    test('嵌套条件块（3 层）', () {
      const t = '{if a > 0}外{if b > 1}中{if n > 5}内{/if}{/if}{/if}';
      expect(engine.render(t), '外中内');
    });

    test('嵌套条件块走 else 分支', () {
      const t =
          '{if a > 100}A{else}{if rain}R{else}{if zero}Z{else}END{/if}{/if}{/if}';
      expect(engine.render(t), 'END');
    });

    test('未定义变量作条件 → 假；条件出错 → 假', () {
      expect(engine.render('{if nope}Y{else}N{/if}'), 'N');
      expect(engine.render('{if nope > 1}Y{else}N{/if}'), 'N');
      expect(engine.render('{if nope}{/if}'), '');
    });

    test('真值判定：空串/0/未定义/空集合为假', () {
      expect(engine.render('{if emptyStr}Y{else}N{/if}'), 'N');
      expect(engine.render('{if blankStr}Y{else}N{/if}'), 'N');
      expect(engine.render('{if zero}Y{else}N{/if}'), 'N');
      expect(engine.render('{if nil}Y{else}N{/if}'), 'N');
      expect(engine.render('{if nope}Y{else}N{/if}'), 'N');
      expect(engine.render('{if city}Y{else}N{/if}'), 'Y');
      expect(engine.render('{if list}Y{else}N{/if}'), 'Y');
      expect(engine.render('{if neg}Y{else}N{/if}'), 'Y');
    });
  });

  // =========================================================================
  group('六、表达式：优先级与运算', () {
    test('算术优先级：* / 高于 + -', () {
      expect(engine.render('{1 + 2 * 3}'), '7');
      expect(engine.render('{2 * 3 + 1}'), '7');
      expect(engine.render('{10 - 2 - 3}'), '5');
      expect(engine.render('{10 % 3 + 1}'), '2');
    });

    test('括号分组', () {
      expect(engine.render('{(1 + 2) * 3}'), '9');
      expect(engine.render('{if (1 + 2) * 3 == 9}Y{else}N{/if}'), 'Y');
    });

    test('除法与取余', () {
      expect(engine.render('{4 / 2}'), '2');
      expect(engine.render('{10 / 4}'), '2.5');
      expect(engine.render('{10 % 3}'), '1');
      expect(engine.render('{-10 + 1}'), '-9');
    });

    test('比较运算', () {
      expect(engine.render('{if 2 > 1}Y{else}N{/if}'), 'Y');
      expect(engine.render('{if 2 >= 2}Y{else}N{/if}'), 'Y');
      expect(engine.render('{if 2 < 1}Y{else}N{/if}'), 'N');
      expect(engine.render('{if 2 <= 2}Y{else}N{/if}'), 'Y');
      expect(engine.render('{if "a" == "a"}Y{else}N{/if}'), 'Y');
      expect(engine.render('{if a != b}Y{else}N{/if}'), 'Y');
    });

    test('逻辑运算与优先级（比较 > && > ||）', () {
      expect(engine.render('{if 1 > 0 && 2 > 1}Y{else}N{/if}'), 'Y');
      expect(engine.render('{if 1 > 2 || 2 > 1}Y{else}N{/if}'), 'Y');
      expect(engine.render('{if not (1 > 2)}Y{else}N{/if}'), 'Y');
      expect(engine.render('{if !(1 > 2)}Y{else}N{/if}'), 'Y');
      // false && ... || true → (false && ..) || true → true
      expect(engine.render('{if 1 > 2 && 1 > 2 || 2 > 1}Y{else}N{/if}'), 'Y');
      // and / or / not 关键字等价
      expect(engine.render('{if 1 > 0 and 2 > 1}Y{else}N{/if}'), 'Y');
      expect(engine.render('{if 0 > 1 or 2 > 1}Y{else}N{/if}'), 'Y');
      expect(engine.render('{if !rain and n > 5}Y{else}N{/if}'), 'Y');
    });

    test('逻辑运算短路，不触发右侧错误', () {
      expect(engine.render('{if false && 1 / 0}Y{else}N{/if}'), 'N');
      expect(engine.render('{if true || 1 / 0}Y{else}N{/if}'), 'Y');
    });

    test('字符串拼接与数值自动转换', () {
      expect(engine.render('{"共" + n + "人"}'), '共7人');
      expect(engine.render('{n + 1}'), '8');
      expect(engine.render('{"1" + 2}'), '3');
      expect(engine.render('{temp * 2}'), '47');
    });
  });

  // =========================================================================
  group('七、转义与字面量', () {
    test('{{ 与 }} 输出字面量花括号', () {
      expect(engine.render('{{'), '{');
      expect(engine.render('}}'), '}');
      expect(engine.render('{{city}}'), '{city}');
      expect(engine.render('{{{{'), '{{');
      expect(engine.render('}}}}'), '}}');
    });

    test('正文里的单个 { 或 } 保持原样', () {
      expect(engine.render('集合 {1, 2} 的元素'), '集合 {1, 2} 的元素');
      expect(engine.render('a } b'), 'a } b');
    });

    test('字符串内的 } 不会截断标签', () {
      expect(engine.render('{upper("a}b")}'), 'A}B');
      expect(engine.render("{'x}y'}"), 'x}y');
    });

    test('\\n 转义为换行', () {
      expect(engine.render('第一行\\n第二行'), '第一行\n第二行');
      expect(engine.render('{city}\\n{a}'), '上海\n1');
    });

    test('\\t 与 \\\\ 转义', () {
      expect(engine.render('a\\tb'), 'a\tb');
      expect(engine.render('C:\\\\path'), 'C:\\path');
      expect(engine.render('保留 \\d 原样'), '保留 \\d 原样');
    });
  });

  // =========================================================================
  group('八、中文数字', () {
    test('常用数字 0-10', () {
      expect(engine.render('{cn(0)}'), '零');
      expect(engine.render('{cn(1)}'), '一');
      expect(engine.render('{cn(5)}'), '五');
      expect(engine.render('{cn(9)}'), '九');
      expect(engine.render('{cn(10)}'), '十');
      expect(engine.render('{cn(11)}'), '十一');
      expect(engine.render('{cn(20)}'), '二十');
    });

    test('百千万', () {
      expect(engine.render('{cn(100)}'), '一百');
      expect(engine.render('{cn(101)}'), '一百零一');
      expect(engine.render('{cn(110)}'), '一百一十');
      expect(engine.render('{cn(1000)}'), '一千');
      expect(engine.render('{cn(1234)}'), '一千二百三十四');
      expect(engine.render('{cn(10000)}'), '一万');
      expect(engine.render('{cn(10001)}'), '一万零一');
      expect(engine.render('{cn(100000)}'), '十万');
    });

    test('负数与小数（小数四舍五入取整）', () {
      expect(engine.render('{cn(-5)}'), '负五');
      expect(engine.render('{cn(-1234)}'), '负一千二百三十四');
      expect(engine.render('{cn(3.4)}'), '三');
      expect(engine.render('{cn(3.6)}'), '四');
      expect(engine.render('{cn(-3.6)}'), '负四');
    });

    test('亿级与边界', () {
      expect(engine.render('{cn(100000000)}'), '一亿');
      expect(engine.render('{cn(1234567890)}'), '十二亿三千四百五十六万七千八百九十');
      expect(engine.render('{cn(dayCount)}'), '一千二百三十四');
    });

    test('cn 函数与 cn 过滤器一致', () {
      expect(engine.render('{cn(1234)}'), engine.render('{1234|cn}'));
    });
  });

  // =========================================================================
  group('九、时间格式化', () {
    test('日期占位符', () {
      expect(engine.render('{format_time(now, "yyyy-MM-dd")}'), '2026-10-14');
      expect(engine.render('{format_time(now, "yy/M/d")}'), '26/10/14');
      expect(engine.render('{format_time(now, "M月d日")}'), '10月14日');
    });

    test('时间占位符', () {
      expect(engine.render('{format_time(now, "HH:mm:ss")}'), '09:05:03');
      expect(engine.render('{format_time(now, "H:m:s")}'), '9:5:3');
      expect(engine.render('{format_time(now, "h:mm a")}'), '9:05 AM');
      expect(engine.render('{format_time(now, "A HH:mm")}'), '上午 09:05');
      expect(engine.render('{format_time(now, "SSS")}'), '000');
    });

    test('星期', () {
      expect(engine.render('{format_time(now, "EEE")}'), '周三');
      expect(engine.render('{format_time(now, "EEEE")}'), '星期三');
    });

    test('未支持的占位符原样输出（不会被拆成 MMMM）', () {
      expect(engine.render('{format_time(now, "MMMM")}'), 'MMMM');
      expect(engine.render('{format_time(now, "第M月")}'), '第10月');
    });

    test('缺省参数与 ISO 字符串 / 时间戳', () {
      expect(engine.render('{format_time(now)}'), '2026-10-14 09:05:03');
      expect(engine.render('{format_time("2026-10-14T09:05:03", "HH:mm")}'),
          '09:05');
      expect(
        engine.render('{format_time(1893456000, "yyyy-MM-dd")}'),
        isNot(contains('{')),
      );
    });
  });

  // =========================================================================
  group('十、关键路径：嵌套 / 字符串 / 超长模板', () {
    test('函数嵌套 ≥ 5 层', () {
      expect(
        engine.render('{upper(repeat(lower(trim(upper("  ab  "))), 2))}'),
        'ABAB',
      );
      expect(
        engine.render('{max(min(max(1, 2), 3), round(2.6))}'),
        '3',
      );
    });

    test('条件块嵌套 5 层', () {
      const t =
          '{if a}1{if b}2{if n > 5}3{if a < 2}4{if n == 7}5{/if}{/if}{/if}{/if}{/if}';
      expect(engine.render(t), '12345');
    });

    test('混合嵌套：条件里套函数、函数里套条件变量', () {
      const t =
          '{if len(city) > 1}长度{len(city)}{if upper(city) == "上海"}OK{/if}{/if}';
      expect(engine.render(t), '长度2OK');
    });

    test('超长模板（约 11KB）渲染正确且不丢内容', () {
      final sb = StringBuffer();
      for (var i = 0; i < 250; i++) {
        sb.write('第$i行：{city} {temp|round0}°C {if temp > 20}热{else}凉{/if}\\n');
      }
      final tpl = sb.toString();
      expect(tpl.length, greaterThan(10000));
      final out = engine.render(tpl);
      final lines = out.split('\n');
      expect(lines.length, 251); // 250 行 + 末尾空串
      expect(lines.first, '第0行：上海 24°C 热');
      expect(lines[249], '第249行：上海 24°C 热');
      expect(out.contains('{'), isFalse);
    });

    test('超长纯文本模板（无标签）', () {
      final tpl = 'A' * 12000;
      expect(engine.render(tpl).length, 12000);
    });

    test('深层括号与一元运算不栈溢出', () {
      final deep = '${'(' * 30}1${')' * 30}';
      expect(() => engine.render('{$deep}'), returnsNormally);
      expect(engine.render('{${'!' * 20}true}'), 'true');
    });
  });

  // =========================================================================
  group('十一、静态分析 API', () {
    test('usedVariables 收集并排序', () {
      expect(engine.usedVariables('{city} {a}'), <String>['a', 'city']);
      expect(
        engine.usedVariables('{city} {if temp > 1}{name}{/if} {defined(q)}'),
        <String>['city', 'name', 'q', 'temp'],
      );
      expect(engine.usedVariables('无变量'), isEmpty);
      expect(engine.usedVariables('{city|default:"x"} {if a}1{/if}'),
          <String>['a', 'city']);
      expect(engine.usedVariables('{user.name}'), <String>['user.name']);
    });

    test('validate：合法模板无 issue', () {
      expect(TemplateEngine.validate('{city} {if a}1{else}2{/if}'), isEmpty);
      expect(TemplateEngine.validate('{{转义}} {a|pad2}'), isEmpty);
      expect(TemplateEngine.validate(''), isEmpty);
    });

    test('validate：未闭合块', () {
      final issues = TemplateEngine.validate('{if a} 没有结束');
      expect(issues, isNotEmpty);
      expect(issues.first.message, contains('缺少 {/if}'));
    });

    test('validate：多余的块标签', () {
      final issues = TemplateEngine.validate('{if a} x {/if}{else}');
      expect(issues, isNotEmpty);
      expect(issues.first.message, contains('多余'));
    });

    test('validate：表达式错误带偏移量', () {
      final issues = TemplateEngine.validate('{1 + + }');
      expect(issues, isNotEmpty);
      expect(issues.first.offset, greaterThan(0));
      expect(issues.first.message, contains('表达式'));
    });

    test('validate：不抛异常', () {
      for (final t in <String>['{', '}', '{{', '{if', '{|||}', '{fn(}']) {
        expect(() => TemplateEngine.validate(t), returnsNormally, reason: t);
      }
    });

    test('describeBuiltins 覆盖全部内置函数与过滤器', () {
      final d = describeBuiltins();
      const fns = <String>[
        'min',
        'max',
        'round',
        'floor',
        'ceil',
        'abs',
        'upper',
        'lower',
        'trim',
        'pad',
        'repeat',
        'len',
        'empty',
        'defined',
        'random',
        'cn',
        'if',
        'format_time',
      ];
      const filters = <String>[
        'pad2',
        'padN',
        'upper',
        'lower',
        'trim',
        'cn',
        'percent',
        'sign',
        'default',
        'round0',
      ];
      for (final f in fns) {
        expect(d, contains(f), reason: '函数说明缺失：$f');
      }
      for (final f in filters) {
        expect(d, contains(f), reason: '过滤器说明缺失：$f');
      }
      expect(d.length, greaterThan(300));
    });
  });

  // =========================================================================
  group('十二、性能', () {
    test('1 万次渲染 < 2 秒（同一模板，走解析缓存）', () {
      final e = makeEngine();
      const tpl = '今天是 {format_time(now, "M月d日 EEEE")}\\n'
          '{city} {temp|round0}°C 湿度 {hum|percent}\\n'
          '{if rain}带伞{else}不带伞{/if} 还有 {cn(dayCount)} 天';
      e.render(tpl); // 预热
      final sw = Stopwatch()..start();
      for (var i = 0; i < 10000; i++) {
        e.render(tpl);
      }
      sw.stop();
      // ignore: avoid_print
      print('性能：1 万次渲染（缓存）耗时 ${sw.elapsedMilliseconds} ms');
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });

    test('1 万次渲染（每次模板都不同，无缓存收益）仍可接受', () {
      final e = makeEngine();
      final sw = Stopwatch()..start();
      for (var i = 0; i < 10000; i++) {
        e.render('第 $i 次：{city} {temp|round0} {if a > 0}Y{else}N{/if}');
      }
      sw.stop();
      // ignore: avoid_print
      print('性能：1 万次解析+渲染（无缓存）耗时 ${sw.elapsedMilliseconds} ms');
      expect(sw.elapsedMilliseconds, lessThan(10000));
    });
  });
}
