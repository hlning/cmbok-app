import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../models/book_content.dart';

/// 解析 EPUB / TXT 为 [BookContent]。
/// - EPUB：archive 解 zip + xml 解 container.xml / OPF / XHTML（含 NAV/NCX 目录）。
/// - TXT：UTF-8 优先，回退系统编码（Windows 中文为 GBK），再回退容错 UTF-8。
class BookParser {
  BookParser._();

  /// 解析 EPUB 文件。
  static Future<BookContent> parseEpub(File file) async {
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    // 归一化条目：精确名 -> bytes，附小写名 -> 精确名（大小写回退）
    final entries = <String, Uint8List>{};
    final lowerToName = <String, String>{};
    for (final f in archive) {
      if (!f.isFile) continue;
      final name = f.name;
      final data = _bytesOfFile(f);
      entries[name] = data;
      lowerToName[name.toLowerCase()] = name;
    }

    Uint8List? entryOf(String path) {
      final e = entries[path];
      if (e != null) return e;
      final real = lowerToName[path.toLowerCase()];
      return real == null ? null : entries[real];
    }

    // 1) container.xml -> OPF 路径
    final containerXml = entryOf('META-INF/container.xml');
    if (containerXml == null) {
      throw const FormatException('缺少 META-INF/container.xml');
    }
    final container = XmlDocument.parse(utf8.decode(containerXml));
    final rootFileEl = container.findAllElements('rootfile', namespace: '*').firstOrNull;
    final opfPath = rootFileEl?.getAttribute('full-path');
    if (opfPath == null || opfPath.isEmpty) {
      throw const FormatException('container.xml 未声明 OPF 路径');
    }
    final opfDir = _dirOf(opfPath);
    final opfBytes = entryOf(opfPath);
    if (opfBytes == null) throw FormatException('OPF 不存在：$opfPath');
    final opf = XmlDocument.parse(utf8.decode(opfBytes));

    // 2) metadata
    String? title;
    final titleEl = opf.findAllElements('title', namespace: '*').firstOrNull;
    if (titleEl != null) title = titleEl.innerText.trim();
    String? author;
    final creatorEl = opf.findAllElements('creator', namespace: '*').firstOrNull;
    if (creatorEl != null) author = creatorEl.innerText.trim();

    // 3) manifest：id -> {href, mediaType, properties}
    final manifest = <String, _ManifestItem>{};
    for (final item in opf.findAllElements('item', namespace: '*')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id == null || href == null) continue;
      manifest[id] = _ManifestItem(
        href: href,
        resolvedHref: _resolve(opfDir, href),
        mediaType: item.getAttribute('media-type') ?? '',
        properties: item.getAttribute('properties') ?? '',
      );
    }

    // 4) spine 顺序
    final spine = opf.findAllElements('spine', namespace: '*').firstOrNull;
    final idrefs = <String>[];
    if (spine != null) {
      for (final itemref in spine.findElements('itemref', namespace: '*')) {
        final idref = itemref.getAttribute('idref');
        if (idref != null && manifest.containsKey(idref)) idrefs.add(idref);
      }
    }
    if (idrefs.isEmpty) {
      // 无 spine 则按 manifest 中 XHTML 顺序兜底
      for (final entry in manifest.entries) {
        if (entry.value.mediaType.contains('xhtml')) idrefs.add(entry.key);
      }
    }

    // 5) 目录：文件 -> 标题（NAV 优先，其次 NCX）
    final tocMap = _buildTocMap(opf, manifest, entryOf);

    // 6) 图片资源入 images map
    final images = <String, Uint8List>{};
    for (final item in manifest.values) {
      if (item.mediaType.startsWith('image/')) {
        final data = entryOf(item.resolvedHref);
        if (data != null) images[item.resolvedHref] = data;
      }
    }

