import 'dart:io';
import 'dart:typed_data';
import 'package:args/args.dart';
import 'package:xbox_memory_unit_tool/xbox_memory_unit_tool.dart';

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addCommand('ls', ArgParser()
      ..addFlag('size', abbr: 's', help: 'Show sizes of games and saves', negatable: false)
      ..addFlag('time', abbr: 't', help: 'Show modification times', negatable: false))
    ..addCommand('import')
    ..addCommand('export')
    ..addCommand('rm')
    ..addCommand('format')
    ..addCommand('extract-image')
    ..addCommand('raw', ArgParser()
      ..addCommand('ls')
      ..addCommand('mkdir')
      ..addCommand('cp', ArgParser()..addFlag('recursive', abbr: 'r', negatable: false))
      ..addCommand('import', ArgParser()..addFlag('recursive', abbr: 'r', negatable: false))
      ..addCommand('export', ArgParser()..addFlag('recursive', abbr: 'r', negatable: false))
      ..addCommand('rm', ArgParser()..addFlag('recursive', abbr: 'r', negatable: false))
      ..addCommand('mv'));

  ArgResults results;
  try {
    results = parser.parse(arguments);
  } catch (e) {
    printUsage(parser);
    return;
  }

  final command = results.command;
  if (command == null) {
    printUsage(parser);
    return;
  }

  try {
    switch (command.name) {
      case 'format':
        await handleFormat(command);
        break;
      case 'ls':
        await handleLs(command);
        break;
      case 'import':
        await handleImport(command);
        break;
      case 'export':
        await handleExport(command);
        break;
      case 'rm':
        await handleRm(command);
        break;
      case 'extract-image':
        await handleExtractImage(command);
        break;
      case 'raw':
        await handleRaw(command);
        break;
      default:
        printUsage(parser);
    }
  } catch (e) {
    _printError(e);
  }
}

void _printError(Object e) {
  if (e is UnimplementedError) {
    print('Error: This feature is not yet implemented.');
  } else if (e is FileSystemException) {
    print('Error: ${e.message}${e.path != null ? " (Path: ${e.path})" : ""}');
    if (e.osError != null) {
      print('OS Error: ${e.osError!.message} (Code: ${e.osError!.errorCode})');
    }
  } else {
    final msg = e.toString().replaceFirst('Exception: ', '');
    print('Error: $msg');
  }
}

/// Prints [text] in the specified [color].
/// Possible colors: [ 
///   black, red, green, yellow, blue, magenta, cyan, white, gray, 
///   bright_red, bright_green, bright_yellow, bright_blue, bright_magenta, 
///   bright_cyan, bright_white
/// ]
void printc(String stringToPrint, String foregroundColor) {
  // Map of common names to ANSI foreground codes
  final Map<String, String> colors = {
    'black': '\x1B[30m',
    'red': '\x1B[31m',
    'green': '\x1B[32m',
    'yellow': '\x1B[33m',
    'blue': '\x1B[34m',
    'magenta': '\x1B[35m',
    'cyan': '\x1B[36m',
    'white': '\x1B[37m',

    // Bright Colors (90-97)
    'gray': '\x1B[90m', // Bright Black
    'bright_red': '\x1B[91m',
    'bright_green': '\x1B[92m',
    'bright_yellow': '\x1B[93m',
    'bright_blue': '\x1B[94m',
    'bright_magenta': '\x1B[95m',
    'bright_cyan': '\x1B[96m',
    'bright_white': '\x1B[97m',

    'reset': '\x1B[0m',
  };

  // Get the code, defaulting to 'reset' if the color isn't found
  String code = colors[foregroundColor.toLowerCase()] ?? colors['reset']!;
  String reset = colors['reset']!;

  print('$code$stringToPrint$reset');
}

