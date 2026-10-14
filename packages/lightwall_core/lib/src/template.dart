/// 纯 Dart 通用模板 / 变量引擎（零第三方依赖，不依赖 Flutter）。
///
/// 场景：为「桌面壁纸叠字」这类需要高频（如每 3 分钟一次）刷新的中文文案提供
/// 模板渲染能力 —— 变量插值、条件块、内置函数、过滤器、字面量转义。
///
/// ## 设计原则
/// * **永不抛异常**：未定义变量、求值失败、语法错误一律退化为「保留原文」，
///   绝不把异常抛给调用方（[TemplateEngine.render] 保证有返回值）。
/// * **无业务内置变量**：所有业务数据（城市、温度、日程…）由调用方通过
///   [TemplateContext.values] 注入；引擎只内置「通用能力」函数与过滤器。
/// * **纯 Dart**：只依赖 `dart:core` 与 `dart:math`。
///
/// ## 语法速查
/// ```
/// {name}                        变量插值（未定义则原样保留 {name}）
/// {fn(a, b)}                    函数调用，参数可为字符串/数字/嵌套函数/表达式
/// {name | upper}                过滤器
/// {fn(x) | pad2 | default:"--"} 过滤器链
/// {if a > 1} ... {elseif b} ... {else} ... {/if}   条件块（可嵌套）
/// {{  }}                         输出字面量 { 和 }
/// \n \t \\                      文本区段中的转义
/// ```
///
/// ## 快速上手
/// ```dart
/// final ctx = TemplateContext(
///   now: DateTime.now(),
///   values: {'city': '上海', 'temp': 23.5, 'rain': false},
/// );
/// final engine = TemplateEngine(ctx);
/// print(engine.render('{city} {temp|round0}°C{if rain} 有雨{else} 无雨{/if}'));
/// // => 上海 24°C 无雨
/// ```
///
/// 详见 [describeBuiltins] 生成的中文帮助文本。
library template_engine;

import 'dart:math' as math;

// ===========================================================================
// 一、公共类型
// ===========================================================================

/// 自定义函数签名，用于 `{fn(arg1, arg2)}`。
///
/// * [args] 是**已求值**的实参列表；若某个实参本身未定义，其值为
///   [TemplateUndefined.instance]，函数通常应原样透传该值。
/// * [ctx] 为当前模板上下文，函数内可读取 [TemplateContext.values] 与
///   [TemplateContext.now]。
/// * 返回值为 [TemplateUndefined.instance] → 引擎「保留原文」；
///   返回 `null` → 渲染为空字符串。
typedef TemplateFn = Object? Function(List<Object?> args, TemplateContext ctx);

/// 「未定义」哨兵值。
///
/// 引擎用它区分两种「空」：
/// * 变量 / 属性路径**不存在** → `TemplateUndefined.instance` → 渲染时**保留原文**；
/// * 变量存在但值为 `null` 或空串 → 正常渲染（`null` → `''`）。
///
/// 自定义函数收到该值时应尽量原样返回，以继续传播「未定义」语义。
class TemplateUndefined {
  const TemplateUndefined._();

  /// 全局唯一实例（用 `identical(x, TemplateUndefined.instance)` 判断）。
  static const TemplateUndefined instance = TemplateUndefined._();

  @override
  String toString() => '';
}

/// 模板上下文：由调用方注入当前时间、变量表、函数表。
///
/// 引擎自身不注入任何业务变量；典型用法是把 `now` 也塞进变量表：
/// ```dart
/// final ctx = TemplateContext(now: DateTime.now());
/// ctx.values['now'] = ctx.now;
/// ```
class TemplateContext {
  TemplateContext({
    required this.now,
    Map<String, Object?>? values,
    Map<String, TemplateFn>? functions,
  })  : values = values ?? <String, Object?>{},
        functions = functions ?? <String, TemplateFn>{};

  /// 当前时间（测试时可固定）。内置 `random` 用它派生随机种子，
  /// `format_time` 也常以它为输入。
  DateTime now;

  /// 变量表。`{name}` 从这里取值，支持 `a.b.c` 形式的嵌套 Map 取值。
  final Map<String, Object?> values;

  /// 自定义函数表。**同名时优先于内置函数**（可覆盖内置实现）。
  final Map<String, TemplateFn> functions;

  /// 出错时是否打印调试日志（默认关闭）。
  bool verbose = false;

  /// 便捷读取，供自定义函数使用。
  Object? operator [](String name) => values[name];

  /// 变量是否存在（值为 `null` 也算存在）。
  bool has(String name) => values.containsKey(name);
}

/// 模板语法检查结果项。
class TemplateIssue {
  const TemplateIssue(this.message, this.offset);

  /// 中文错误描述。
  final String message;

  /// 在模板字符串中的字符下标（从 0 开始），可用于编辑器高亮定位。
  final int offset;

  @override
  String toString() => '[offset $offset] $message';
}

// ===========================================================================
// 二、内部错误
// ===========================================================================

/// 表达式解析错误（内部使用，只在 `validate` 中被翻译成 [TemplateIssue]）。
class _SyntaxError implements Exception {
  _SyntaxError(this.message, this.offset);
  final String message;
  final int offset;
  @override
  String toString() => '$message (offset $offset)';
}

/// 求值错误（内部使用）。抛出后由 tag 渲染层捕获 → 输出原文。
class _EvalError implements Exception {
  _EvalError(this.message);
  final String message;
  @override
  String toString() => message;
}

// ===========================================================================
// 三、表达式 AST
// ===========================================================================

/// 表达式节点基类。
sealed class TExpr {
  const TExpr();
}

/// 字面量：数字 / 字符串 / `true` / `false` / `null`。
class TLiteral extends TExpr {
  const TLiteral(this.value);
  final Object? value;
}

/// 变量引用，支持 `a.b.c` 形式的嵌套路径（[name] 为完整路径）。
class TVar extends TExpr {
  const TVar(this.name);
  final String name;
}

/// 函数调用 `fn(a, b)`。
class TCall extends TExpr {
  const TCall(this.name, this.args);
  final String name;
  final List<TExpr> args;
}

/// 一元运算：`!` `not` `-` `+`。
class TUnary extends TExpr {
  const TUnary(this.op, this.operand);
  final String op;
  final TExpr operand;
}

/// 二元运算：`|| or && and == != > >= < <= + - * / %`。
class TBinary extends TExpr {
  const TBinary(this.op, this.left, this.right);
  final String op;
  final TExpr left;
  final TExpr right;
}

/// 单个过滤器调用：`| name` 或 `| name:arg1,arg2`。
class _FilterCall {
  _FilterCall(this.name, this.args, this.offset);
  final String name;
  final List<TExpr> args;
  final int offset;
}

/// 一条「表达式 + 过滤器链」，即一个 `{...}` 标签的完整语义。
///
/// 继承 [TExpr]，因此可以作为基元出现在括号分组里（如 `{(a|upper)}`）。
class _Pipeline extends TExpr {
  const _Pipeline(this.base, this.filters);
  final TExpr base;
  final List<_FilterCall> filters;
}

// ===========================================================================
// 四、词法分析
// ===========================================================================

/// 表达式 token。
class _Tok {
  _Tok(this.kind, this.value, this.start);
  final String kind; // 'num' | 'str' | 'id' | 'op' | 'eof'
  final Object? value;
  final int start;
  @override
  String toString() => '$kind($value)@$start';
}

/// 表达式词法分析器。[base] 为本段源码在原始模板中的绝对偏移，
/// 使报错偏移量可以直接映射回模板字符串。
class _ExprLexer {
  _ExprLexer(this.s, this.base) {
    _run();
  }

  final String s;
  final int base;
  int i = 0;
  final List<_Tok> toks = <_Tok>[];

  static final RegExp _idStart = RegExp(r'[\p{L}_$]', unicode: true);
  static final RegExp _idPart = RegExp(r'[\p{L}\p{N}_$]', unicode: true);