    // 7) 按 spine 顺序解每个 XHTML 为 chapter
    final chapters = <BookChapter>[];
    for (var i = 0; i < idrefs.length; i++) {
      final item = manifest[idrefs[i]]!;
      if (!item.mediaType.contains('xhtml') &&
          !item.resolvedHref.toLowerCase().endsWith('.xhtml') &&
          !item.resolvedHref.toLowerCase().endsWith('.html') &&
          !item.resolvedHref.toLowerCase().endsWith('.htm')) {
        continue;
      }
      final xhtmlBytes = entryOf(item.resolvedHref);
      if (xhtmlBytes == null) continue;
      final docBaseDir = _dirOf(item.resolvedHref);
      final blocks = <BookBlock>[];
      try {
        final doc = XmlDocument.parse(utf8.decode(xhtmlBytes));
        final body = doc.findAllElements('body', namespace: '*').firstOrNull;
        if (body != null) _extractBlocks(body, docBaseDir, blocks);
      } catch (_) {
        // 单章解析失败跳过，不影响其余章节
        continue;
      }
      if (blocks.isEmpty) continue;
      final title = tocMap[item.resolvedHref] ??
          (blocks.whereType<HeadingBlock>().firstOrNull?.text) ??
          '第 ${i + 1} 节';
      chapters.add(BookChapter(title: title, blocks: blocks));
    }