void printUsage(ArgParser parser) {
  print('Usage: xbmut <command> [arguments]');
  print('');
  print('Commands:');
  print('  ls <image_path>                      List all games and saves');
  print('  import <image_path> <zip_path>       Import a save ZIP');
  print('  export <image_path> <path> [zip]     Export a directory to ZIP (Supports name-based paths)');
  print('  rm <image_path> <path>               Delete a game or save by friendly path');
  print('  format <image_path> [size]           Produce a formatted image file (8, 16, 32, 64, 128 MB)');
  print('  extract-image <image_path> <path> [out]   Extract and convert .xbx icon(s) to .bmp');
  print('                                            <path> can be "all", a game name, or "game/save"');
  print('');
  print('Raw (low-level) commands:');
  print('  raw ls <image_path> [memcard_path]                 List raw directory entries (default /)');
  print('  raw mkdir <image_path> <memcard_path>              Create a directory on the card');
  print('  raw import [-r] <image_path> <host_path> <memcard_path>  Import host -> card');
  print('  raw export [-r] <image_path> <memcard_path> <host_path>  Export card -> host');
  print('  raw cp [-r] <image_path> <src_memcard_path> <dst_memcard_path>  Copy within card');
  print('  raw mv <image_path> <src_memcard_path> <dst_memcard_path>       Move/rename within card');
  print('  raw rm [-r] <image_path> <memcard_path>           Delete file or directory on card');
  print('');
  print('Options for "ls":');
  print('  -s, --size                           Show sizes');
  print('  -t, --time                           Show modification times');
  print('');
  print('Note: Use "-" for <image_path> to read from stdin (ls/export only).');
  print('');
  print('Examples:');
  print('  xbmut ls card.bin                    List all games and saves');
  print('  xbmut ls card.bin --size --time      List with detailed info');
  print('');
  print('  xbmut raw ls card.bin /UDATA         List raw UDATA directory');
  print('  xbmut raw mkdir card.bin /UDATA/MyGame');
  print('  xbmut raw import -r card.bin ./mydir /UDATA/mydir');
  print('  xbmut raw export card.bin /UDATA/save.bin ./save.bin');
  print('  xbmut raw cp card.bin /UDATA/a.bin /UDATA/b.bin');
  print('  xbmut raw mv card.bin /UDATA/a.bin /UDATA/c.bin');
  print('  xbmut raw rm -r card.bin /UDATA/OldGame');
  printc('  --   Linux-only-start ---', "bright_cyan");
  print('  lsblk                                        Locate plugged-in memcard/FATX usb (sdc, sdd ...)');
  print('  sudo dd if=/dev/sdc of=mu_backup.bin bs=1M   Dump the card');
  print('  sudo dd if=mu_backup.bin of=/dev/sdc bs=1M   Write back to the card (Linux) ');
  print('');
  print('  sudo cat /dev/sdc | xbmut ls -              List contents of physical drive plugged into /dev/sdc (Linux)');
  print('  sudo cat /dev/sdd | xbmut export - all      Export contents of physical drive plugged into /dev/sdc to "all.zip" (Linux)');
  printc('  --   Linux-only-end ---', "bright_cyan");
  print('  xbmut export card.bin all            Export entire card to "all.zip"');
  print('  xbmut export card.bin 55530004       Export Game folder to "55530004.zip"');
  print('  xbmut export card.bin Deathrow       Export all Deathrow saves to "Deathrow.zip"');
  print('  xbmut export card.bin "54540003/8DD53EC93D8B"     Export save to 8DD53EC93D8B.zip');
  print('  xbmut export card.bin "ESPN NFL 2K5/2K26Fran"   Export save to 2K26Fran.zip');
  print('  xbmut export card.bin all-individual ./out/  Batch export each save');
  print('  xbmut export card.bin all-individual ./out/  Batch export each save');
  print('  xbmut extract-image  mu_dump_2k4.bin "Max Payne" mp.bmp   extract title image');
  print('  xbmut extract-image mu_dump_2k4.bin 4c41001a/C3F49C01519D Player1.bmp   extract save image');
  //sudo cat /dev/sdd | ./xbmut export - all
}

