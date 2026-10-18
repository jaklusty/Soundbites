import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../engine/state.dart';
import '../../engine/views.dart';
import '../controller.dart';
import '../theme.dart';

class SettingsPanel extends StatefulWidget {
  const SettingsPanel({super.key, required this.state, required this.controller});
  final AppState state;
  final SoundbitesController controller;
  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  late final feed = TextEditingController(text: widget.state.profile['_feedBase']?.toString() ?? widget.state.feedBase);
  late final conc = TextEditingController(text: '${widget.state.concurrency}');
  late final pause = TextEditingController(text: '${(widget.state.requestPauseMs / 1000).round()}');
  final ruleField = <String, String>{};
  final ruleValue = <String, TextEditingController>{};

  @override
  void dispose() {
    feed.dispose();
    conc.dispose();
    pause.dispose();
    for (final c in ruleValue.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.sb;
    final s = widget.state;
    final views = s.savedViews;
    return _Panel(title: 'Settings', children: [
      _label('Library folder'),
      Row(children: [
        Expanded(child: Text(s.libraryPath ?? 'none chosen', style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5))),
        OutlinedButton(onPressed: widget.controller.chooseLibraryFolder, child: const Text('Change…')),
      ]),
      _label('Feed address (an https address, or a folder on this computer)'),
      TextField(controller: feed),
      Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_label('Downloads at a time (1 to 3)'), TextField(controller: conc, keyboardType: TextInputType.number)])),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_label('Pause between requests to YouTube (seconds)'), TextField(controller: pause, keyboardType: TextInputType.number)])),
      ]),
      const SizedBox(height: 10),
      FilledButton(
        onPressed: () async {
          await widget.controller.updateSettings(feedBase: feed.text, concurrency: int.tryParse(conc.text), requestPauseMs: (int.tryParse(pause.text) ?? 2) * 1000);
          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved.')));
        },
        child: const Text('Save'),
      ),
      const SizedBox(height: 18),
      const Text('Saved views', style: TextStyle(fontWeight: FontWeight.w700)),
      Text('Views only change what is shown, never what is captured. A track shows when any condition of the rule matches.', style: TextStyle(fontSize: 12.5, color: c.muted)),
      for (final e in views.entries) ...[
        const SizedBox(height: 10),
        Text.rich(TextSpan(children: [
          TextSpan(text: ((e.value as Map?)?['label'] ?? e.key).toString(), style: const TextStyle(fontWeight: FontWeight.w600)),
          TextSpan(text: '  —  ${describeRule((e.value as Map?)?['rule'])}', style: TextStyle(color: c.muted, fontSize: 12.5)),
        ])),
        if (((e.value as Map?)?['description'] ?? '').toString().isNotEmpty) Text((e.value as Map)['description'].toString(), style: TextStyle(fontSize: 12.5, color: c.muted)),
        Row(children: [
          DropdownButton<String>(
            value: ruleField[e.key] ?? 'energy',
            items: const [
              DropdownMenuItem(value: 'energy', child: Text('energy is')),
              DropdownMenuItem(value: 'mood', child: Text('mood contains')),
              DropdownMenuItem(value: 'suits', child: Text('description contains')),
              DropdownMenuItem(value: 'direction', child: Text('direction is')),
              DropdownMenuItem(value: 'licence', child: Text('licence is')),
              DropdownMenuItem(value: 'platform', child: Text('platform is')),
            ],
            onChanged: (v) => setState(() => ruleField[e.key] = v ?? 'energy'),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 180, child: TextField(controller: ruleValue.putIfAbsent(e.key, TextEditingController.new), decoration: const InputDecoration(hintText: 'value'))),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () {
              final field = ruleField[e.key] ?? 'energy';
              final value = ruleValue[e.key]!.text.trim();
              if (value.isEmpty) return;
              final equalsFields = {'energy', 'direction', 'licence', 'platform'};
              final cond = equalsFields.contains(field) ? {'field': field, 'equals': value} : {'field': field, 'contains': value};
              widget.controller.saveViewRule(e.key, {'any': [cond]});
            },
            child: const Text('Replace rule with this'),
          ),
        ]),
      ],
      const SizedBox(height: 18),
      const Text('Downloader', style: TextStyle(fontWeight: FontWeight.w700)),
      Text(
        'yt-dlp ${widget.state.tools.ytdlp ?? 'not installed yet'} · Deno ${widget.state.tools.deno ?? 'not installed yet'} · ffmpeg ${widget.state.tools.ffmpeg ?? 'not found'}',
        style: TextStyle(fontSize: 12.5, color: c.muted),
      ),
      if (widget.state.tools.message != null) Text(widget.state.tools.message!, style: TextStyle(fontSize: 12.5, color: c.fading)),
      if (widget.controller.logPath != null) ...[
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: Text('If downloads fail, the log file says why: ${widget.controller.logPath}', style: TextStyle(fontSize: 12.5, color: c.muted))),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: widget.controller.showLogFile, child: const Text('Show log file')),
        ]),
      ],
    ]);
  }

  Widget _label(String t) => Padding(padding: const EdgeInsets.only(top: 10, bottom: 4), child: Text(t, style: TextStyle(fontSize: 13, color: context.sb.muted)));
}

class AboutPanel extends StatelessWidget {
  const AboutPanel({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.sb;
    return _Panel(title: 'About Soundbites', children: [
      Text(
        'Bundled: ffmpeg and ffprobe (LGPL v2.1 or later, built from unmodified FFmpeg source with LAME for MP3). Downloaded on first run and kept up to date: yt-dlp (Unlicense) and Deno (MIT). The ffmpeg source and build recipe are attached to each ffmpeg release at github.com/jaklusty/soundbites.',
        style: TextStyle(fontSize: 12.5, color: c.muted, height: 1.5),
      ),
      const SizedBox(height: 8),
      FutureBuilder<String>(
        future: rootBundle.loadString('LICENSES/ffmpeg.LICENSE.md').catchError((_) => ''),
        builder: (ctx, snap) => ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Licence texts', style: TextStyle(fontSize: 13)),
          children: [
            for (final f in ['ffmpeg.LICENSE.md', 'ffmpeg.COPYING.LGPLv2.1', 'lame.COPYING', 'yt-dlp.LICENSE', 'deno.LICENSE'])
              FutureBuilder<String>(
                future: rootBundle.loadString('LICENSES/$f').catchError((_) => '(missing)'),
                builder: (ctx2, s2) => ExpansionTile(title: Text(f, style: const TextStyle(fontSize: 12.5)), children: [
                  Container(
                    constraints: const BoxConstraints(maxHeight: 260),
                    padding: const EdgeInsets.all(8),
                    child: SingleChildScrollView(child: Text(s2.data ?? '', style: const TextStyle(fontFamily: 'monospace', fontSize: 11))),
                  ),
                ]),
              ),
          ],
        ),
      ),
    ]);
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final c = context.sb;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(color: c.panel, border: Border.all(color: c.line), borderRadius: BorderRadius.circular(9)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)), const SizedBox(height: 6), ...children]),
    );
  }
}
