import 'dart:isolate';

import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cmake.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/dos.dart';
import 'package:re_highlight/languages/elixir.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/gradle.dart';
import 'package:re_highlight/languages/graphql.dart';
import 'package:re_highlight/languages/groovy.dart';
import 'package:re_highlight/languages/haskell.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/latex.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/nginx.dart';
import 'package:re_highlight/languages/objectivec.dart';
import 'package:re_highlight/languages/perl.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/powershell.dart';
import 'package:re_highlight/languages/protobuf.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/r.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scala.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/shell.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/vue.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';

/// Syntax highlighting for code in the chat, tool calls and files: the
/// languages agents work in most, coloured to match the app's palette.
abstract final class CodeHighlighter {
  static final Highlight _engine = Highlight()
    ..registerLanguages({
      'bash': langBash,
      'c': langC,
      'cmake': langCmake,
      'cpp': langCpp,
      'csharp': langCsharp,
      'css': langCss,
      'dart': langDart,
      'diff': langDiff,
      'dockerfile': langDockerfile,
      'dos': langDos,
      'elixir': langElixir,
      'go': langGo,
      'gradle': langGradle,
      'graphql': langGraphql,
      'groovy': langGroovy,
      'haskell': langHaskell,
      'ini': langIni,
      'java': langJava,
      'javascript': langJavascript,
      'json': langJson,
      'kotlin': langKotlin,
      'latex': langLatex,
      'lua': langLua,
      'makefile': langMakefile,
      'markdown': langMarkdown,
      'nginx': langNginx,
      'objectivec': langObjectivec,
      'perl': langPerl,
      'php': langPhp,
      'powershell': langPowershell,
      'protobuf': langProtobuf,
      'python': langPython,
      'r': langR,
      'ruby': langRuby,
      'rust': langRust,
      'scala': langScala,
      'scss': langScss,
      'shell': langShell,
      'sql': langSql,
      'swift': langSwift,
      'typescript': langTypescript,
      'vue': langVue,
      'xml': langXml,
      'yaml': langYaml,
    });

  /// Code larger than this is shown plain: highlighting it would stall a
  /// frame on a phone.
  static const maxLength = 60000;

  static const _extensions = {
    'sh': 'bash',
    'bash': 'bash',
    'zsh': 'bash',
    'fish': 'bash',
    'c': 'c',
    'h': 'c',
    'cc': 'cpp',
    'cpp': 'cpp',
    'cxx': 'cpp',
    'hpp': 'cpp',
    'hh': 'cpp',
    'cs': 'csharp',
    'css': 'css',
    'dart': 'dart',
    'diff': 'diff',
    'patch': 'diff',
    'bat': 'dos',
    'cmd': 'dos',
    'ex': 'elixir',
    'exs': 'elixir',
    'go': 'go',
    'gradle': 'gradle',
    'graphql': 'graphql',
    'gql': 'graphql',
    'groovy': 'groovy',
    'hs': 'haskell',
    'ini': 'ini',
    'toml': 'ini',
    'cfg': 'ini',
    'conf': 'ini',
    'properties': 'ini',
    'java': 'java',
    'js': 'javascript',
    'jsx': 'javascript',
    'mjs': 'javascript',
    'cjs': 'javascript',
    'json': 'json',
    'jsonc': 'json',
    'json5': 'json',
    'arb': 'json',
    'lock': 'json',
    'kt': 'kotlin',
    'kts': 'kotlin',
    'tex': 'latex',
    'lua': 'lua',
    'mk': 'makefile',
    'md': 'markdown',
    'markdown': 'markdown',
    'm': 'objectivec',
    'mm': 'objectivec',
    'pl': 'perl',
    'php': 'php',
    'ps1': 'powershell',
    'psm1': 'powershell',
    'proto': 'protobuf',
    'py': 'python',
    'pyi': 'python',
    'r': 'r',
    'rb': 'ruby',
    'rs': 'rust',
    'scala': 'scala',
    'scss': 'scss',
    'sass': 'scss',
    'sql': 'sql',
    'swift': 'swift',
    'ts': 'typescript',
    'tsx': 'typescript',
    'mts': 'typescript',
    'cts': 'typescript',
    'vue': 'vue',
    'html': 'xml',
    'htm': 'xml',
    'xml': 'xml',
    'svg': 'xml',
    'plist': 'xml',
    'xaml': 'xml',
    'csproj': 'xml',
    'yml': 'yaml',
    'yaml': 'yaml',
  };