Future<XboxMemoryUnit> _loadMU(String path, {bool writeAccess = false}) async {
  if (path == '-') {
    if (writeAccess) {
      throw Exception('Write access is not supported when reading from stdin.');
    }
    print('Reading from stdin...');
    final bytes = await stdin.fold<List<int>>([], (prev, element) => prev..addAll(element));
    return XboxMemoryUnit.fromBytes(Uint8List.fromList(bytes));
  }

  final file = File(path);
  if (!file.existsSync()) {
    throw FileSystemException('File does not exist', file.absolute.path, const OSError('No such file or directory', 2));
  }
  return XboxMemoryUnit.fromFile(file, writeAccess: writeAccess);
}

Future<void> handleRm(ArgResults results) async {
  if (results.rest.length < 2) {
    print('Usage: xbmut rm <image_path> <path>');
    return;
  }

  final imagePath = results.rest[0];
  final searchPath = results.rest[1];

  final mu = await _loadMU(imagePath, writeAccess: true);

  print('Searching for $searchPath to delete...');
  mu.delete(searchPath);
  mu.flush();
  print('Done.');
}

Future<void> handleFormat(ArgResults results) async {
  if (results.rest.isEmpty || results.rest.length > 2) {
    print('Usage: xbmut format <image_path> [size_in_mb]');
    return;
  }

  final path = results.rest[0];
  var size = 8 * 1024 * 1024;
  if (results.rest.length == 2) {
    final mb = int.tryParse(results.rest[1]);
    if (mb == null || ![8, 16, 32, 64, 128].contains(mb)) {
      print('Error: Size must be 8, 16, 32, 64, or 128 (MB).');
      return;
    }
    size = mb * 1024 * 1024;
  }

  print('Formatting $path (${size ~/ (1024 * 1024)}MB)...');
  final mu = XboxMemoryUnit.format(size: size);
  File(path).writeAsBytesSync(mu.bytes);
  print('Done.');
}