    if (chapters.isEmpty) throw const FormatException('EPUB 无可读内容');
    return BookContent(
      title: title ?? '未知书名',
      author: author,
      chapters: chapters,
      images: images,
    );
  }

  /// 解析 TXT 文件。
  static Future<BookContent> parseTxt(File file) async {
    final bytes = await file.readAsBytes();
    String text;
    try {
      text = utf8.decode(bytes, allowMalformed: false);
    } catch (_) {
      try {
        text = systemEncoding.decode(bytes);
      } catch (_) {
        text = utf8.decode(bytes, allowMalformed: true);
      }
    }
    // 一行一段（中文 TXT 主流格式）；空行跳过；去首尾空白（含全角空格缩进）
    final blocks = <BookBlock>[];
    for (final line in text.split(RegExp(r'\r\n|\r|\n'))) {
      final t = line.trim();
      if (t.isNotEmpty) blocks.add(ParagraphBlock(t));
    }
    final title = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last
        : '未命名';
    return BookContent(
      title: title,
      chapters: [BookChapter(title: title, blocks: blocks)],
    );
  }

  /// 递归提取 body 下的 block：容器元素（div/section 等）下钻，
  /// 叶内容元素（p/h/img/hr/li）直接成块，避免重复。
  static void _extractBlocks(XmlElement parent, String baseDir, List<BookBlock> out) {
    for (final node in parent.children) {
      if (node is! XmlElement) continue;
      final tag = node.name.local.toLowerCase();
      if (tag.length == 2 && tag[0] == 'h') {
        final code = tag.codeUnitAt(1);
        if (code >= 0x31 && code <= 0x36) {
          // h1~h6
          final t = node.innerText.trim();
          if (t.isNotEmpty) out.add(HeadingBlock(t, code - 0x30));
        }
      } else if (tag == 'p' || tag == 'li' || tag == 'figcaption') {
        final t = node.innerText.trim();
        if (t.isNotEmpty) out.add(ParagraphBlock(t));
      } else if (tag == 'img') {
        final src = node.getAttribute('src') ?? '';
        if (src.isNotEmpty) out.add(ImageBlock(_resolve(baseDir, src)));
      } else if (tag == 'image') {
        final href = node.getAttribute('href', namespace: '*') ??
            node.getAttribute('xlink:href') ??
            '';
        if (href.isNotEmpty) out.add(ImageBlock(_resolve(baseDir, href)));
      } else if (tag == 'hr') {
        out.add(const DividerBlock());
      } else if (tag == 'br') {
        // 忽略，文本自然流动
      } else if (tag == 'table') {
        // 表格扁平化为段落：每行单元格文本拼接
        for (final tr in node.findAllElements('tr', namespace: '*')) {
          final cells = [
            ...tr.findElements('td', namespace: '*'),
            ...tr.findElements('th', namespace: '*'),
          ];
          final t = cells
              .map((c) => c.innerText.trim())
              .where((s) => s.isNotEmpty)
              .join('  ');
          if (t.isNotEmpty) out.add(ParagraphBlock(t));
        }
      } else {
        _extractBlocks(node, baseDir, out);
      }
    }
  }

  /// 构建 目录：内容文件路径 -> 标题。NAV(EPUB3) 优先，其次 NCX(EPUB2)。
  static Map<String, String> _buildTocMap(
    XmlDocument opf,
    Map<String, _ManifestItem> manifest,
    Uint8List? Function(String) entryOf,
  ) {
    final map = <String, String>{};
    // NAV：properties 含 nav
    String? navId;
    for (final entry in manifest.entries) {
      if (entry.value.properties.split(' ').contains('nav')) {
        navId = entry.key;
        break;
      }
    }
    if (navId != null) {
      final navItem = manifest[navId]!;
      final navBytes = entryOf(navItem.resolvedHref);
      if (navBytes != null) {
        try {
          final doc = XmlDocument.parse(utf8.decode(navBytes));
          final navDir = _dirOf(navItem.resolvedHref);
          for (final a in doc.findAllElements('a', namespace: '*')) {
            final href = a.getAttribute('href');
            final text = a.innerText.trim();
            if (href == null || href.isEmpty || text.isEmpty) continue;
            final fileKey = _resolve(navDir, href);
            map.putIfAbsent(fileKey, () => text);
          }
        } catch (_) {
          // ignore
        }
      }
    }
    if (map.isNotEmpty) return map;
    // NCX：media-type application/x-dtbncx+xml
    String? ncxId;
    _ManifestItem? ncxItem;
    for (final entry in manifest.entries) {
      if (entry.value.mediaType.contains('x-dtbncx+xml')) {
        ncxId = entry.key;
        ncxItem = entry.value;
        break;
      }
    }
    if (ncxId != null && ncxItem != null) {
      final ncxBytes = entryOf(ncxItem.resolvedHref);
      if (ncxBytes != null) {
        try {
          final doc = XmlDocument.parse(utf8.decode(ncxBytes));
          final ncxDir = _dirOf(ncxItem.resolvedHref);
          for (final np in doc.findAllElements('navPoint', namespace: '*')) {
            final content = np.findElements('content', namespace: '*').firstOrNull;
            final label = np
                .findAllElements('text', namespace: '*')
                .firstOrNull
                ?.innerText
                .trim();
            final src = content?.getAttribute('src');
            if (src != null && src.isNotEmpty && label != null && label.isNotEmpty) {
              map.putIfAbsent(_resolve(ncxDir, src), () => label);
            }
          }
        } catch (_) {
          // ignore
        }
      }
    }
    return map;
  }

  /// 取 ArchiveFile 的字节（content 可能是 `Uint8List` 或 `List<int>`）
  static Uint8List _bytesOfFile(ArchiveFile f) {
    final c = f.content;
    if (c is Uint8List) return c;
    return Uint8List.fromList(c as List<int>);
  }

  /// 路径所属目录
  static String _dirOf(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? '' : path.substring(0, i);
  }

  /// 相对路径解析：合并 baseDir + href，处理 ./ ../，去 anchor。
  static String _resolve(String baseDir, String href) {
    final h = href.split('#').first.trim();
    if (h.isEmpty) return baseDir;
    final parts = <String>[
      ...baseDir.split('/').where((s) => s.isNotEmpty),
      ...h.split('/'),
    ];
    final out = <String>[];
    for (final p in parts) {
      if (p == '.' || p.isEmpty) continue;
      if (p == '..') {
        if (out.isNotEmpty) out.removeLast();
        continue;
      }
      out.add(p);
    }
    return out.join('/');
  }
}

class _ManifestItem {
  final String href;
  final String resolvedHref;
  final String mediaType;
  final String properties;
  const _ManifestItem({
    required this.href,
    required this.resolvedHref,
    required this.mediaType,
    required this.properties,
  });
}
