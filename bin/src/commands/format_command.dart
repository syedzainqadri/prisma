import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:orm/version.dart';
import 'package:path/path.dart';

import '../binary_engine/binary_engine.dart';
import '../binary_engine/binary_engine_platform.dart';
import '../binary_engine/binray_engine_type.dart';
import '../environment.dart';
import '../utils/ansi_progress.dart';

class FormatCommand extends Command {
  FormatCommand() {
    argParser.addOption(
      'schema',
      help: 'Schema file path.',
      valueHelp: 'path',
      defaultsTo: environment.schema.path,
    );
  }

  @override
  String get description => 'Format a Prisma schema.';

  @override
  String get name => 'format';

  @override
  Future<void> run() async {
    final File schema = File(argResults!['schema']);
    if (!schema.existsSync()) {
      throw Exception('Provided schema file does not exist. - ${schema.path}');
    }

    final BinaryEngine engine = BinaryEngine(
      platform: BinaryEnginePlatform.current,
      type: BinaryEngineType.format,
      version: binaryVersion,
    );
    if (!await engine.hasDownloaded) {
      await engine
          .download(AnsiProgress.createFutureHandler('Download format engine'));
      await Future.delayed(Duration(microseconds: 500));
    }

    // Create format progress.
    final AnsiProgress formatProgress =
        AnsiProgress('Formatting prisma schema...');

    // Run format engine binary.
    final ProcessResult result = await engine.run(
        ['format', '-i', relative(schema.path, from: environment.projectRoot)]);

    // If format engine binary failed, print error message.
    if (result.exitCode != 0) {
      throw Exception(result.stderr);
    }

    // Write formatted schema to schema file.
    schema.writeAsString(result.stdout);

    // Cancel format progress.
    formatProgress.cancel(
      overrideMessage: '${schema.path} formatted successfully.',
      showTime: false,
    );
  }
}