  static const List<String> _twoCharOps = <String>[
    '>=',
    '<=',
    '==',
    '!=',
    '&&',
    '||',
  ];
  static const String _oneCharOps = '+-*/%><!(),|:';

  static bool _isDigit(String c) {
    final u = c.codeUnitAt(0);
    return u >= 0x30 && u <= 0x39;
  }

  void _run() {
    final n = s.length;
    while (i < n) {
      final c = s[i];
      final cu = c.codeUnitAt(0);
      if (cu == 0x20 || cu == 0x09 || cu == 0x0A || cu == 0x0D) {
        i++;
        continue;
      }
      final st = i;

      // ---- 数字 ----
      if (_isDigit(c) || (c == '.' && i + 1 < n && _isDigit(s[i + 1]))) {
        while (i < n && _isDigit(s[i])) {
          i++;
        }
        if (i + 1 < n && s[i] == '.' && _isDigit(s[i + 1])) {
          i++;
          while (i < n && _isDigit(s[i])) {
            i++;
          }
        }
        if (i < n && (s[i] == 'e' || s[i] == 'E')) {
          final save = i;
          var j = i + 1;
          if (j < n && (s[j] == '+' || s[j] == '-')) j++;
          if (j < n && _isDigit(s[j])) {
            while (j < n && _isDigit(s[j])) {
              j++;
            }
            i = j;
          } else {
            i = save;
          }
        }
        final txt = s.substring(st, i);
        toks.add(_Tok('num', num.parse(txt), base + st));
        continue;
      }

      // ---- 字符串 ----
      if (c == '"' || c == "'") {
        final quote = c;
        i++;
        final sb = StringBuffer();
        var closed = false;
        while (i < n) {
          final ch = s[i];
          if (ch == '\\' && i + 1 < n) {
            final rep = _unescapeChar(s[i + 1]);
            if (rep != null) {
              sb.write(rep);
              i += 2;
              continue;
            }
            sb.write(ch);
            i++;
            continue;
          }
          if (ch == quote) {
            closed = true;
            i++;
            break;
          }
          sb.write(ch);
          i++;
        }
        if (!closed) throw _SyntaxError('字符串缺少结束引号 $quote', base + st);
        toks.add(_Tok('str', sb.toString(), base + st));
        continue;
      }

      // ---- 标识符（允许中文等 Unicode 字母）----
      if (_idStart.hasMatch(c)) {
        i++;
        while (i < n) {
          final ch = s[i];
          if (ch == '.') {
            if (i + 1 < n && _idStart.hasMatch(s[i + 1])) {
              i++;
              continue;
            }
            break;
          }
          if (_idPart.hasMatch(ch)) {
            i++;
            continue;
          }
          break;
        }
        toks.add(_Tok('id', s.substring(st, i), base + st));
        continue;
      }

      // ---- 运算符 ----
      if (i + 1 < n) {
        final two = s.substring(i, i + 2);
        if (_twoCharOps.contains(two)) {
          toks.add(_Tok('op', two, base + st));
          i += 2;
          continue;
        }
      }
      if (_oneCharOps.contains(c)) {
        toks.add(_Tok('op', c, base + st));
        i++;
        continue;
      }
      throw _SyntaxError('无法识别的字符 "$c"', base + st);
    }
    toks.add(_Tok('eof', null, base + n));
  }
}

/// 转义字符映射（字符串字面量内）。
String? _unescapeChar(String c) {
  switch (c) {
    case 'n':
      return '\n';
    case 't':
      return '\t';
    case 'r':
      return '\r';
    case '\\':
      return '\\';
    case '"':
      return '"';
    case "'":
      return "'";
  }
  return null;
}

// ===========================================================================
// 五、语法分析（表达式）
// ===========================================================================

/// 递归下降表达式解析器。
///
/// 优先级（自低到高）：
/// `| filter` < `||/or` < `&&/and` < `!/not` < 比较 < `+ -` < `* / %` < 一元 `-` < 基元
///
/// 为防止恶意模板造成栈溢出，一元运算与括号嵌套深度上限为 [_maxDepth]。
class _ExprParser {
  _ExprParser(this.src, int base) : t = _ExprLexer(src, base).toks;

  static const int _maxDepth = 48;

  final String src;
  final List<_Tok> t;
  int p = 0;
  int depth = 0;

  // ---- 基础工具 ----

  _Tok get _cur => t[p];

  bool _isOp(String s) => _cur.kind == 'op' && _cur.value == s;

  bool _isId(String s) => _cur.kind == 'id' && _cur.value == s;

  bool _eatOp(String s) {
    if (_isOp(s)) {
      p++;
      return true;
    }
    return false;
  }

  void _expectOp(String s) {
    if (!_isOp(s)) {
      throw _SyntaxError('缺少 "$s"', _cur.start);
    }
    p++;
  }

  /// 解析完整表达式并确认没有多余内容。
  TExpr parseFull() {
    final e = parsePipeline();
    if (_cur.kind != 'eof') {
      throw _SyntaxError('表达式后有多余内容 "${_cur.value}"', _cur.start);
    }
    return e;
  }

  /// 入口：解析一条「表达式 + 过滤器链」。
  ///
  /// 没有过滤器时直接返回裸表达式，这样函数实参、条件表达式在静态分析里
  /// 也能被识别成 `TVar` / `TCall` 等原始节点。
  TExpr parsePipeline() {
    final base = _parseOr();
    List<_FilterCall>? filters;
    while (_isOp('|')) {
      final at = t[p].start;
      p++;
      if (_cur.kind != 'id') {
        throw _SyntaxError('过滤器缺少名称', _cur.start);
      }
      final name = _cur.value as String;
      p++;
      List<TExpr>? args;
      if (_eatOp(':')) {
        args = <TExpr>[_parseOr()];
        while (_eatOp(',')) {
          args.add(_parseOr());
        }
      }
      (filters ??= <_FilterCall>[]).add(
        _FilterCall(name, args ?? const <TExpr>[], at),
      );
    }
    if (filters == null) return base;
    return _Pipeline(base, filters);
  }

  // ---- 各优先级层次 ----

  TExpr _parseOr() {
    var left = _parseAnd();
    while (true) {
      if (_isOp('||')) {
        p++;
      } else if (_isId('or')) {
        p++;
      } else {
        break;
      }
      left = TBinary('||', left, _parseAnd());
    }
    return left;
  }

  TExpr _parseAnd() {
    var left = _parseNot();
    while (true) {
      if (_isOp('&&')) {
        p++;
      } else if (_isId('and')) {
        p++;
      } else {
        break;
      }
      left = TBinary('&&', left, _parseNot());
    }
    return left;
  }

  TExpr _parseNot() {
    if (_isOp('!') || _isId('not')) {
      if (++depth > _maxDepth) throw _SyntaxError('表达式嵌套过深', _cur.start);
      p++;
      final operand = _parseNot();
      depth--;
      return TUnary('!', operand);
    }
    return _parseComparison();
  }

  TExpr _parseComparison() {
    var left = _parseAdditive();
    while (true) {
      final v = _cur.value;
      if (_cur.kind == 'op' &&
          (v == '>' ||
              v == '>=' ||
              v == '<' ||
              v == '<=' ||
              v == '==' ||
              v == '!=')) {
        p++;
        left = TBinary(v as String, left, _parseAdditive());
        continue;
      }
      break;
    }
    return left;
  }

  TExpr _parseAdditive() {
    var left = _parseMultiplicative();
    while (true) {
      if (_isOp('+') || _isOp('-')) {
        final op = _cur.value as String;
        p++;
        left = TBinary(op, left, _parseMultiplicative());
        continue;
      }
      break;
    }
    return left;
  }

  TExpr _parseMultiplicative() {
    var left = _parseUnary();
    while (true) {
      if (_isOp('*') || _isOp('/') || _isOp('%')) {
        final op = _cur.value as String;
        p++;
        left = TBinary(op, left, _parseUnary());
        continue;
      }
      break;
    }
    return left;
  }

