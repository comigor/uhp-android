part of 'main.dart';

final feedSearchOpenProvider = StateProvider<bool>((ref) => false);
final feedSearchQueryProvider = StateProvider<String>((ref) => '');

bool matchesFeedSearch(String query, String title, String firstUserLine) =>
    query.isEmpty ||
    title.toLowerCase().contains(query) ||
    firstUserLine.toLowerCase().contains(query);

void closeFeedSearch(WidgetRef ref) {
  ref.read(feedSearchOpenProvider.notifier).state = false;
  ref.read(feedSearchQueryProvider.notifier).state = '';
}

class FeedSearchField extends ConsumerStatefulWidget {
  const FeedSearchField({super.key});

  @override
  ConsumerState<FeedSearchField> createState() => _FeedSearchFieldState();
}

class _FeedSearchFieldState extends ConsumerState<FeedSearchField> {
  late final TextEditingController _controller;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ref.read(feedSearchQueryProvider),
    );
  }

  void _change(String value) {
    _debounce?.cancel();
    final query = value.trim().toLowerCase();
    if (query.isEmpty) {
      ref.read(feedSearchQueryProvider.notifier).state = '';
      return;
    }
    final server = ref.read(selectedServerProvider);
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted ||
          !ref.read(feedSearchOpenProvider) ||
          !identical(server, ref.read(selectedServerProvider))) {
        return;
      }
      ref.read(feedSearchQueryProvider.notifier).state = query;
    });
  }

  void _close() {
    _debounce?.cancel();
    closeFeedSearch(ref);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
    child: TextField(
      key: const ValueKey('feed-search-input'),
      controller: _controller,
      autofocus: true,
      onChanged: _change,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Search loaded sessions',
        border: InputBorder.none,
        suffixIcon: IconButton(
          tooltip: 'Close feed search',
          onPressed: _close,
          icon: const Icon(Icons.close),
        ),
      ),
    ),
  );
}
