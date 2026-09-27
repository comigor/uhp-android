part of 'main.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    _scheduleHarnessLoad();
  }

  void _scheduleHarnessLoad() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final server = ref.read(selectedServerProvider);
      final harnesses = ref.read(harnessesProvider);
      if (server == null ||
          !server.hasApiKey ||
          harnesses.isLoading ||
          harnesses.hasError ||
          (harnesses.valueOrNull?.isNotEmpty ?? false)) {
        return;
      }
      try {
        await ref.read(harnessesProvider.notifier).refresh();
      } catch (_) {
        // The provider exposes the error and the reload action below.
      }
    });
  }

  Future<void> _addServer({bool demo = false}) async {
    final server = ServerConfig(
      id: newLocalId(),
      name: demo ? demoServer.name : 'New server',
      baseUrl: demo ? demoServer.baseUrl : '',
    );
    try {
      await ref.read(serversProvider.notifier).add(server);
      if (!mounted) return;
      await _editServer(server);
    } catch (error) {
      if (mounted) showMessage(ref, error);
    }
  }

  Future<void> _editServer(ServerConfig server) => Navigator.of(
    context,
  ).push<void>(MaterialPageRoute(builder: (_) => ServerEditor(server: server)));

  Future<void> _selectServer(ServerConfig server) async {
    if (!server.hasApiKey) {
      await _editServer(server);
      return;
    }
    ref.read(selectedServerProvider.notifier).state = server;
    ref.read(selectedHarnessProvider.notifier).state = null;
    try {
      await ref.read(appPreferencesProvider.notifier).selectServer(server.id);
      if (!mounted) return;
      ref.read(appDestinationProvider.notifier).state = AppDestination.feed;
    } catch (error) {
      if (mounted) showMessage(ref, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(selectedServerProvider, (_, _) => _scheduleHarnessLoad());
    final profiles = ref.watch(serversProvider);
    final server = ref.watch(selectedServerProvider);
    final harnesses = ref.watch(harnessesProvider);
    final blocked =
        ref.watch(taskBusyProvider) || ref.watch(unsavedThreadProvider) != null;
    final heading = Theme.of(context).textTheme.titleLarge;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Servers', style: heading),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: profiles.hasValue ? () => _addServer() : null,
                      icon: const Icon(Icons.add),
                      label: const Text('Add server'),
                    ),
                    TextButton(
                      onPressed: profiles.hasValue
                          ? () => _addServer(demo: true)
                          : null,
                      child: const Text('Add demo profile'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        profiles.when(
          loading: () => const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('Loading profiles…'),
            ),
          ),
          error: (error, _) => SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Cannot load profiles: $error'),
            ),
          ),
          data: (items) => items.isEmpty
              ? const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No saved servers. Add one to begin.'),
                  ),
                )
              : SliverList.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final profile = items[index];
                    return ListTile(
                      leading: Icon(
                        profile.id == server?.id
                            ? Icons.check_circle
                            : Icons.dns_outlined,
                      ),
                      title: Text(
                        profile.name.isEmpty ? 'Unnamed server' : profile.name,
                      ),
                      subtitle: Text(
                        '${profile.baseUrl}\n${profile.hasApiKey ? profile.testResult ?? 'Not tested' : 'API key required'}',
                      ),
                      isThreeLine: true,
                      onTap: () => _selectServer(profile),
                      trailing: IconButton(
                        tooltip: 'Edit server',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _editServer(profile),
                      ),
                    );
                  },
                ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(height: 32),
                Text('Harnesses', style: heading),
                const SizedBox(height: 8),
                if (server == null || !server.hasApiKey)
                  const Text(
                    'Select a server with an API key to load harnesses.',
                  )
                else ...[
                  Text('Harnesses on ${server.name}'),
                  OutlinedButton.icon(
                    onPressed: harnesses.isLoading
                        ? null
                        : () async {
                            try {
                              await ref
                                  .read(harnessesProvider.notifier)
                                  .refresh();
                            } catch (error) {
                              if (mounted) showMessage(ref, error);
                            }
                          },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reload harnesses'),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (server != null && server.hasApiKey)
          harnesses.when(
            loading: () =>
                const SliverToBoxAdapter(child: LinearProgressIndicator()),
            error: (error, _) => SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('$error'),
              ),
            ),
            data: (items) => items.isEmpty
                ? const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No harnesses available.'),
                    ),
                  )
                : SliverList.builder(
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final harness = items[index];
                      return ListTile(
                        title: Text(harness.name),
                        subtitle: Text(
                          '${harness.baseLabel}\n${harness.defaultModel}',
                        ),
                        isThreeLine: true,
                        onTap: blocked
                            ? null
                            : () async {
                                try {
                                  await startNewChat(ref, harness: harness);
                                } catch (error) {
                                  if (mounted) showMessage(ref, error);
                                }
                              },
                        trailing: IconButton(
                          tooltip: 'Edit default model',
                          icon: const Icon(Icons.tune),
                          onPressed: blocked
                              ? null
                              : () => showDialog<void>(
                                  context: context,
                                  builder: (_) => _HarnessModelEditor(
                                    server: server,
                                    harness: harness,
                                  ),
                                ),
                        ),
                      );
                    },
                  ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Divider(height: 32),
                Text('Updater', style: heading),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('App updates'),
                  subtitle: const Text(
                    'Check for updates and install a new release.',
                  ),
                  trailing: UpdateMenu(
                    service: ref.watch(updateServiceProvider),
                  ),
                ),
                const Divider(height: 32),
                Text('About', style: heading),
                const SizedBox(height: 8),
                const Text('UHP Android'),
                const Text('Version $appVersion'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