  TExpr _parseUnary() {
    if (_isOp('-') || _isOp('+')) {
      if (++depth > _maxDepth) throw _SyntaxError('表达式嵌套过深', _cur.start);
      final op = _cur.value as String;
      p++;
      final operand = _parseUnary();
      depth--;
      return op == '-' ? TUnary('-', operand) : operand;
    }
    return _parsePrimary();
  }

  TExpr _parsePrimary() {
    final tk = _cur;
    switch (tk.kind) {
      case 'num':
        p++;
        return TLiteral(tk.value);
      case 'str':
        p++;
        return TLiteral(tk.value);
      case 'id':
        final name = tk.value as String;
        p++;
        switch (name) {
          case 'true':
            return const TLiteral(true);
          case 'false':
            return const TLiteral(false);
          case 'null':
            return const TLiteral(null);
        }
        if (_isOp('(')) {
          p++;
          final args = <TExpr>[];
          if (!_isOp(')')) {
            args.add(parsePipeline());
            while (_eatOp(',')) {
              args.add(parsePipeline());
            }
          }
          _expectOp(')');
          return TCall(name, args);
        }
        return TVar(name);
      case 'op':
        if (tk.value == '(') {
          if (++depth > _maxDepth) throw _SyntaxError('括号嵌套过深', tk.start);
          p++;
          final inner = parsePipeline();
          _expectOp(')');
          depth--;
          return inner;
        }
        break;
    }
    throw _SyntaxError(
      tk.kind == 'eof' ? '表达式意外结束' : '无法解析的内容 "${tk.value}"',
      tk.start,
    );
  }
}

// ===========================================================================
// 六、模板 AST 与解析
// ===========================================================================

/// 模板节点基类。
sealed class _Node {
  const _Node();
}

/// 纯文本（已完成 `\n` / `\t` / `\\` 转义与 `{{` `}}` 还原）。
class _TextNode extends _Node {
  const _TextNode(this.text);
  final String text;
}

/// 一个 `{...}` 标签。保留 [raw] 以便求值失败时「保留原文」。
class _TagNode extends _Node {
  const _TagNode(this.raw, this.expr);
  final String raw;

  /// 标签内的表达式（可能是 [_Pipeline]，也可能是裸表达式）。
  final TExpr expr;
}

/// `{if}` 的一个分支。
class _IfBranch {
  const _IfBranch(this.cond, this.body);
  final TExpr cond;
  final List<_Node> body;
}

/// 条件块。
class _IfNode extends _Node {
  const _IfNode(this.branches, this.elseBody);
  final List<_IfBranch> branches;
  final List<_Node>? elseBody;
}

/// 标签终止符信息。
class _TermTag {
  _TermTag(this.keyword, this.tagStart, this.tagEnd, this.content,
      this.contentStart);
  final String keyword; // 'elseif' | 'else' | '/if'
  final int tagStart; // '{' 的下标
  final int tagEnd; // '}' 的下标
  final String content; // 去首尾空白后的内容
  final int contentStart; // content 在模板中的绝对起点
}

/// 模板解析器：一次性扫描，产出节点树并收集语法问题。
///
/// 永不抛异常（除编程错误外）；遇到坏语法时**降级为普通文本**继续解析。
class _TplParser {
  _TplParser(this.src);

  /// 条件块最大嵌套层数，防止恶意模板造成栈溢出。
  static const int maxNesting = 64;

  final String src;
  int i = 0;
  final List<TemplateIssue> issues = <TemplateIssue>[];

  static bool _isSpace(int c) =>
      c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

  List<_Node> parse() => _parseBody(const <String>{}, 0);

  // ---- 主循环 ----

  /// 解析直到文件结束，或遇到 [stops] 中的块关键字（此时 [i] 停在 `{` 上）。
  List<_Node> _parseBody(Set<String> stops, int depth) {
    final out = <_Node>[];
    final buf = StringBuffer();

    void flush() {
      if (buf.isNotEmpty) {
        out.add(_TextNode(buf.toString()));
        buf.clear();
      }
    }

    final n = src.length;
    while (i < n) {
      final c = src[i];

      // ---- 文本转义 ----
      if (c == '\\') {
        if (i + 1 < n) {
          final nx = src[i + 1];
          if (nx == 'n') {
            buf.write('\n');
            i += 2;
            continue;
          }
          if (nx == 't') {
            buf.write('\t');
            i += 2;
            continue;
          }
          if (nx == 'r') {
            buf.write('\r');
            i += 2;
            continue;
          }
          if (nx == '\\') {
            buf.write('\\');
            i += 2;
            continue;
          }
        }
        buf.write(c);
        i++;
        continue;
      }

      // ---- 标签 ----
      if (c == '{') {
        if (i + 1 < n && src[i + 1] == '{') {
          buf.write('{');
          i += 2;
          continue;
        }
        final close = _findTagEnd(i);
        if (close < 0) {
          // 未闭合的 '{'：当普通文本，继续向后扫（永远不崩）。
          buf.write(c);
          i++;
          continue;
        }
        final raw = src.substring(i, close + 1);
        final inner = src.substring(i + 1, close);
        final content = inner.trim();
        if (content.isEmpty) {
          buf.write(raw);
          i = close + 1;
          continue;
        }
        var contentStart = i + 1;
        while (contentStart < close && _isSpace(src.codeUnitAt(contentStart))) {
          contentStart++;
        }
        final kw = _blockKeyword(content);
        if (kw != null) {
          if (stops.contains(kw)) {
            flush();
            return out; // 停在终止符上，交给上层处理
          }
          if (kw == 'if') {
            flush();
            final node = _parseIf(content, i, close, contentStart, depth);
            if (node == null) {
              buf.write(raw); // 条件非法 → 整块当普通文本
              i = close + 1;
              continue;
            }
            out.add(node);
            continue;
          }
          issues.add(TemplateIssue(
            kw == '/if' ? '多余的 {/if}：没有与之匹配的 {if}' : '多余的 {$kw}：没有与之匹配的 {if}',
            i,
          ));
          buf.write(raw);
          i = close + 1;
          continue;
        }
        // ---- 普通插值标签 ----
        flush();
        try {
          final expr = _ExprParser(inner, i + 1).parseFull();
          out.add(_TagNode(raw, expr));
        } on _SyntaxError catch (e) {
          issues.add(TemplateIssue('表达式错误：${e.message}', e.offset));
          out.add(_TextNode(raw));
        }
        i = close + 1;
        continue;
      }

      // ---- '}' ----
      if (c == '}') {
        if (i + 1 < n && src[i + 1] == '}') {
          buf.write('}');
          i += 2;
          continue;
        }
        buf.write('}');
        i++;
        continue;
      }

      buf.write(c);
      i++;
    }
    flush();
    return out;
  }

  // ---- 条件块 ----

