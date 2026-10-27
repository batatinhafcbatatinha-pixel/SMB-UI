import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Strip ANSI escape codes from terminal strings for clean markdown output
final RegExp _ansiRegex = RegExp(
  r'[\u001B\u009B][[\]()#;?]*(?:(?:(?:(?:;[-a-zA-Z\d\/#&.:=?%_]+)*|[a-zA-Z\d]+(?:;[-a-zA-Z\d\/#&.:=?%_]*)*)?\u0007)|(?:(?:\d{1,4}(?:;\d{0,4})*)?[\dA-PR-TZcf-ntqry=><~]))',
);

String _formatDateTime(DateTime dt) {
  final y = dt.year.toString().padLeft(4, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  final ss = dt.second.toString().padLeft(2, '0');
  return '$y-$m-$d $hh:$mm:$ss';
}

String _formatDuration(Duration d) {
  final minutes = d.inMinutes;
  final seconds = d.inSeconds % 60;
  if (minutes > 0) {
    return '${minutes}m ${seconds}s';
  }
  return '${seconds}s';
}

/// Detects running Android emulator or device ID automatically
Future<String?> _detectAndroidDeviceId() async {
  try {
    final result = await Process.run(
      'flutter',
      ['devices', '--machine'],
      runInShell: true,
    );
    if (result.exitCode == 0) {
      final jsonOutput = result.stdout.toString().trim();
      final startIndex = jsonOutput.indexOf('[');
      final endIndex = jsonOutput.lastIndexOf(']');
      if (startIndex != -1 && endIndex != -1 && endIndex >= startIndex) {
        final rawJson = jsonOutput.substring(startIndex, endIndex + 1);
        final list = jsonDecode(rawJson) as List<dynamic>;

        // 1. Look for running android emulator
        for (final item in list) {
          if (item is Map<String, dynamic>) {
            final targetPlatform =
                item['targetPlatform']?.toString().toLowerCase() ?? '';
            final isEmulator = item['emulator'] == true;
            if (targetPlatform.startsWith('android') && isEmulator) {
              return item['id']?.toString();
            }
          }
        }

        // 2. Look for any running android device
        for (final item in list) {
          if (item is Map<String, dynamic>) {
            final targetPlatform =
                item['targetPlatform']?.toString().toLowerCase() ?? '';
            if (targetPlatform.startsWith('android')) {
              return item['id']?.toString();
            }
          }
        }
      }
    }
  } catch (e) {
    // Ignore error and fallback
  }
  return null;
}

/// Checks available emulators and launches the first one if none is active
Future<String?> _launchAvailableEmulator() async {
  try {
    stdout.writeln(
        '\x1B[33m[Log Runner]\x1B[0m Nenhum emulador ativo detectado. Buscando emuladores disponíveis...');
    final result = await Process.run(
      'flutter',
      ['emulators'],
      runInShell: true,
    );
    final output = result.stdout.toString();
    // Parse first emulator ID from table
    final lines = output.split('\n');
    for (final line in lines) {
      if (line.contains('•') && !line.startsWith('Id')) {
        final parts = line.split('•');
        if (parts.isNotEmpty) {
          final emuId = parts[0].trim();
          if (emuId.isNotEmpty) {
            stdout.writeln(
                '\x1B[32m[Log Runner]\x1B[0m Iniciando emulador \x1B[36m$emuId\x1B[0m...');
            Process.run(
              'flutter',
              ['emulators', '--launch', emuId],
              runInShell: true,
            );
            // Give emulator a few seconds to register
            await Future.delayed(const Duration(seconds: 4));
            return emuId;
          }
        }
      }
    }
  } catch (_) {}
  return null;
}

/// Prepares emulator storage (cleans tmp and sets reasonable low-storage thresholds)
Future<void> _prepareEmulatorStorage(String? deviceId) async {
  if (deviceId == null) return;
  try {
    await Process.run(
      'adb',
      ['-s', deviceId, 'shell', 'rm', '-rf', '/data/local/tmp/*'],
      runInShell: true,
    );
    await Process.run(
      'adb',
      [
        '-s',
        deviceId,
        'shell',
        'settings',
        'put',
        'global',
        'sys_storage_threshold_percentage',
        '1'
      ],
      runInShell: true,
    );
    await Process.run(
      'adb',
      [
        '-s',
        deviceId,
        'shell',
        'settings',
        'put',
        'global',
        'sys_storage_threshold_max_bytes',
        '50000000'
      ],
      runInShell: true,
    );
  } catch (_) {}
}

void main(List<String> args) async {
  final startTime = DateTime.now();
  final logFile = File('flutter_logs.md');

  // Build flutter run command arguments
  final flutterArgs = <String>['run'];

  // Resolve device ID if not specified by user
  String? deviceId;
  final hasExplicitDevice =
      args.contains('-d') || args.contains('--device-id');

  if (!hasExplicitDevice) {
    deviceId = await _detectAndroidDeviceId();
    if (deviceId == null) {
      final launchedEmu = await _launchAvailableEmulator();
      deviceId = await _detectAndroidDeviceId() ?? launchedEmu ?? 'emulator';
    }
    flutterArgs.addAll(['-d', deviceId]);
  }

  // Ensure emulator storage threshold is ready
  await _prepareEmulatorStorage(deviceId);

  flutterArgs.addAll(args);

  final commandString = 'flutter ${flutterArgs.join(' ')}';
  final targetDeviceLabel = deviceId != null ? 'Android ($deviceId)' : 'Android';

  // 1. Clear / reset flutter_logs.md with Markdown header
  final header = '''# 📱 Flutter Android Run Log

- **Início:** ${_formatDateTime(startTime)}
- **Comando:** `$commandString`
- **Alvo:** $targetDeviceLabel
- **Status:** 🟡 Em execução

---

## 📋 Logs de Execução

```log
''';

  try {
    await logFile.writeAsString(header, mode: FileMode.write, flush: true);
  } catch (e) {
    stderr.writeln('Erro ao inicializar flutter_logs.md: $e');
  }

  stdout.writeln(
      '\x1B[32m[Log Runner]\x1B[0m Arquivo \x1B[36mflutter_logs.md\x1B[0m limpo e pronto.');
  stdout.writeln(
      '\x1B[32m[Log Runner]\x1B[0m Executando: \x1B[33m$commandString\x1B[0m\n');

  final logSink = logFile.openWrite(mode: FileMode.append);

  // 2. Start flutter run process
  Process process;
  try {
    process = await Process.start(
      'flutter',
      flutterArgs,
      runInShell: true,
      mode: ProcessStartMode.normal,
    );
  } catch (e) {
    stderr.writeln('Falha ao iniciar o Flutter: $e');
    logSink.writeln('[ERRO] Falha ao iniciar o comando: $e');
    await logSink.flush();
    await logSink.close();
    exit(1);
  }

  // Handle terminal stdin forwarding (for r, R, q, etc.)
  StreamSubscription? stdinSub;
  try {
    if (stdin.hasTerminal) {
      stdin.lineMode = false;
      stdin.echoMode = true;
    }
    stdinSub = stdin.listen((data) {
      try {
        process.stdin.add(data);
      } catch (_) {}
    });
  } catch (_) {
    // If not attached to interactive terminal, continue normally
  }

  void appendLog(String line) {
    final cleanLine = line.replaceAll(_ansiRegex, '');
    logSink.writeln(cleanLine);
  }

  // Stream stdout
  final stdoutSub = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    stdout.writeln(line);
    appendLog(line);
  });

  // Stream stderr
  final stderrSub = process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    stderr.writeln(line);
    appendLog('[STDERR] $line');
  });

  // Handle SIGINT (Ctrl+C) gracefully
  ProcessSignal.sigint.watch().listen((_) async {
    try {
      process.kill();
    } catch (_) {}
  });

  final exitCode = await process.exitCode;
  final endTime = DateTime.now();
  final duration = endTime.difference(startTime);

  await stdoutSub.cancel();
  await stderrSub.cancel();
  await stdinSub?.cancel();

  // 3. Finalize flutter_logs.md
  final statusEmoji = exitCode == 0 ? '🟢' : '🔴';
  final statusText = exitCode == 0
      ? 'Finalizado com sucesso (Exit code: 0)'
      : 'Encerrado com erro (Exit code: $exitCode)';

  final footer = '''
```

---

### 🏁 Resumo da Sessão
- **Término:** ${_formatDateTime(endTime)}
- **Duração:** ${_formatDuration(duration)}
- **Status:** $statusEmoji $statusText
''';

  logSink.write(footer);
  await logSink.flush();
  await logSink.close();

  // Reset stdin settings if modified
  try {
    if (stdin.hasTerminal) {
      stdin.lineMode = true;
      stdin.echoMode = true;
    }
  } catch (_) {}

  stdout.writeln(
      '\n\x1B[32m[Log Runner]\x1B[0m Sessão encerrada. Logs salvos em \x1B[36mflutter_logs.md\x1B[0m ($statusEmoji $statusText)');
  exit(exitCode);
}