  static const _fileNames = {
    'dockerfile': 'dockerfile',
    'makefile': 'makefile',
    'gnumakefile': 'makefile',
    'cmakelists.txt': 'cmake',
    'nginx.conf': 'nginx',
    '.bashrc': 'bash',
    '.zshrc': 'bash',
  };

  /// The language a file is written in, from its name; null when unknown.
  static String? languageForPath(String path) {
    final name = path.split(RegExp(r'[/\\]')).last.toLowerCase();
    if (_fileNames[name] case final language?) return language;
    final dot = name.lastIndexOf('.');
    if (dot < 0) return null;
    return _extensions[name.substring(dot + 1)];
  }

  /// [language] as a fence or a file would name it (`ts`, `py`, `sh`…),
  /// resolved to a registered one; null when unknown.
  static String? resolve(String? language) {
    final name = language?.trim().toLowerCase();
    if (name == null || name.isEmpty) return null;
    if (_extensions[name] case final language?) return language;
    return _engine.getLanguage(name) != null ? name : null;
  }

  /// Code up to this length is tokenised on the spot; longer code goes to a
  /// background isolate so a frame never waits on it.
  static const inlineLength = 4000;

  static final _cache = <(String, int, int), List<Token>>{};

  /// [code] split into runs of text with the scope that colours each.
  /// Pure Dart, so it runs on any isolate.
  static List<Token> tokens(String code, String language) {
    final resolved = resolve(language);
    if (resolved == null || code.length > maxLength) return [(code, null)];
    try {
      final renderer = _TokenRenderer();
      _engine.highlight(code: code, language: resolved).render(renderer);
      return renderer.tokens;
    } catch (_) {
      return [(code, null)];
    }
  }

  /// Tokens from the cache, or null when they still have to be worked out.
  static List<Token>? cachedTokens(String code, String? language) {
    if (language == null) return [(code, null)];
    if (code.length <= inlineLength) return tokens(code, language);
    final key = (language, code.length, code.hashCode);
    final hit = _cache.remove(key);
    if (hit != null) _cache[key] = hit;
    return hit;
  }

  /// Tokens for long code, worked out on a background isolate and cached.
  static Future<List<Token>> tokensLater(String code, String language) async {
    final key = (language, code.length, code.hashCode);
    final result = await Isolate.run(() => tokens(code, language));
    _cache[key] = result;
    while (_cache.length > 48) {
      _cache.remove(_cache.keys.first);
    }
    return result;
  }

  /// [tokens] as one span in the theme for [brightness].
  static TextSpan spans(
    List<Token> tokens,
    TextStyle style,
    Brightness brightness,
  ) {
    final theme = brightness == Brightness.dark ? _dark : _light;
    return TextSpan(
      style: style,
      children: [
        for (final (text, scope) in tokens)
          TextSpan(text: text, style: scope == null ? null : theme[scope]),
      ],
    );
  }

  /// [code] as coloured spans; plain when the language is unknown. For short
  /// code; long code goes through [cachedTokens] and [tokensLater].
  static TextSpan highlight(
    String code, {
    required String? language,
    required TextStyle style,
    required Brightness brightness,
  }) {
    final resolved = resolve(language);
    if (resolved == null || code.length > maxLength) {
      return TextSpan(text: code, style: style);
    }
    return spans(tokens(code, resolved), style, brightness);
  }