  /// 若条件块整块非法则返回 null（调用方按纯文本处理）。
  _IfNode? _parseIf(
    String content,
    int tagStart,
    int tagEnd,
    int contentStart,
    int depth,
  ) {
    if (depth >= maxNesting) {
      issues.add(TemplateIssue('条件块嵌套超过 $maxNesting 层，已忽略', tagStart));
      return null;
    }
    i = tagEnd + 1; // 越过 {if ...} 标签本身，再解析块体
    final branches = <_IfBranch>[];
    var kw = 'if';
    var curContent = content;
    var curContentStart = contentStart;
    var curTagStart = tagStart;
    var curTagEnd = tagEnd;

    while (true) {
      final kwLen = kw == 'if' ? 2 : _elseKeywordLength(curContent);
      final condStart = _skipSpace(curContentStart + kwLen, curTagEnd);
      final condText = src.substring(condStart, curTagEnd);
      if (condText.trim().isEmpty) {
        issues.add(TemplateIssue('{$kw} 缺少条件表达式', curTagStart));
        return null;
      }
      TExpr cond;
      try {
        cond = _ExprParser(condText, condStart).parseFull();
      } on _SyntaxError catch (e) {
        issues.add(TemplateIssue('条件表达式错误：${e.message}', e.offset));
        return null;
      }

      final body =
          _parseBody(const <String>{'elseif', 'else', '/if'}, depth + 1);
      branches.add(_IfBranch(cond, body));

      final term = _peekTerminator();
      if (term == null) {
        issues.add(TemplateIssue('{if} 块缺少 {/if}（已按文件结尾自动闭合）', curTagStart));
        return _IfNode(branches, null);
      }
      if (term.keyword == '/if') {
        i = term.tagEnd + 1;
        return _IfNode(branches, null);
      }
      if (term.keyword == 'else') {
        i = term.tagEnd + 1;
        final elseBody = _parseBody(const <String>{'/if'}, depth + 1);
        final t2 = _peekTerminator();
        if (t2 == null) {
          issues.add(TemplateIssue('{if} 块缺少 {/if}（已按文件结尾自动闭合）', curTagStart));
          return _IfNode(branches, elseBody);
        }
        if (t2.keyword != '/if') {
          issues.add(TemplateIssue('{else} 之后只能是 {/if}', t2.tagStart));
        }
        i = t2.tagEnd + 1;
        return _IfNode(branches, elseBody);
      }
      // elseif → 继续下一轮
      curContent = term.content;
      curContentStart = term.contentStart;
      curTagStart = term.tagStart;
      curTagEnd = term.tagEnd;
      kw = 'elseif';
    }
  }

  int _skipSpace(int from, int limit) {
    var k = from;
    while (k < limit && _isSpace(src.codeUnitAt(k))) {
      k++;
    }
    return k;
  }

  /// 读取当前位置的块终止符（`{elseif ...}` / `{else}` / `{/if}`），不移动 [i]。
  _TermTag? _peekTerminator() {
    if (i >= src.length || src[i] != '{') return null;
    final close = _findTagEnd(i);
    if (close < 0) return null;
    final inner = src.substring(i + 1, close);
    final content = inner.trim();
    final kw = _blockKeyword(content);
    if (kw == null) return null;
    var cs = i + 1;
    while (cs < close && _isSpace(src.codeUnitAt(cs))) {
      cs++;
    }
    return _TermTag(kw, i, close, content, cs);
  }

  /// 判断标签内容是否为块关键字。
  static String? _blockKeyword(String content) {
    if (content == '/if') return '/if';
    if (content == 'else') return 'else';
    if (content.startsWith('elseif ') || content.startsWith('elseif\t')) {
      return 'elseif';
    }
    if (content.startsWith('else if ') || content.startsWith('else if\t')) {
      return 'elseif';
    }
    if (content == 'if' ||
        content.startsWith('if ') ||
        content.startsWith('if\t')) {
      return 'if';
    }
    return null;
  }

  static int _elseKeywordLength(String content) =>
      content.startsWith('else if') ? 7 : 6;

  /// 找 `{` 对应的 `}`：
  /// * 跳过字符串字面量内部的 `}`（支持 `\"` 转义）；
  /// * 遇到换行视为未闭合（避免正文里一个孤立的 `{` 吞掉整篇模板）。
  int _findTagEnd(int start) {
    var quote = '';
    for (var k = start + 1; k < src.length; k++) {
      final c = src[k];
      if (quote.isNotEmpty) {
        if (c == '\\') {
          k++;
          continue;
        }
        if (c == quote) quote = '';
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
        continue;
      }
      if (c == '}') return k;
      if (c == '\n') return -1;
    }
    return -1;
  }
}

// ===========================================================================
// 七、值语义辅助（真值判定 / 数值转换 / 字符串化）
// ===========================================================================

bool _isUndef(Object? v) => identical(v, TemplateUndefined.instance);

/// 真值判定：null / 未定义 / `false` / `0` / 空串（含纯空白）/ 空集合 → false。
bool _truthy(Object? v) {
  if (v == null || _isUndef(v)) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.trim().isNotEmpty;
  if (v is Iterable) return v.isNotEmpty;
  if (v is Map) return v.isNotEmpty;
  return true;
}

/// 宽松数值转换：num 直取；可解析的字符串转 num；其余返回 null。
num? _toNum(Object? v) {
  if (v is num) return v;
  if (v is String) {
    final s = v.trim();
    if (s.isEmpty) return null;
    return num.tryParse(s);
  }
  return null;
}

/// 转为展示字符串。
String _str(Object? v) {
  if (v == null || _isUndef(v)) return '';
  if (v is String) return v;
  if (v is bool) return v ? 'true' : 'false';
  if (v is int) return v.toString();
  if (v is double) {
    if (v.isNaN) return 'NaN';
    if (v.isInfinite) return v > 0 ? '∞' : '-∞';
    // 整数值的 double 显示为整数（2.0 → "2"），避免 {4/2} 出现 "2.0"
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
    return v.toString();
  }
  if (v is DateTime) {
    return '${_pad4(v.year)}-${_two(v.month)}-${_two(v.day)} '
        '${_two(v.hour)}:${_two(v.minute)}:${_two(v.second)}';
  }
  if (v is Duration) {
    final neg = v.isNegative;
    final d = neg ? -v : v;
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final body =
        h > 0 ? '$h:${_two(m)}:${_two(s)}' : '${_two(d.inMinutes)}:${_two(s)}';
    return neg ? '-$body' : body;
  }
  return v.toString();
}

String _two(int v) => v < 10 ? '0$v' : '$v';
String _pad3(int v) => v.toString().padLeft(3, '0');
String _pad4(int v) => v.toString().padLeft(4, '0');

/// 左补零（保留负号）：`_padNumStr('7', 2)` → `'07'`，`_padNumStr('-7', 3)` → `'-007'`。
String _padNumStr(String s, int len) {
  if (len <= 0) return s;
  final neg = s.startsWith('-');
  var body = neg ? s.substring(1) : s;
  if (body.length < len) body = body.padLeft(len, '0');
  return neg ? '-$body' : body;
}

/// 补零，接受数字或数字字符串；其它类型返回 [TemplateUndefined]。
Object? _padNumValue(Object? v, int len) {
  if (v is num) return _padNumStr(_str(v), len);
  if (v is String) {
    final t = v.trim();
    if (t.isEmpty) return v;
    return _padNumStr(t, len);
  }
  return TemplateUndefined.instance;
}

// ===========================================================================
// 八、中文数字
// ===========================================================================

const List<String> _cnDigits = <String>[
  '零',
  '一',
  '二',
  '三',
  '四',
  '五',
  '六',
  '七',
  '八',
  '九',
];
const List<String> _cnUnits = <String>['', '十', '百', '千'];
const List<String> _cnSections = <String>['', '万', '亿', '万亿', '亿亿'];

/// 数字转中文。小数四舍五入取整；负数加「负」前缀。
/// 例：0→零，7→七，10→十，11→十一，1234→一千二百三十四，
/// 10001→一万零一，1234567890→十二亿三千四百五十六万七千八百九十，-5→负五。
String cnNumber(Object? value) {
  final num? n = _toNum(value);
  if (n == null) return _str(value);
  if (n.isNaN || n.isInfinite) return _str(n);
  var v = n.round();
  if (v == 0) return '零';
  final neg = v < 0;
  var abs = v.abs();
  // 超出 int 安全范围时退化为普通数字（极端情况，够用）
  if (abs > 9007199254740991) return (neg ? '-' : '') + abs.toString();
  final parts = <int>[];
  while (abs > 0) {
    parts.add(abs % 10000);
    abs ~/= 10000;
  }
  final sb = StringBuffer();
  for (var idx = parts.length - 1; idx >= 0; idx--) {
    final p = parts[idx];
    if (p == 0) {
      if (sb.isNotEmpty && idx > 0 && _hasNonZeroBelow(parts, idx)) {
        if (!sb.toString().endsWith('零')) sb.write('零');
      }
      continue;
    }
    if (sb.isNotEmpty && p < 1000) {
      if (!sb.toString().endsWith('零')) sb.write('零');
    }
    sb.write(_cnSection(p));
    sb.write(_cnSections[idx]);
  }
  var out = sb.toString();
  // 10~19 读作「十X」而不是「一十X」
  if (out.startsWith('一十')) out = out.substring(1);
  return neg ? '负$out' : out;
}

