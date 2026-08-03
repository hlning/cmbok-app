import 'package:flutter/material.dart';

import '../models/book_content.dart';

/// 图书排版参数：字号 / 行距 / 边距。paginator 与阅读器页共用同一实例，
/// 保证度量高度与实际渲染一致（颜色不影响布局，渲染时 copyWith 颜色）。
class BookTypography {
  final double fontSize;
  final double lineHeight;
  final double padding; // 水平边距
  final double verticalPadding; // 垂直边距（含 HUD 上下留白）
  final String? fontFamily; // 字体；null = 系统默认。度量与渲染共用，确保分页一致

  const BookTypography({
    required this.fontSize,
    required this.lineHeight,
    required this.padding,
    required this.verticalPadding,
    this.fontFamily,
  });

  /// 段落 / 块之间的纵向间距
  double get blockSpacing => fontSize * 0.55;

  /// 段落度量样式（无颜色）
  TextStyle paragraphStyle() =>
      TextStyle(fontSize: fontSize, height: lineHeight, fontFamily: fontFamily);

  /// 标题字号：level 越小字号越大
  double headingFontSize(int level) {
    final l = level < 1 ? 1 : (level > 6 ? 6 : level);
    return fontSize + (6 - l) * 2.0 + 2;
  }

  /// 标题度量样式：level 越小字号越大
  TextStyle headingStyle(int level) {
    return TextStyle(
      fontSize: headingFontSize(level),
      height: lineHeight,
      fontWeight: FontWeight.w700,
      fontFamily: fontFamily,
    );
  }

  /// 强制行高 strut：分页度量与渲染共用同一 strut，消除 TextPainter 与
  /// SelectableText/Text 的行高偏差（不同设备字体度量不同，否则多行累积
  /// 到页底会溢出）。
  StrutStyle strutStyleFor(double size) =>
      StrutStyle(fontSize: size, height: lineHeight, forceStrutHeight: true);

  StrutStyle get paragraphStrut => strutStyleFor(fontSize);

  StrutStyle headingStrut(int level) => strutStyleFor(headingFontSize(level));
}

/// 一页中的一条内容（可能是整块，或段落被切分后的部分文本）
class PageEntry {
  final BookBlock block;

  /// null = 整块原样；非 null = 段落/标题切分后的部分文本
  final String? partialText;
  const PageEntry(this.block, {this.partialText});
}

/// 分页后的一页
class BookPage {
  /// 该页首 block 在 flatBlocks 中的索引（续读 / TOC 映射用）
  final int firstBlockIndex;
  final List<PageEntry> entries;
  const BookPage({required this.firstBlockIndex, required this.entries});
}

/// TextPainter 度量分页器：把 flatBlocks 按 [BookTypography] 与视口尺寸切成页。
/// 段落跨页按行断点切分（getLineBoundary），不切断半行。
class BookPaginator {
  final List<BookBlock> blocks;
  final double viewportWidth;
  final double viewportHeight;
  final BookTypography typo;

  /// imageKey -> 宽/高（阅读器解码图片后回填；未知按 1.5 估算）
  final Map<String, double> imageAspectRatios;

  const BookPaginator({
    required this.blocks,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.typo,
    this.imageAspectRatios = const {},
  });

  List<BookPage> paginate() {
    final pages = <BookPage>[];
    final contentWidth = viewportWidth - typo.padding * 2;
    final pageHeight = viewportHeight - typo.verticalPadding * 2;
    if (pageHeight <= 0 || contentWidth <= 0 || blocks.isEmpty) return pages;

    var cur = <PageEntry>[];
    var curFirst = 0;
    var remaining = pageHeight;

    void commitPage() {
      if (cur.isNotEmpty) {
        pages.add(BookPage(firstBlockIndex: curFirst, entries: cur));
      }
      cur = <PageEntry>[];
      remaining = pageHeight;
    }

    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      if (cur.isEmpty) curFirst = i;

      // 分隔线
      if (block is DividerBlock) {
        const h = 16.0;
        if (remaining < h + typo.blockSpacing) commitPage();
        cur.add(const PageEntry(DividerBlock()));
        remaining -= h + typo.blockSpacing;
        continue;
      }

      // 图片
      if (block is ImageBlock) {
        final ar = imageAspectRatios[block.imageKey] ?? 1.5;
        var imgH = contentWidth / ar;
        if (imgH > pageHeight) imgH = pageHeight; // 超高图限制为一页高
        if (imgH > remaining && cur.isNotEmpty) {
          commitPage();
          curFirst = i;
        }
        cur.add(PageEntry(block));
        remaining -= imgH + typo.blockSpacing;
        continue;
      }

      // 段落 / 标题：文本度量（strut 强制行高，与渲染一致）
      final isHeading = block is HeadingBlock;
      final text = isHeading ? block.text : (block as ParagraphBlock).text;
      final style = isHeading
          ? typo.headingStyle(block.level)
          : typo.paragraphStyle();
      final strut = isHeading
          ? typo.headingStrut(block.level)
          : typo.paragraphStrut;

      final tp = TextPainter(
        text: TextSpan(text: text, style: style),
        strutStyle: strut,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: contentWidth);
      final totalH = tp.height;

      if (totalH <= remaining) {
        // 整块放得下
        cur.add(PageEntry(block));
        remaining -= totalH + typo.blockSpacing;
        continue;
      }

      // 放不下：按页切分
      var rest = text;
      var firstChunk = true;
      while (rest.isNotEmpty) {
        if (!firstChunk || cur.isNotEmpty) {
          commitPage();
          curFirst = i;
        }
        firstChunk = false;
        final tp2 = TextPainter(
          text: TextSpan(text: rest, style: style),
          strutStyle: strut,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: contentWidth);

        if (tp2.height <= pageHeight) {
          // 剩余全部放得下
          cur.add(PageEntry(block, partialText: rest == text ? null : rest));
          remaining = pageHeight - tp2.height - typo.blockSpacing;
          rest = '';
        } else {
          // 按行切分
          var fitEnd = _fitOffset(tp2, pageHeight);
          if (fitEnd <= 0) {
            // 一行都放不下（视口过小），强制取一行避免死循环
            final range = tp2.getLineBoundary(const TextPosition(offset: 0));
            fitEnd = range.end > range.start ? range.end : 1;
          }
          cur.add(PageEntry(block, partialText: rest.substring(0, fitEnd)));
          remaining = 0;
          rest = rest.substring(fitEnd).trimLeft();
        }
      }
    }
    commitPage();
    return pages;
  }

  /// 返回在 [maxHeight] 内能放下的文本字符偏移（行末对齐）
  int _fitOffset(TextPainter tp, double maxHeight) {
    final metrics = tp.computeLineMetrics();
    var cursor = 0;
    var used = 0.0;
    var fitEnd = 0;
    for (final m in metrics) {
      if (used + m.height <= maxHeight) {
        used += m.height;
        final range = tp.getLineBoundary(TextPosition(offset: cursor));
        fitEnd = range.end;
        cursor = range.end;
        if (range.end <= range.start) break;
      } else {
        break;
      }
    }
    return fitEnd;
  }

  /// 找包含给定 blockIndex 的页索引（续读恢复用）
  static int pageIndexOf(List<BookPage> pages, int blockIndex) {
    if (pages.isEmpty) return 0;
    var lo = 0, hi = pages.length - 1, ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (pages[mid].firstBlockIndex <= blockIndex) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }
}
