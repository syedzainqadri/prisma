library prisma.cli;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:orm/configure.dart';
import 'package:orm/version.dart';

import 'src/commands/db/db_command.dart';
import 'src/commands/format_command.dart';
import 'src/commands/generate_command.dart';
import 'src/commands/init_command.dart';
import 'src/commands/precache_command.dart';
import 'src/environment.dart';

/// The Prisma CLI executable name.
const String _executableName = r'dart run orm';

/// Prisma CLI description.
const String _description =
    ' ◭ Prisma CLI 🚀\nPrisma is a modern DB toolkit to query, migrate and model your database.\n More info: https://github.com/odroe/prisma-dart';

void main(List<String> args) async {
  final String? developmentExecutable = environment.developmentExecutable;
  if (developmentExecutable != null) {
    final ProcessResult result = await Process.run(
      developmentExecutable,
      environment.developmentArguments.toList(),
      includeParentEnvironment: true,
      stderrEncoding: utf8,
      stdoutEncoding: utf8,
    );
    if (result.exitCode != 0) {
      stderr.writeln(result.stderr);
      exit(result.exitCode);
    }

    PrismaDevelopment.client(environment: environment, encoded: result.stdout);
  }

  // Create command runner.
  final CommandRunner runner = CommandRunner(_executableName, _description);

  // Add global options.
  runner.argParser.addFlag('version',
      abbr: 'v', negatable: false, help: 'Print CLI and engines version.');
  runner.argParser
      .addFlag('debug', negatable: false, help: 'Print debug information.');

  // Add commands.
  runner.addCommand(InitCommand());
  runner.addCommand(FormatCommand());
  runner.addCommand(DbCommand());
  runner.addCommand(GenerateCommand());
  runner.addCommand(PrecacheCommand());

  // Get command result.
  final ArgResults results = runner.parse(args);

  // If version flag is set, print version and exit.
  if (results.wasParsed('version')) {
    return _printVersion();
  }

  // Run command.
  try {
    await runner.runCommand(results);
  } catch (error) {
    print('');
    if (results.wasParsed('debug') || environment.debug) {
      rethrow;
    }

    runner.printUsage();
    print('\n');
    print(_redTextWrapper(error.toString()));
    print('\n');
    exit(1);
  }
}

/// Red text if then terminal supports it.
String _redTextWrapper(String text) {
  if (stdout.supportsAnsiEscapes) {
    return '\x1B[31m$text\x1B[0m';
  }

  return text;
}

/// Print CLI and engines version.
void _printVersion() {
  final String info = '''
  ${'Prisma CLI'.padRight(40)}$packageVersion
  ${'Prisma Binary Engines'.padRight(40)}$binaryVersion
  ${'Prisma Query C API'.padRight(40)}$capiVersion
  ${'Data Proxy Remote Client'.padRight(40)}${environment.clientDataProxyClientVersion}
  ''';

  print(info);
}