bool _hasNonZeroBelow(List<int> parts, int idx) {
  for (var k = 0; k < idx; k++) {
    if (parts[k] != 0) return true;
  }
  return false;
}

/// 1..9999 的节内中文（不含节单位）。
String _cnSection(int n) {
  final s = n.toString();
  final sb = StringBuffer();
  var zeroPending = false;
  for (var k = 0; k < s.length; k++) {
    final d = s.codeUnitAt(k) - 0x30;
    final unit = s.length - 1 - k;
    if (d == 0) {
      zeroPending = sb.isNotEmpty;
      continue;
    }
    if (zeroPending) {
      sb.write('零');
      zeroPending = false;
    }
    sb.write(_cnDigits[d]);
    sb.write(_cnUnits[unit]);
  }
  return sb.toString();
}

// ===========================================================================
// 九、时间格式化
// ===========================================================================

/// 支持的时间占位符（按匹配优先级排列）。
///
/// 匹配规则：占位符后面**不能紧跟同名字母**，因此 `MMMM` / `sss` 这类未支持的
/// 写法会原样输出，而不是被拆成 `MM` + `MM`。
const List<String> _timeTokens = <String>[
  'yyyy',
  'EEEE',
  'SSS',
  'yy',
  'MM',
  'dd',
  'HH',
  'hh',
  'mm',
  'ss',
  'EEE',
  'M',
  'd',
  'H',
  'h',
  'm',
  's',
  'a',
  'A',
];

const List<String> _weekdayShort = <String>['一', '二', '三', '四', '五', '六', '日'];
const List<String> _weekdayLong = <String>['一', '二', '三', '四', '五', '六', '日'];

/// 格式化 [DateTime]。
///
/// 占位符：`yyyy` `yy` `MM` `M` `dd` `d` `HH` `H` `hh` `h` `mm` `m` `ss` `s`
/// `SSS` `a`(AM/PM) `A`(上午/下午) `EEE`(周一) `EEEE`(星期一)。
/// 其它字符原样输出。
String formatDateTime(DateTime d, String pattern) {
  final sb = StringBuffer();
  var k = 0;
  final n = pattern.length;
  while (k < n) {
    var matched = false;
    for (final tok in _timeTokens) {
      if (!pattern.startsWith(tok, k)) continue;
      final after = k + tok.length;
      if (after < n && pattern[after] == tok[tok.length - 1]) continue;
      sb.write(_timeTokenValue(d, tok));
      k = after;
      matched = true;
      break;
    }
    if (!matched) {
      sb.write(pattern[k]);
      k++;
    }
  }
  return sb.toString();
}

String _timeTokenValue(DateTime d, String tok) {
  switch (tok) {
    case 'yyyy':
      return _pad4(d.year);
    case 'yy':
      return _two(d.year % 100);
    case 'MM':
      return _two(d.month);
    case 'M':
      return '${d.month}';
    case 'dd':
      return _two(d.day);
    case 'd':
      return '${d.day}';
    case 'HH':
      return _two(d.hour);
    case 'H':
      return '${d.hour}';
    case 'hh':
      return _two(_hour12(d.hour));
    case 'h':
      return '${_hour12(d.hour)}';
    case 'mm':
      return _two(d.minute);
    case 'm':
      return '${d.minute}';
    case 'ss':
      return _two(d.second);
    case 's':
      return '${d.second}';
    case 'SSS':
      return _pad3(d.millisecond);
    case 'a':
      return d.hour < 12 ? 'AM' : 'PM';
    case 'A':
      return d.hour < 12 ? '上午' : '下午';
    case 'EEE':
      return '周${_weekdayShort[d.weekday - 1]}';
    case 'EEEE':
      return '星期${_weekdayLong[d.weekday - 1]}';
  }
  return tok;
}

int _hour12(int h) {
  final r = h % 12;
  return r == 0 ? 12 : r;
}

/// 把日期类参数统一成 [DateTime]：支持 DateTime / ISO 字符串 / 秒或毫秒时间戳。
DateTime? _toDateTime(Object? v) {
  if (v is DateTime) return v;
  if (v is int) {
    return v.abs() < 100000000000
        ? DateTime.fromMillisecondsSinceEpoch(v * 1000)
        : DateTime.fromMillisecondsSinceEpoch(v);
  }
  if (v is double) return _toDateTime(v.toInt());
  if (v is String) {
    final t = v.trim();
    if (t.isEmpty) return null;
    final asInt = int.tryParse(t);
    if (asInt != null) return _toDateTime(asInt);
    return DateTime.tryParse(t);
  }
  return null;
}

// ===========================================================================
// 十、内置函数
// ===========================================================================

void _arity(List<Object?> a, int min, int max, String name) {
  if (a.length < min || a.length > max) {
    final want = min == max ? '$min' : '$min~$max';
    throw _EvalError('$name 需要 $want 个参数，实际收到 ${a.length} 个');
  }
}

bool _anyUndef(List<Object?> a) {
  for (final v in a) {
    if (_isUndef(v)) return true;
  }
  return false;
}

num _numOrThrow(Object? v, String fn) {
  final n = _toNum(v);
  if (n == null) throw _EvalError('$fn 的参数不是数字：${_str(v)}');
  return n;
}

Object? _fnMin(List<Object?> a, TemplateContext c) {
  _arity(a, 2, 2, 'min');
  if (_anyUndef(a)) return TemplateUndefined.instance;
  final x = _numOrThrow(a[0], 'min');
  final y = _numOrThrow(a[1], 'min');
  return x <= y ? x : y;
}

Object? _fnMax(List<Object?> a, TemplateContext c) {
  _arity(a, 2, 2, 'max');
  if (_anyUndef(a)) return TemplateUndefined.instance;
  final x = _numOrThrow(a[0], 'max');
  final y = _numOrThrow(a[1], 'max');
  return x >= y ? x : y;
}

Object? _fnRound(List<Object?> a, TemplateContext c) {
  _arity(a, 1, 1, 'round');
  if (_anyUndef(a)) return TemplateUndefined.instance;
  return _numOrThrow(a[0], 'round').round();
}

Object? _fnFloor(List<Object?> a, TemplateContext c) {
  _arity(a, 1, 1, 'floor');
  if (_anyUndef(a)) return TemplateUndefined.instance;
  return _numOrThrow(a[0], 'floor').floor();
}

Object? _fnCeil(List<Object?> a, TemplateContext c) {
  _arity(a, 1, 1, 'ceil');
  if (_anyUndef(a)) return TemplateUndefined.instance;
  return _numOrThrow(a[0], 'ceil').ceil();
}

Object? _fnAbs(List<Object?> a, TemplateContext c) {
  _arity(a, 1, 1, 'abs');
  if (_anyUndef(a)) return TemplateUndefined.instance;
  return _numOrThrow(a[0], 'abs').abs();
}

Object? _fnUpper(List<Object?> a, TemplateContext c) {
  _arity(a, 1, 1, 'upper');
  if (_anyUndef(a)) return TemplateUndefined.instance;
  return _str(a[0]).toUpperCase();
}

Object? _fnLower(List<Object?> a, TemplateContext c) {
  _arity(a, 1, 1, 'lower');
  if (_anyUndef(a)) return TemplateUndefined.instance;
  return _str(a[0]).toLowerCase();
}

