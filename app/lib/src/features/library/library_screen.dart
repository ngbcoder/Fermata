import 'dart:async';

import 'package:fermata_core/fermata_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/library_providers.dart';
import 'widgets/empty_library.dart';
import 'widgets/import_sheet.dart';
import 'widgets/score_card.dart';

/// The user's search text, sort order and layout choice for the library.
class LibraryFilter {
  const LibraryFilter({
    this.searchText = '',
    this.sort = ScoreSort.recentlyOpened,
    this.grid = true,
    this.tagIds = const <String>{},
    this.setlistId,
  });

  final String searchText;
  final ScoreSort sort;
  final bool grid;
  final Set<String> tagIds;
  final String? setlistId;

  ScoreQuery get query => ScoreQuery(
    searchText: searchText,
    sort: sort,
    tagIds: tagIds,
    setlistId: setlistId,
  );

  LibraryFilter copyWith({
    String? searchText,
    ScoreSort? sort,
    bool? grid,
    Set<String>? tagIds,
    String? setlistId,
    bool clearSetlist = false,
  }) => LibraryFilter(
    searchText: searchText ?? this.searchText,
    sort: sort ?? this.sort,
    grid: grid ?? this.grid,
    tagIds: tagIds ?? this.tagIds,
    setlistId: clearSetlist ? null : (setlistId ?? this.setlistId),
  );
}

final libraryFilterProvider =
    NotifierProvider<LibraryFilterNotifier, LibraryFilter>(
      LibraryFilterNotifier.new,
    );

class LibraryFilterNotifier extends Notifier<LibraryFilter> {
  @override
  LibraryFilter build() => const LibraryFilter();

  void setSearchText(String value) =>
      state = state.copyWith(searchText: value);

  void setSort(ScoreSort value) => state = state.copyWith(sort: value);

  void toggleLayout() => state = state.copyWith(grid: !state.grid);
}

/// The live library, re-emitted whenever any score or page changes.
final libraryProvider = StreamProvider.autoDispose<List<Score>>((ref) async* {
  final repository = await ref.watch(scoreRepositoryProvider.future);
  final filter = ref.watch(libraryFilterProvider);
  yield* repository.watchScores(filter.query);
});

final scorePagesProvider = FutureProvider.autoDispose
    .family<List<ScorePage>, String>((ref, scoreId) async {
      final repository = await ref.watch(scoreRepositoryProvider.future);
      return repository.getPages(scoreId);
    });

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key, required this.onOpenScore});

  final void Function(Score score) onOpenScore;

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(libraryFilterProvider);
    final library = ref.watch(libraryProvider);
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Library',
                      style: theme.textTheme.headlineMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Import scores',
                    onPressed: () => _startImport(context),
                    icon: const Icon(Icons.add_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: SearchBar(
                controller: _searchController,
                hintText: 'Search titles and composers',
                leading: const Icon(Icons.search_rounded),
                trailing: [
                  if (filter.searchText.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        _searchController.clear();
                        ref
                            .read(libraryFilterProvider.notifier)
                            .setSearchText('');
                      },
                    ),
                ],
                onChanged: (value) =>
                    ref.read(libraryFilterProvider.notifier).setSearchText(value),
              ),
            ),
            _SortBar(
              sort: filter.sort,
              grid: filter.grid,
              onSortChanged: (value) =>
                  ref.read(libraryFilterProvider.notifier).setSort(value),
              onToggleLayout: () =>
                  ref.read(libraryFilterProvider.notifier).toggleLayout(),
            ),
            Expanded(
              child: switch (library) {
                AsyncData(:final value) when value.isEmpty =>
                  filter.hasFilters
                      ? const _NoMatches()
                      : EmptyLibrary(onImport: () => _startImport(context)),
                AsyncData(:final value) => _ScoreCollection(
                  scores: value,
                  grid: filter.grid,
                  onOpen: widget.onOpenScore,
                ),
                AsyncError(:final error) => _ErrorState(error: error),
                _ => const Center(child: CircularProgressIndicator()),
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startImport(BuildContext context) async {
    final result = await showImportSheet(context);
    if (result == null || !context.mounted) return;
    widget.onOpenScore(result);
  }
}

extension on LibraryFilter {
  bool get hasFilters =>
      searchText.trim().isNotEmpty || tagIds.isNotEmpty || setlistId != null;
}

class _ScoreCollection extends StatelessWidget {
  const _ScoreCollection({
    required this.scores,
    required this.grid,
    required this.onOpen,
  });

  final List<Score> scores;
  final bool grid;
  final void Function(Score score) onOpen;

  @override
  Widget build(BuildContext context) {
    if (grid) {
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 96),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 220,
          mainAxisExtent: 232,
          crossAxisSpacing: 14,
          mainAxisSpacing: 14,
        ),
        itemCount: scores.length,
        itemBuilder: (context, index) => ScoreCard.grid(
          score: scores[index],
          onTap: () => onOpen(scores[index]),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 96),
      itemCount: scores.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) => ScoreCard.list(
        score: scores[index],
        onTap: () => onOpen(scores[index]),
      ),
    );
  }
}

class _SortBar extends StatelessWidget {
  const _SortBar({
    required this.sort,
    required this.grid,
    required this.onSortChanged,
    required this.onToggleLayout,
  });

  final ScoreSort sort;
  final bool grid;
  final ValueChanged<ScoreSort> onSortChanged;
  final VoidCallback onToggleLayout;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final option in ScoreSort.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(_labelFor(option)),
                        selected: option == sort,
                        onSelected: (_) => onSortChanged(option),
                      ),
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: grid ? 'Show as list' : 'Show as grid',
            onPressed: onToggleLayout,
            icon: Icon(
              grid ? Icons.view_list_rounded : Icons.grid_view_rounded,
            ),
          ),
        ],
      ),
    );
  }

  static String _labelFor(ScoreSort sort) => switch (sort) {
    ScoreSort.recentlyOpened => 'Recent',
    ScoreSort.titleAscending => 'Title',
    ScoreSort.composerAscending => 'Composer',
    ScoreSort.dateAddedDescending => 'Date added',
  };
}

class _NoMatches extends StatelessWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text('No matches', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Try a different title or composer.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 48,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              'Could not open the library',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
