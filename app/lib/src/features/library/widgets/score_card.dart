import 'dart:io';

import 'package:fermata_core/fermata_core.dart';
import 'package:flutter/material.dart';

/// A score as a grid tile.
///
/// The tile stands in for a page of music: it is the one place in the library
/// where a visual hint of the actual score is worth more than metadata, which
/// is why a thumbnail slot is reserved even before thumbnails are generated.
class ScoreCard extends StatelessWidget {
  const ScoreCard.grid({super.key, required this.score, required this.onTap})
    : _list = false;

  const ScoreCard.list({super.key, required this.score, required this.onTap})
    : _list = true;

  final Score score;
  final VoidCallback onTap;
  final bool _list;

  @override
  Widget build(BuildContext context) {
    return _list ? _buildList(context) : _buildGrid(context);
  }

  Widget _buildGrid(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _Thumbnail(score: score),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    score.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    score.composer.isEmpty ? 'Unknown composer' : score.composer,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              SizedBox(
                width: 52,
                height: 68,
                child: _Thumbnail(score: score, rounded: 8),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      score.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      score.composer.isEmpty
                          ? 'Unknown composer'
                          : score.composer,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _pageLabel(score.pageCount),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _pageLabel(int pageCount) =>
      pageCount == 1 ? '1 page' : '$pageCount pages';
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.score, this.rounded = 0});

  final Score score;
  final double rounded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // A generated thumbnail, when present, replaces the placeholder. The path
    // is stored relative to the library root or as an absolute path depending
    // on the producer, so accept either and fall back to the placeholder when
    // the file is missing rather than throwing.
    final thumbnailPath = score.thumbnailPath;
    if (thumbnailPath != null && thumbnailPath.isNotEmpty) {
      final file = File(thumbnailPath);
      if (file.existsSync()) {
        return Image.file(
          file,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _placeholder(theme),
        );
      }
    }

    return _placeholder(theme);
  }

  Widget _placeholder(ThemeData theme) {
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.music_note_rounded,
              size: 28,
              color: theme.colorScheme.onSurfaceVariant.withValues(
                alpha: 0.6,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${score.pageCount}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