Object? _fnTrim(List<Object?> a, TemplateContext c) {
  _arity(a, 1, 1, 'trim');
  if (_anyUndef(a)) return TemplateUndefined.instance;
  return _str(a[0]).trim();
}

/// `pad(7, 2)` → `07`
Object? _fnPad(List<Object?> a, TemplateContext c) {
  _arity(a, 2, 2, 'pad');
  if (_anyUndef(a)) return TemplateUndefined.instance;
  final len = _numOrThrow(a[1], 'pad').toInt().clamp(0, 64);
  return _padNumValue(a[0], len);
}

Object? _fnRepeat(List<Object?> a, TemplateContext c) {
  _arity(a, 2, 2, 'repeat');
  if (_anyUndef(a)) return TemplateUndefined.instance;
  final s = _str(a[0]);
  var n = _numOrThrow(a[1], 'repeat').toInt();
  if (n < 0) n = 0;
  if (n > 10000) n = 10000; // 防爆内存
  if (s.isEmpty || n == 0) return '';
  if (s.length * n > 200000) return s;
  return s * n;
}

Object? _fnLen(List<Object?> a, TemplateContext c) {
  _arity(a, 1, 1, 'len');
  if (_anyUndef(a)) return TemplateUndefined.instance;
  final v = a[0];
  if (v is String) return v.runes.length; // 中文/emoji 按字符数计
  if (v is Iterable) return v.length;
  if (v is Map) return v.length;
  return _str(v).runes.length;
}

Object? _fnEmpty(List<Object?> a, TemplateContext c) {
  _arity(a, 1, 1, 'empty');
  if (a.isEmpty) return true;
  return !_truthy(a[0]);
}

/// `defined(name)` 的参数是**变量名**，其特殊处理在 [_evalCall] 中；
/// 这里是「参数已被求值」时的兜底实现。
Object? _fnDefined(List<Object?> a, TemplateContext c) {
  _arity(a, 1, 1, 'defined');
  return !_isUndef(a[0]);
}

/// `random(1, 6)`：闭区间整数，用 `ctx.now` 派生种子（同一时刻结果可复现）。
/// 可选第三参数为整数盐值，用于在同一时刻取到不同序列。
Object? _fnRandom(List<Object?> a, TemplateContext c) {
  _arity(a, 2, 3, 'random');
  if (_anyUndef(a)) return TemplateUndefined.instance;
  var lo = _numOrThrow(a[0], 'random').floor();
  var hi = _numOrThrow(a[1], 'random').floor();
  if (lo > hi) {
    final t = lo;
    lo = hi;
    hi = t;
  }
  final span = hi - lo + 1;
  if (span <= 0) return lo;
  if (span > 0x3FFFFFFF) {
    throw _EvalError('random 的区间过大');
  }
  var seed = c.now.microsecondsSinceEpoch & 0x7FFFFFFF;
  if (a.length >= 3) {
    final salt = _numOrThrow(a[2], 'random').toInt();
    seed = (seed ^ (salt * 0x9E3779B1)) & 0x7FFFFFFF;
  }
  return lo + math.Random(seed).nextInt(span);
}

Object? _fnCn(List<Object?> a, TemplateContext c) {
  _arity(a, 1, 1, 'cn');
  if (_anyUndef(a)) return TemplateUndefined.instance;
  return cnNumber(a[0]);
}

/// `if(cond, a, b)` —— 常规路径为惰性求值，见 [_evalCall]。
Object? _fnIf(List<Object?> a, TemplateContext c) {
  _arity(a, 2, 3, 'if');
  if (_truthy(a[0])) return a[1];
  return a.length >= 3 ? a[2] : null;
}

Object? _fnFormatTime(List<Object?> a, TemplateContext c) {
  _arity(a, 1, 2, 'format_time');
  if (a.isNotEmpty && _isUndef(a[0])) return TemplateUndefined.instance;
  final dt = _toDateTime(a.isNotEmpty ? a[0] : null) ?? c.now;
  final pattern = a.length >= 2 ? _str(a[1]) : 'yyyy-MM-dd HH:mm:ss';
  return formatDateTime(dt, pattern);
}

/// 内置函数表（不含 `defined` / `if` 的惰性特例）。
final Map<String, TemplateFn> _builtinFunctions = <String, TemplateFn>{
  'min': _fnMin,
  'max': _fnMax,
  'round': _fnRound,
  'floor': _fnFloor,
  'ceil': _fnCeil,
  'abs': _fnAbs,
  'upper': _fnUpper,
  'lower': _fnLower,
  'trim': _fnTrim,
  'pad': _fnPad,
  'repeat': _fnRepeat,
  'len': _fnLen,
  'empty': _fnEmpty,
  'defined': _fnDefined,
  'random': _fnRandom,
  'cn': _fnCn,
  'if': _fnIf,
  'format_time': _fnFormatTime,
};

// ===========================================================================
// 十一、内置过滤器
// ===========================================================================

/// 过滤器签名：`(值, 参数列表, 上下文)`。
typedef _FilterFn = Object? Function(Object?, List<Object?>, TemplateContext);

Object? _fPad2(Object? v, List<Object?> a, TemplateContext c) {
  if (_anyUndef(a) || _isUndef(v)) return TemplateUndefined.instance;
  return _padNumValue(v, 2);
}

/// `padN[:len]`，默认补到 2 位。
Object? _fPadN(Object? v, List<Object?> a, TemplateContext c) {
  if (_anyUndef(a) || _isUndef(v)) return TemplateUndefined.instance;
  var len = 2;
  if (a.isNotEmpty) len = _numOrThrow(a[0], 'padN').toInt().clamp(0, 64);
  return _padNumValue(v, len);
}

Object? _fUpper(Object? v, List<Object?> a, TemplateContext c) {
  if (_isUndef(v)) return TemplateUndefined.instance;
  return _str(v).toUpperCase();
}

Object? _fLower(Object? v, List<Object?> a, TemplateContext c) {
  if (_isUndef(v)) return TemplateUndefined.instance;
  return _str(v).toLowerCase();
}

Object? _fTrim(Object? v, List<Object?> a, TemplateContext c) {
  if (_isUndef(v)) return TemplateUndefined.instance;
  return _str(v).trim();
}

Object? _fCn(Object? v, List<Object?> a, TemplateContext c) {
  if (_isUndef(v)) return TemplateUndefined.instance;
  return cnNumber(v);
}

