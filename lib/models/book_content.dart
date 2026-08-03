import 'dart:typed_data';

/// EPUB / TXT 解析后的统一内容模型。
/// 阅读器与分页器共用：把 flatBlocks 经 TextPainter 度量切成翻页。
class BookContent {
  final String title;
  final String? author;
  final List<BookChapter> chapters;

  /// 图片资源：key 为解析时归一化的相对路径，value 为原始字节。
  final Map<String, Uint8List> images;

  const BookContent({
    required this.title,
    this.author,
    required this.chapters,
    this.images = const {},
  });

  /// 全部章节扁平化为一个 block 序列，章节标题作为 1 级标题块插入。
  /// 阅读器列表 / 分页器均消费此序列。
  List<BookBlock> get flatBlocks {
    final out = <BookBlock>[];
    for (final c in chapters) {
      out.add(HeadingBlock(c.title, 1));
      out.addAll(c.blocks);
    }
    return out;
  }

  /// 每章首 block 在 flatBlocks 中的索引（TOC 跳转用），长度 = chapters.length。
  List<int> get chapterStarts {
    final out = <int>[];
    var idx = 0;
    for (final c in chapters) {
      out.add(idx);
      idx += 1 + c.blocks.length; // 章节标题块 + 该章 blocks
    }
    return out;
  }
}

class BookChapter {
  final String title;
  final List<BookBlock> blocks;

  const BookChapter({required this.title, required this.blocks});
}

/// 内容块（密封类）。MVP 仅段落 / 标题 / 图片 / 分隔。
/// 内联样式（粗体/斜体/链接）暂抽纯文本，后续可扩展 span。
sealed class BookBlock {
  const BookBlock();
  factory BookBlock.paragraph(String text) = ParagraphBlock;
  factory BookBlock.heading(String text, int level) = HeadingBlock;
  factory BookBlock.image(String imageKey, {double? aspectRatio}) = ImageBlock;
  factory BookBlock.divider() = DividerBlock;
}

/// 段落（普通正文）
class ParagraphBlock extends BookBlock {
  final String text;
  const ParagraphBlock(this.text);
}

/// 标题（h1~h6）
class HeadingBlock extends BookBlock {
  final String text;
  final int level;
  const HeadingBlock(this.text, this.level);
}

/// 图片。aspectRatio = 宽/高，分页度量用；解析时不一定能取到，由阅读器/分页器解码后回填。
class ImageBlock extends BookBlock {
  final String imageKey;
  final double? aspectRatio;
  const ImageBlock(this.imageKey, {this.aspectRatio});
}

/// 分隔线
class DividerBlock extends BookBlock {
  const DividerBlock();
}