  static Map<String, TextStyle> _theme({
    required Color keyword,
    required Color string,
    required Color number,
    required Color comment,
    required Color title,
    required Color type,
    required Color attr,
    required Color meta,
  }) {
    TextStyle c(Color color) => TextStyle(color: color);
    return {
      'keyword': c(keyword),
      'meta-keyword': c(keyword),
      'selector-tag': c(keyword),
      'template-tag': c(keyword),
      'built_in': c(type),
      'type': c(type),
      'title.class_': c(type),
      'title.class_.inherited__': c(type),
      'class': c(type),
      'literal': c(number),
      'number': c(number),
      'symbol': c(number),
      'variable.constant_': c(number),
      'string': c(string),
      'meta-string': c(string),
      'regexp': c(string),
      'char.escape_': c(string),
      'title': c(title),
      'title.function_': c(title),
      'function': c(title),
      'section': c(title),
      'name': c(keyword),
      'tag': c(meta),
      'attr': c(attr),
      'attribute': c(attr),
      'property': c(attr),
      'selector-attr': c(attr),
      'selector-class': c(attr),
      'selector-id': c(attr),
      'params': const TextStyle(),
      'variable': c(attr),
      'variable.language_': c(keyword),
      'template-variable': c(attr),
      'subst': const TextStyle(),
      'meta': c(meta),
      'doctag': c(meta),
      'bullet': c(keyword),
      'comment': TextStyle(color: comment, fontStyle: FontStyle.italic),
      'quote': TextStyle(color: comment, fontStyle: FontStyle.italic),
      'emphasis': const TextStyle(fontStyle: FontStyle.italic),
      'strong': const TextStyle(fontWeight: FontWeight.w600),
      'addition': c(string),
      'deletion': c(const Color(0xFFE5534B)),
    };
  }

  static final _dark = _theme(
    keyword: const Color(0xFFE9B96E),
    string: const Color(0xFFA5D6A7),
    number: const Color(0xFFF2A07B),
    comment: const Color(0xFF6E6E78),
    title: const Color(0xFF8AB4F8),
    type: const Color(0xFF7FD1C7),
    attr: const Color(0xFFD7BA7D),
    meta: const Color(0xFFB39DDB),
  );

  static final _light = _theme(
    keyword: const Color(0xFF9A5B00),
    string: const Color(0xFF2E7D32),
    number: const Color(0xFFB0521E),
    comment: const Color(0xFF8E8E93),
    title: const Color(0xFF1F5FBF),
    type: const Color(0xFF0F766E),
    attr: const Color(0xFF8A5A00),
    meta: const Color(0xFF6A3FB5),
  );
}

/// A run of text and the highlight scope that colours it, if any.
typedef Token = (String, String?);

/// Flattens the highlighter's nested scopes: each run takes the innermost
/// scope the theme colours.
class _TokenRenderer implements HighlightRenderer {
  final tokens = <Token>[];
  final _scopes = <String?>[];

  @override
  void addText(String text) {
    String? scope;
    for (final candidate in _scopes.reversed) {
      if (candidate != null && CodeHighlighter._dark.containsKey(candidate)) {
        scope = candidate;
        break;
      }
    }
    if (tokens.isNotEmpty && tokens.last.$2 == scope) {
      tokens[tokens.length - 1] = (tokens.last.$1 + text, scope);
    } else {
      tokens.add((text, scope));
    }
  }

  @override
  void openNode(DataNode node) => _scopes.add(node.scope);

  @override
  void closeNode(DataNode node) => _scopes.removeLast();
}

extension CodeHighlightContext on BuildContext {
  /// [code] highlighted in the current theme with [style].
  TextSpan highlightCode(String code, String? language, TextStyle style) =>
      CodeHighlighter.highlight(
        code,
        language: language,
        style: style,
        brightness: Theme.of(this).brightness,
      );
}

/// Kept here so the theme has one home; the monospace face for code.
TextStyle codeTextStyle(BuildContext context, {double size = 12.5}) =>
    context.typo.mono.copyWith(fontSize: size, height: 1.55);
