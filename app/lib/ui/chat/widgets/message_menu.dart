/// Reading an answer aloud: its Markdown as words, and their language.
library;

/// Markdown as plain words to read aloud: code blocks named, marks dropped.
String speechText(String markdown) => markdown
    .replaceAll(RegExp(r'```[\s\S]*?```'), ' code block ')
    .replaceAll(RegExp(r'[`*_>#~-]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String speechLanguage(String text) =>
    RegExp(r'[㐀-鿿]').hasMatch(text) ? 'zh-CN' : 'en-US';