Future<void> handleLs(ArgResults results) async {
  if (results.rest.isEmpty) {
    print('Usage: xbmut ls <image_path>');
    return;
  }

  final imagePath = results.rest[0];
  final showSize = results['size'] as bool;
  final showTime = results['time'] as bool;
  final mu = await _loadMU(imagePath, writeAccess: false);

  print('Listing contents...');
  for (final title in mu.titles) {
    final sizeStr = showSize ? " [${_formatSize(title.size)}]" : "";
    final timeStr = showTime ? " [${_formatTime(title.modifiedAt)}]" : "";
    print('Game: ${title.name} (${title.id})$sizeStr$timeStr');
    
    for (final save in title.saves) {
      final sSizeStr = showSize ? " [${_formatSize(save.size)}]" : "";
      final sTimeStr = showTime ? " [${_formatTime(save.modifiedAt)}]" : "";
      print('  - Save: ${save.name} (${save.folderName})$sSizeStr$sTimeStr');
    }
  }
  
  print('\nFree Space: ${_formatSize(mu.freeBytes)} / ${_formatSize(mu.totalBytes)}');
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _formatTime(DateTime dt) {
  final y = dt.year.toString().padLeft(4, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final h = dt.hour.toString().padLeft(2, '0');
  final min = dt.minute.toString().padLeft(2, '0');
  final s = dt.second.toString().padLeft(2, '0');
  return '$y-$m-$d $h:$min:$s';
}

Future<void> handleImport(ArgResults results) async {
  if (results.rest.length < 2) {
    print('Usage: xbmut import <image_path> <zip_path>');
    return;
  }

  final imagePath = results.rest[0];
  final zipPath = results.rest[1];

  final mu = await _loadMU(imagePath, writeAccess: true);

  if (!File(zipPath).existsSync()) {
    print('Error: ZIP $zipPath does not exist.');
    return;
  }

  print('Importing $zipPath...');
  final zipBytes = File(zipPath).readAsBytesSync();
  mu.importZip(zipBytes);
  mu.flush();
  print('Done.');
}

Future<void> handleExport(ArgResults results) async {
  if (results.rest.length < 2) {
    print('Usage: xbmut export <image_path> <search_path> [zip_path/out_dir]');
    return;
  }

  final imagePath = results.rest[0];
  final searchPath = results.rest[1];
  final mu = await _loadMU(imagePath, writeAccess: false);

  if (searchPath.toLowerCase() == 'all-individual') {
    final outDir = Directory(results.rest.length > 2 ? results.rest[2] : '.');
    if (!outDir.existsSync()) outDir.createSync(recursive: true);

    print('Batch exporting all saves to individual ZIPs in ${outDir.path}...');
    var count = 0;
    for (final title in mu.titles) {
      for (final save in title.saves) {
        final filename = _sanitizeFilename('${title.name}.${save.name}.zip');
        final path = '${outDir.path}/$filename';
        print('  Exporting: $filename');
        File(path).writeAsBytesSync(save.exportZip());
        count++;
      }
    }
    print('\nDone. Exported $count saves.');
    return;
  }

  // Single export
  String zipPath;
  if (results.rest.length > 2) {
    zipPath = results.rest[2];
  } else {
    final parts = searchPath.split('/').where((p) => p.isNotEmpty);
    zipPath = '${parts.last}.zip';
  }

  print('Searching for $searchPath...');
  final zipBytes = mu.export(searchPath);
  print('Exporting to $zipPath...');
  File(zipPath).writeAsBytesSync(zipBytes);
  print('Done.');
}

String _sanitizeFilename(String name) {
  return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
}

Future<void> handleExtractImage(ArgResults results) async {
  if (results.rest.length < 2) {
    print('Usage: xbmut extract-image <image_path> <search_path> [out]');
    return;
  }

  final imagePath = results.rest[0];
  final searchPath = results.rest[1];
  final mu = await _loadMU(imagePath, writeAccess: false);

  if (searchPath.toLowerCase() == 'all') {
    final outDir = Directory(results.rest.length > 2 ? results.rest[2] : '.');
    if (!outDir.existsSync()) outDir.createSync(recursive: true);

    print('Extracting all images to ${outDir.path}...');
    var count = 0;
    for (final title in mu.titles) {
      final titleBmp = title.titleImageBmp;
      if (titleBmp != null) {
        final filename = _sanitizeFilename('${title.name}_Title.bmp');
        File('${outDir.path}/$filename').writeAsBytesSync(titleBmp);
        print('  Saved: $filename');
        count++;
      }
      for (final save in title.saves) {
        final saveBmp = save.saveImageBmp;
        if (saveBmp != null) {
          final filename = _sanitizeFilename('${title.name}_${save.name}_Save.bmp');
          File('${outDir.path}/$filename').writeAsBytesSync(saveBmp);
          print('  Saved: $filename');
          count++;
        }
      }
    }
    print('\nDone. Extracted $count images.');
    return;
  }

  // Single extraction (Game or Save)
  print('Searching for $searchPath...');
  
  if (searchPath.contains('/')) {
    // Likely a save path "Game/Save"
    final parts = searchPath.split('/');
    final title = mu.findTitle(parts[0]);
    if (title == null) {
      print('Error: Game "${parts[0]}" not found.');
      return;
    }
    final save = title.findSave(parts[1]);
    if (save == null) {
      print('Error: Save "${parts[1]}" not found in ${title.name}.');
      return;
    }
    
    final raw = save.saveImage;
    if (raw == null) {
      print('Error: SaveImage.xbx not found for this save.');
      return;
    }
    final bmp = XbxImageConverter.convertToBmp(raw);
    if (bmp == null) {
      print('Error: SaveImage.xbx exists but failed to convert (Unsupported XPR0 format or size).');
      return;
    }
    final outPath = results.rest.length > 2 ? results.rest[2] : _sanitizeFilename('${title.name}_${save.name}.bmp');
    File(outPath).writeAsBytesSync(bmp);
    print('Extracted to $outPath');
  } else {
    // Likely a game name or ID
    final title = mu.findTitle(searchPath);
    if (title == null) {
      print('Error: Game "$searchPath" not found.');
      return;
    }
    final raw = title.titleImage;
    if (raw == null) {
      print('Error: TitleImage.xbx not found for this game.');
      return;
    }
    final bmp = XbxImageConverter.convertToBmp(raw);
    if (bmp == null) {
      print('Error: TitleImage.xbx exists but failed to convert (Unsupported XPR0 format or size).');
      return;
    }
    final outPath = results.rest.length > 2 ? results.rest[2] : _sanitizeFilename('${title.name}.bmp');
    File(outPath).writeAsBytesSync(bmp);
    print('Extracted to $outPath');
  }
}

Future<void> handleRaw(ArgResults command) async {
  final sub = command.command;
  if (sub == null) {
    print('Usage: xbmut raw <ls|mkdir|cp|import|export|rm|mv> ...');
    return;
  }

  switch (sub.name) {
    case 'ls':
      await handleRawLs(sub);
      break;
    case 'mkdir':
      await handleRawMkdir(sub);
      break;
    case 'cp':
      await handleRawCp(sub);
      break;
    case 'import':
      await handleRawImport(sub);
      break;
    case 'export':
      await handleRawExport(sub);
      break;
    case 'rm':
      await handleRawRm(sub);
      break;
    case 'mv':
      await handleRawMv(sub);
      break;
    default:
      print('Unknown raw subcommand: ${sub.name}');
  }
}

Future<void> handleRawLs(ArgResults results) async {
  if (results.rest.isEmpty || results.rest.length > 2) {
    print('Usage: xbmut raw ls <image_path> [memcard_path]');
    return;
  }

  final imagePath = results.rest[0];
  final memcardPath = results.rest.length == 2 ? results.rest[1] : '/';
  final mu = await _loadMU(imagePath, writeAccess: false);

  final entries = mu.rawLs(memcardPath);
  for (final entry in entries) {
    print(entry);
  }
}

Future<void> handleRawMkdir(ArgResults results) async {
  if (results.rest.length != 2) {
    print('Usage: xbmut raw mkdir <image_path> <memcard_path>');
    return;
  }

  final imagePath = results.rest[0];
  final memcardPath = results.rest[1];
  final mu = await _loadMU(imagePath, writeAccess: true);

  mu.rawMkdir(memcardPath);
  mu.flush();
  print('Created $memcardPath');
}

Future<void> handleRawCp(ArgResults results) async {
  if (results.rest.length != 3) {
    print('Usage: xbmut raw cp [-r] <image_path> <src_memcard_path> <dst_memcard_path>');
    return;
  }

  final imagePath = results.rest[0];
  final src = results.rest[1];
  final dst = results.rest[2];
  final recursive = results['recursive'] as bool;

  final mu = await _loadMU(imagePath, writeAccess: true);
  mu.rawCpWithinCard(src, dst, recursive: recursive);
  mu.flush();
  print('Copied $src -> $dst');
}

Future<void> handleRawImport(ArgResults results) async {
  if (results.rest.length != 3) {
    print('Usage: xbmut raw import [-r] <image_path> <host_path> <memcard_path>');
    return;
  }

  final imagePath = results.rest[0];
  final hostPath = results.rest[1];
  final memcardPath = results.rest[2];
  final recursive = results['recursive'] as bool;

  final mu = await _loadMU(imagePath, writeAccess: true);

  final host = File(hostPath);
  if (!host.existsSync()) {
    print('Error: host path does not exist: $hostPath');
    return;
  }

  if (host.statSync().type == FileSystemEntityType.directory) {
    if (!recursive) {
      print('Error: directory import requires -r');
      return;
    }

    for (final entity in host.listSync()) {
      final entityName = entity.uri.pathSegments.isEmpty ? entity.path.split('/').last : entity.uri.pathSegments.last;
      final target = '$memcardPath/$entityName';
      if (entity is File) {
        mu.rawWriteFile(target, entity.readAsBytesSync());
      } else if (entity is Directory) {
        final srcDir = Directory(entity.path);
        _importDirectoryToCard(mu, srcDir, target);
      }
    }
  } else {
    mu.rawWriteFile(memcardPath, host.readAsBytesSync());
  }

  mu.flush();
  print('Imported $hostPath -> $memcardPath');
}

void _importDirectoryToCard(XboxMemoryUnit mu, Directory dir, String targetPath) {
  mu.rawMkdir(targetPath);
  for (final entity in dir.listSync()) {
    final finalName = entity.uri.pathSegments.isEmpty ? entity.path.split('/').last : entity.uri.pathSegments.last;
    final childTarget = '$targetPath/$finalName';
    if (entity is File) {
      mu.rawWriteFile(childTarget, entity.readAsBytesSync());
    } else if (entity is Directory) {
      _importDirectoryToCard(mu, entity, childTarget);
    }
  }
}

Future<void> handleRawExport(ArgResults results) async {
  if (results.rest.length != 3) {
    print('Usage: xbmut raw export [-r] <image_path> <memcard_path> <host_path>');
    return;
  }

  final imagePath = results.rest[0];
  final memcardPath = results.rest[1];
  final hostPath = results.rest[2];
  final recursive = results['recursive'] as bool;

  final mu = await _loadMU(imagePath, writeAccess: false);

  final entry = mu.rawEntry(memcardPath);
  if (entry == null) {
    print('Error: path not found: $memcardPath');
    return;
  }

  if (entry.isDirectory) {
    if (!recursive) {
      print('Error: directory export requires -r');
      return;
    }

    final hostDir = Directory(hostPath);
    if (!hostDir.existsSync()) {
      hostDir.createSync(recursive: true);
    }

    for (final child in mu.rawLs(memcardPath)) {
      final childPath = child.endsWith('/') ? child.substring(0, child.length - 1) : child;
      final childMem = '${memcardPath.endsWith('/') ? memcardPath.substring(0, memcardPath.length - 1) : memcardPath}/$childPath';
      final childEntry = mu.rawEntry(childMem);
      if (childEntry == null) continue;
      if (childEntry.isDirectory) {
        final subDir = Directory('$hostPath/$childPath');
        if (!subDir.existsSync()) {
          subDir.createSync(recursive: true);
        }
        await handleRawExport(ArgResults(ArgParser()..addCommand('raw')..addCommand('export'), []));
      } else {
        File('$hostPath/$childPath').writeAsBytesSync(mu.rawReadFile(childMem));
      }
    }
    return;
  }

  final hostFile = File(hostPath);
  final parent = hostFile.parent;
  if (!parent.existsSync()) parent.createSync(recursive: true);
  hostFile.writeAsBytesSync(mu.rawReadFile(memcardPath));
  print('Exported $memcardPath -> $hostPath');
}

Future<void> handleRawRm(ArgResults results) async {
  if (results.rest.length != 2) {
    print('Usage: xbmut raw rm [-r] <image_path> <memcard_path>');
    return;
  }

  final imagePath = results.rest[0];
  final memcardPath = results.rest[1];
  final recursive = results['recursive'] as bool;

  final mu = await _loadMU(imagePath, writeAccess: true);
  mu.rawRm(memcardPath, recursive: recursive);
  mu.flush();
  print('Removed $memcardPath');
}

Future<void> handleRawMv(ArgResults results) async {
  if (results.rest.length != 3) {
    print('Usage: xbmut raw mv <image_path> <src_memcard_path> <dst_memcard_path>');
    return;
  }

  final imagePath = results.rest[0];
  final src = results.rest[1];
  final dst = results.rest[2];

  final mu = await _loadMU(imagePath, writeAccess: true);
  mu.rawMv(src, dst);
  mu.flush();
  print('Moved $src -> $dst');
}