/// `0.35` → `35%`
Object? _fPercent(Object? v, List<Object?> a, TemplateContext c) {
  if (_isUndef(v)) return TemplateUndefined.instance;
  final n = _toNum(v);
  if (n == null) throw _EvalError('percent 需要数字，实际是 ${_str(v)}');
  final scaled = n * 100.0;
  if (a.isNotEmpty) {
    final d = _numOrThrow(a[0], 'percent').toInt().clamp(0, 10);
    return '${scaled.toStringAsFixed(d)}%';
  }
  if (scaled == scaled.roundToDouble() && scaled.abs() < 1e15) {
    return '${scaled.toInt()}%';
  }
  var s = scaled.toStringAsFixed(2);
  if (s.contains('.')) {
    while (s.endsWith('0')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  return '$s%';
}

/// 正数加 `+` 前缀。
Object? _fSign(Object? v, List<Object?> a, TemplateContext c) {
  if (_isUndef(v)) return TemplateUndefined.instance;
  final n = _toNum(v);
  if (n == null) return _str(v);
  final s = _str(n);
  return n > 0 ? '+$s' : s;
}

/// `default:x`：未定义 / null / 空串（纯空白）时用 `x`。
Object? _fDefault(Object? v, List<Object?> a, TemplateContext c) {
  if (a.isEmpty) throw _EvalError('default 需要一个参数，如 default:"--"');
  final fallback = a[0];
  if (_isUndef(v) || v == null) return fallback;
  if (v is String && v.trim().isEmpty) return fallback;
  if (v is Iterable && v.isEmpty) return fallback;
  if (v is Map && v.isEmpty) return fallback;
  return v;
}

/// 四舍五入取整。
Object? _fRound0(Object? v, List<Object?> a, TemplateContext c) {
  if (_isUndef(v)) return TemplateUndefined.instance;
  final n = _toNum(v);
  if (n == null) throw _EvalError('round0 需要数字，实际是 ${_str(v)}');
  return n.round();
}

/// 内置过滤器表。
final Map<String, _FilterFn> _builtinFilters = <String, _FilterFn>{
  'pad2': _fPad2,
  'padN': _fPadN,
  'upper': _fUpper,
  'lower': _fLower,
  'trim': _fTrim,
  'cn': _fCn,
  'percent': _fPercent,
  'sign': _fSign,
  'default': _fDefault,
  'round0': _fRound0,
};

// ===========================================================================
// 十二、求值
// ===========================================================================

/// 变量查找：先整体命中，再按 `a.b.c` 逐级下钻 Map / List。
/// 找不到返回 [TemplateUndefined.instance]（→ 保留原文）。
Object? _lookupVar(TemplateContext ctx, String path) {
  if (ctx.values.containsKey(path)) return ctx.values[path];
  final firstDot = path.indexOf('.');
  if (firstDot < 0) return TemplateUndefined.instance;
  final root = path.substring(0, firstDot);
  if (!ctx.values.containsKey(root)) return TemplateUndefined.instance;
  Object? cur = ctx.values[root];
  var idx = firstDot;
  while (idx >= 0) {
    final next = path.indexOf('.', idx + 1);
    final seg = path.substring(idx + 1, next < 0 ? path.length : next);
    if (cur is Map) {
      if (!cur.containsKey(seg)) return TemplateUndefined.instance;
      cur = cur[seg];
    } else if (cur is List) {
      final k = int.tryParse(seg);
      if (k == null || k < 0 || k >= cur.length) {
        return TemplateUndefined.instance;
      }
      cur = cur[k];
    } else {
      return TemplateUndefined.instance;
    }
    idx = next;
  }
  return cur;
}

/// 比较：数值或数字字符串按数值比；两者都是 DateTime 按时间比；
/// 两者都是字符串按字典序；否则报错（→ 保留原文）。
int _compare(Object? l, Object? r) {
  if (_isUndef(l) || _isUndef(r)) {
    throw _EvalError('未定义的变量不能参与比较');
  }
  final ln = _toNum(l);
  final rn = _toNum(r);
  if (ln != null && rn != null) return ln.compareTo(rn);
  if (l is DateTime && r is DateTime) return l.compareTo(r);
  if (l is String && r is String) return l.compareTo(r);
  throw _EvalError('无法比较 ${_str(l)} 与 ${_str(r)}');
}

bool _looseEq(Object? l, Object? r) {
  final lu = _isUndef(l);
  final ru = _isUndef(r);
  if (lu || ru) {
    if (lu && ru) return true;
    return (lu ? r : l) == null;
  }
  if (l == null || r == null) return l == r;
  if (l is bool || r is bool) return l == r;
  if (l is DateTime && r is DateTime) return l.isAtSameMomentAs(r);
  final ln = _toNum(l);
  final rn = _toNum(r);
  if (ln != null && rn != null) return ln == rn;
  return _str(l) == _str(r);
}

Object? _binaryOp(String op, Object? l, Object? r) {
  switch (op) {
    case '==':
      return _looseEq(l, r);
    case '!=':
      return !_looseEq(l, r);
    case '>':
      return _compare(l, r) > 0;
    case '>=':
      return _compare(l, r) >= 0;
    case '<':
      return _compare(l, r) < 0;
    case '<=':
      return _compare(l, r) <= 0;
  }
  if (_isUndef(l) || _isUndef(r)) return TemplateUndefined.instance;

  if (op == '+' && (l is! num || r is! num)) {
    final ln = _toNum(l);
    final rn = _toNum(r);
    if (ln == null || rn == null) return _str(l) + _str(r); // 字符串拼接
    return ln + rn;
  }

  final ln = _toNum(l);
  final rn = _toNum(r);
  if (ln == null || rn == null) {
    throw _EvalError('运算符 $op 需要数字：${_str(l)} , ${_str(r)}');
  }

  switch (op) {
    case '+':
      return ln + rn;
    case '-':
      return ln - rn;
    case '*':
      return ln * rn;
    case '/':
      if (rn == 0) throw _EvalError('除数不能为 0');
      if (ln is int && rn is int && ln % rn == 0) return ln ~/ rn;
      return ln / rn;
    case '%':
      if (rn == 0) throw _EvalError('取余的除数不能为 0');
      return ln % rn;
  }
  throw _EvalError('未知运算符 $op');
}

Object? _eval(TExpr e, TemplateContext ctx) {
  if (e is TLiteral) return e.value;
  if (e is TVar) return _lookupVar(ctx, e.name);
  if (e is _Pipeline) return _evalPipeline(e, ctx);
  if (e is TCall) return _evalCall(e, ctx);
  if (e is TUnary) {
    final v = _eval(e.operand, ctx);
    if (e.op == '!') return !_truthy(v);
    if (_isUndef(v)) return TemplateUndefined.instance;
    final n = _toNum(v);
    if (n == null) throw _EvalError('一元 - 需要数字：${_str(v)}');
    return -n;
  }
  if (e is TBinary) {
    if (e.op == '&&') {
      if (!_truthy(_eval(e.left, ctx))) return false;
      return _truthy(_eval(e.right, ctx));
    }
    if (e.op == '||') {
      if (_truthy(_eval(e.left, ctx))) return true;
      return _truthy(_eval(e.right, ctx));
    }
    return _binaryOp(e.op, _eval(e.left, ctx), _eval(e.right, ctx));
  }
  throw _EvalError('未知表达式节点');
}

Object? _evalCall(TCall e, TemplateContext ctx) {
  // 惰性求值：if(cond, a, b) 只求值被选中的分支，
  // 未选中的分支即使含错误（如除零、未知函数）也不会影响结果。
  if (e.name == 'if' && e.args.length == 3) {
    final c = _eval(e.args[0], ctx);
    return _eval(_truthy(c) ? e.args[1] : e.args[2], ctx);
  }

  final user = ctx.functions[e.name];
  if (user == null) {
    // `defined(name)`：参数取变量名而非值，需在求值前拦截。
    if (e.name == 'defined') {
      if (e.args.isEmpty) throw _EvalError('defined(name) 需要一个参数');
      final a0 = e.args[0];
      if (a0 is TVar) return !_isUndef(_lookupVar(ctx, a0.name));
      if (a0 is TLiteral && a0.value is String) {
        return !_isUndef(_lookupVar(ctx, a0.value as String));
      }
      return !_isUndef(_eval(a0, ctx));
    }
    // `if(cond, a, b)`：惰性求值，未选中的分支不执行。
    if (e.name == 'if') {
      _arity(e.args, 2, 3, 'if');
      if (_truthy(_eval(e.args[0], ctx))) return _eval(e.args[1], ctx);
      return e.args.length >= 3 ? _eval(e.args[2], ctx) : null;
    }
  }
  final fn = user ?? _builtinFunctions[e.name];
  if (fn == null) throw _EvalError('未知函数 "${e.name}"');
  final args = <Object?>[];
  for (final a in e.args) {
    args.add(_eval(a, ctx));
  }
  try {
    return fn(args, ctx);
  } on _EvalError {
    rethrow;
  } catch (err) {
    throw _EvalError('函数 ${e.name} 执行失败：$err');
  }
}

Object? _applyFilter(
  String name,
  Object? value,
  List<Object?> args,
  TemplateContext ctx,
) {
  final f = _builtinFilters[name];
  if (f != null) return f(value, args, ctx);
  final user = ctx.functions[name];
  if (user != null) {
    return user(<Object?>[value, ...args], ctx);
  }
  throw _EvalError('未知过滤器 "$name"');
}

Object? _evalPipeline(_Pipeline p, TemplateContext ctx) {
  var v = _eval(p.base, ctx);
  for (final f in p.filters) {
    final args = <Object?>[];
    for (final a in f.args) {
      args.add(_eval(a, ctx));
    }
    v = _applyFilter(f.name, v, args, ctx);
  }
  return v;
}

// ===========================================================================
// 十三、对外 API
// ===========================================================================

/// 模板引擎。构造时绑定一个 [TemplateContext]；同一个模板字符串会被缓存解析结果，
/// 因此「每 3 分钟渲染一次同一模板」不会重复解析。
class TemplateEngine {
  TemplateEngine(this.ctx);

  /// 上下文（可随时替换 `now`，或改写 `values`）。
  final TemplateContext ctx;

  /// 解析缓存容量上限。
  static const int cacheLimit = 64;

  final Map<String, List<_Node>> _cache = <String, List<_Node>>{};

  // ---- 渲染 ----

  /// 渲染模板。**永不抛异常**：
  /// 未定义变量 / 求值失败 → 该处输出原文（如 `{city}`）；
  /// 整体异常 → 返回原模板。
  String render(String template) {
    try {
      final sb = StringBuffer();
      _renderNodes(_nodesFor(template), sb);
      return sb.toString();
    } catch (e) {
      if (ctx.verbose) {
        // ignore: avoid_print
        print('[TemplateEngine] 渲染失败，已返回原模板：$e');
      }
      return template;
    }
  }

  List<_Node> _nodesFor(String template) {
    final hit = _cache[template];
    if (hit != null) return hit;
    final parsed = _TplParser(template).parse();
    if (_cache.length >= cacheLimit) {
      _cache.remove(_cache.keys.first);
    }
    _cache[template] = parsed;
    return parsed;
  }

  void _renderNodes(List<_Node> nodes, StringBuffer sb) {
    for (final node in nodes) {
      if (node is _TextNode) {
        sb.write(node.text);
      } else if (node is _TagNode) {
        _renderTag(node, sb);
      } else if (node is _IfNode) {
        var handled = false;
        for (final b in node.branches) {
          if (_truthy(_evalQuiet(b.cond))) {
            _renderNodes(b.body, sb);
            handled = true;
            break;
          }
        }
        if (!handled && node.elseBody != null) {
          _renderNodes(node.elseBody!, sb);
        }
      }
    }
  }

  /// 条件求值：出错（含未定义）视为「假」，不打断渲染。
  Object? _evalQuiet(TExpr e) {
    try {
      return _eval(e, ctx);
    } catch (e2) {
      if (ctx.verbose) {
        // ignore: avoid_print
        print('[TemplateEngine] 条件求值失败，按 false 处理：$e2');
      }
      return false;
    }
  }

  void _renderTag(_TagNode node, StringBuffer sb) {
    try {
      final v = _eval(node.expr, ctx);
      if (_isUndef(v)) {
        sb.write(node.raw); // 未定义 → 保留原文
        return;
      }
      sb.write(_str(v));
    } catch (e) {
      if (ctx.verbose) {
        // ignore: avoid_print
        print('[TemplateEngine] "${node.raw}" 求值失败，保留原文：$e');
      }
      sb.write(node.raw);
    }
  }

  // ---- 静态分析 ----

  /// 模板中引用到的变量名（去重、字典序），供 UI 做「可用变量」提示。
  List<String> usedVariables(String template) {
    try {
      final set = <String>{};
      _collectVars(_nodesFor(template), set);
      final list = set.toList()..sort();
      return list;
    } catch (_) {
      return const <String>[];
    }
  }

  void _collectVars(List<_Node> nodes, Set<String> out) {
    for (final node in nodes) {
      if (node is _TagNode) {
        _collectExprVars(node.expr, out);
      } else if (node is _IfNode) {
        for (final b in node.branches) {
          _collectExprVars(b.cond, out);
          _collectVars(b.body, out);
        }
        if (node.elseBody != null) _collectVars(node.elseBody!, out);
      }
    }
  }

  void _collectExprVars(TExpr e, Set<String> out) {
    if (e is TVar) {
      out.add(e.name);
    } else if (e is TUnary) {
      _collectExprVars(e.operand, out);
    } else if (e is TBinary) {
      _collectExprVars(e.left, out);
      _collectExprVars(e.right, out);
    } else if (e is _Pipeline) {
      _collectExprVars(e.base, out);
      for (final f in e.filters) {
        for (final a in f.args) {
          _collectExprVars(a, out);
        }
      }
    } else if (e is TCall) {
      if (e.name == 'defined' && e.args.isNotEmpty) {
        final a0 = e.args[0];
        if (a0 is TVar) {
          out.add(a0.name);
          return;
        }
      }
      for (final a in e.args) {
        _collectExprVars(a, out);
      }
    }
  }

  /// 语法检查（不执行、不依赖上下文）。返回空列表表示语法正确。
  static List<TemplateIssue> validate(String template) {
    try {
      final p = _TplParser(template);
      p.parse();
      return List<TemplateIssue>.unmodifiable(p.issues);
    } catch (e) {
      return <TemplateIssue>[TemplateIssue('模板解析异常：$e', 0)];
    }
  }
}

/// 内置函数 / 过滤器的中文说明，供 UI 帮助面板直接展示。
String describeBuiltins() => '''【变量】{name}      取变量值；变量不存在时原样保留 {name}
【函数】{fn(a, b)}   调用函数，参数可为字符串 "x"、数字、嵌套函数
【过滤】{v | f}      过滤器，可链式 {v | f1 | f2}，带参 {v | f:'x'}
【条件】{if 表达式} … {elseif 表达式} … {else} … {/if}（可嵌套）
【转义】{{ 输出 {    }} 输出 }    \\n 换行  \\t 制表符

— 内置函数 —
min(a, b)                取较小值
max(a, b)                取较大值
round(x)                 四舍五入取整
floor(x)                 向下取整
ceil(x)                  向上取整
abs(x)                   绝对值
upper(s)                 转大写
lower(s)                 转小写
trim(s)                  去掉首尾空白
pad(n, len)              左补零，pad(7, 2) → 07
repeat(s, n)             s 重复 n 次
len(s)                   字符数（中文/emoji 按 1 个字符计）
empty(x)                 为空（空串/0/未定义/空集合）→ true
defined(name)            变量是否存在（参数写变量名，不加引号）
random(a, b)             闭区间随机整数 [a, b]，同一次渲染可复现
cn(n)                    数字转中文，cn(1234) → 一千二百三十四
if(cond, a, b)           条件取值，惰性求值
format_time(dt, pattern) 时间格式化

— 过滤器 —
pad2          补零到 2 位（数字用），7 → 07
padN[:len]    补零到 len 位（默认 2），7|padN:3 → 007
upper         转大写
lower         转小写
trim          去首尾空白
cn            数字转中文，1234|cn → 一千二百三十四
percent       0.35 → 35%
sign          正数加 +，5|sign → +5
default:x     为空/未定义时用 x，{name|default:'--'}
round0        四舍五入取整，23.5|round0 → 24

— 时间占位符 —
yyyy 年  yy 两位年  MM 月  M 月  dd 日  d 日
HH 24时  H 24时  hh 12时  h 12时  mm 分  m 分  ss 秒  s 秒
SSS 毫秒  a AM/PM  A 上午/下午  EEE 周一  EEEE 星期一
例：format_time(now, 'M月d日 EEEE HH:mm') → 10月14日 星期三 09:30

— 运算符 —
比较 >  >=  <  <=  ==  !=
逻辑 &&  ||  !（也可写 and / or / not）
算术 +  -  *  /  %（+ 遇字符串时做拼接）
括号 ( ) 可分组
真值：空串 / 0 / 未定义 / 空集合 → 假''';
