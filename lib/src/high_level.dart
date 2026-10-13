import 'dart:io';
import 'dart:typed_data';
import 'fatx.dart';
import 'fatx_image.dart';
import 'formatter.dart';
import 'importer.dart';
import 'exporter.dart';
import 'searcher.dart';
import 'xbx_meta.dart';
import 'xbx_image_converter.dart';
import 'models.dart';
import 'storage.dart';
import 'storage_factory_compat.dart';

// High-level API types

class XboxMemoryUnit {
  final FatxImage _image;

  XboxMemoryUnit._(this._image);

  /// Formats a new Xbox Memory Unit in memory. Default is 8MB.
  factory XboxMemoryUnit.format({int size = 8388608}) {
    final buffer = FatxFormatter.format(size: size);
    return XboxMemoryUnit._(FatxImage(MemoryStorage(buffer)));
  }

  /// Loads an Xbox Memory Unit from an in-memory buffer.
  factory XboxMemoryUnit.fromBytes(Uint8List bytes) {
    return XboxMemoryUnit._(FatxImage(MemoryStorage(bytes)));
  }

  /// Opens an Xbox Memory Unit from a physical file or device.
  /// Not available on web.
  factory XboxMemoryUnit.fromFile(dynamic file, {bool writeAccess = true}) {
    final storage = createFileStorage(file, writeAccess: writeAccess);
    return XboxMemoryUnit._(FatxImage(storage));
  }

  /// Returns the raw bytes of the memory unit.
  Uint8List get bytes {
    if (_image.storage is MemoryStorage) {
      return (_image.storage as MemoryStorage).bytes;
    }
    return _image.storage.read(0, _image.storage.length);
  }

  /// Flushes any pending writes to the underlying storage.
  void flush() {
    _image.storage.flush();
  }

  /// Returns the number of free bytes available.
  int get freeBytes => _image.fat.countFreeClusters() * _image.config.clusterSizeReal;

  /// Returns the total capacity of the storage in bytes.
  int get totalBytes => _image.storage.length;

  /// Returns a list of all games/titles on the memory unit.
  List<XboxTitle> get titles {
    final entries = _image.listDirectory(1); // Root
    return entries
        .where((e) => e.isDirectory)
        .map((e) => XboxTitle._(this, e))
        .toList();
  }

  /// Imports a save ZIP into the memory unit.
  void importZip(Uint8List zipBytes) {
    final importer = FatxImporter(_image);
    importer.importZip(zipBytes);
  }

  /// Deletes a game or save by friendly path (e.g., "NFL 2K5/Roster1").
  void delete(String path) {
    final searcher = FatxSearcher(_image);
    final result = searcher.resolvePath(path);

    if (result.saveCluster != null) {
      // Delete specific save folder inside the game folder
      final gameEntries = _image.listDirectory(result.gameCluster);
      final saveFolder = gameEntries.firstWhere((e) => e.firstCluster == result.saveCluster).filename;
      _image.deleteEntry(result.gameCluster, saveFolder);
    } else {
      // Delete the entire game folder from root
      final rootEntries = _image.listDirectory(1);
      final gameFolder = rootEntries.firstWhere((e) => e.firstCluster == result.gameCluster).filename;
      _image.deleteEntry(1, gameFolder);
    }
  }

  /// Exports the entire memory unit content to a ZIP (prepends UDATA/).
  Uint8List exportAll() {
    final exporter = FatxExporter(_image);
    return exporter.exportToZip(1, "");
  }

  /// Exports a specific game or save by friendly path (e.g., "NFL 2K5/Roster1").
  /// Use "all" to export everything.
  Uint8List export(String path) {
    if (path.toLowerCase() == 'all') {
      return exportAll();
    }
    final searcher = FatxSearcher(_image);
    final result = searcher.resolvePath(path);
    final exporter = FatxExporter(_image);
    return exporter.exportGameOrSave(result);
  }

  /// Finds a title by its internal name or Title ID (case-insensitive).
  XboxTitle? findTitle(String nameOrId) {
    final search = nameOrId.toUpperCase();
    for (final title in titles) {
      if (title.name.toUpperCase() == search || title.id.toUpperCase() == search) return title;
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Raw FATX filesystem helpers
  // -------------------------------------------------------------------------

  String _normalizeRawPath(String path) {
    final p = path.trim();
    if (p.isEmpty || p == '/') return '/';
    return p.startsWith('/') ? p : '/$p';
  }

  List<String> _splitRawPath(String path) {
    final norm = _normalizeRawPath(path);
    if (norm == '/') return const [];
    return norm.split('/').where((s) => s.isNotEmpty).toList();
  }

  int _resolveRawDirCluster(String path) {
    final parts = _splitRawPath(path);
    var current = 1; // root
    for (final part in parts) {
      final entries = _image.listDirectory(current);
      final match = entries.where((e) => e.isDirectory && e.filename == part).toList();
      if (match.isEmpty) {
        throw Exception('Directory not found: $path');
      }
      current = match.first.firstCluster;
    }
    return current;
  }

  FatxDirEntry? _findRawEntryInDir(int dirCluster, String name) {
    final entries = _image.listDirectory(dirCluster);
    for (final entry in entries) {
      if (entry.filename == name) return entry;
    }
    return null;
  }

  FatxDirEntry? _findRawEntry(String path) {
    final parts = _splitRawPath(path);
    if (parts.isEmpty) return null;

    final parentPath = parts.length == 1 ? '/' : '/' + parts.sublist(0, parts.length - 1).join('/');
    final filename = parts.last;

    final parentCluster = _resolveRawDirCluster(parentPath);
    final entry = _findRawEntryInDir(parentCluster, filename);
    return entry;
  }

  void _ensureRawDir(String path) {
    final parts = _splitRawPath(path);
    if (parts.isEmpty) return;

    var current = 1;
    for (final part in parts) {
      final entries = _image.listDirectory(current);
      final existing = entries.where((e) => e.isDirectory && e.filename == part).toList();
      if (existing.isEmpty) {
        final dirCluster = _image.fat.allocateCluster();
        final dirEntry = FatxDirEntry()
          ..filename = part
          ..filenameLength = part.length
          ..attributes = FatxDirEntry.attrDirectory
          ..firstCluster = dirCluster
          ..fileSize = 0;

        final padding = Uint8List(_image.config.clusterSizeReal)
          ..fillRange(0, _image.config.clusterSizeReal, 0xFF);
        _image.writeCluster(dirCluster, padding);

        _image.addEntry(current, dirEntry);
        current = dirCluster;
      } else {
        current = existing.first.firstCluster;
      }
    }
  }

  int _writeRawData(Uint8List data) {
    if (data.isEmpty) return 0;

    final numClusters = (data.length / _image.config.clusterSizeReal).ceil();
    final clusters = <int>[];
    for (var i = 0; i < numClusters; i++) {
      clusters.add(_image.fat.allocateCluster());
    }

    for (var i = 0; i < clusters.length - 1; i++) {
      _image.fat.setEntry(clusters[i], clusters[i + 1]);
    }
    _image.fat.setEntry(clusters.last, 0xFFFF);

    for (var i = 0; i < clusters.length; i++) {
      final start = i * _image.config.clusterSizeReal;
      var end = (i + 1) * _image.config.clusterSizeReal;

      final chunk = Uint8List(_image.config.clusterSizeReal);
      if (end > data.length) {
        final sub = data.sublist(start);
        chunk.setRange(0, sub.length, sub);
      } else {
        final sub = data.sublist(start, end);
        chunk.setRange(0, _image.config.clusterSizeReal, sub);
      }
      _image.writeCluster(clusters[i], chunk);
    }

    return clusters.first;
  }

  /// Writes a file into the card at `memcardPath` (creating parent dirs as needed).
  void rawWriteFile(String memcardPath, Uint8List data) {
    final norm = _normalizeRawPath(memcardPath);
    final parts = _splitRawPath(norm);
    if (parts.isEmpty) {
      throw Exception('Cannot write to root directory');
    }

    final parentPath = parts.length == 1 ? '/' : '/' + parts.sublist(0, parts.length - 1).join('/');
    final filename = parts.last;

    _ensureRawDir(parentPath);

    final parentCluster = _resolveRawDirCluster(parentPath);
    final existing = _findRawEntryInDir(parentCluster, filename);
    if (existing != null) {
      _image.deleteEntry(parentCluster, filename);
    }

    final firstCluster = _writeRawData(data);
    final entry = FatxDirEntry()
      ..filename = filename
      ..filenameLength = filename.length
      ..attributes = 0x00
      ..firstCluster = firstCluster
      ..fileSize = data.length;

    _image.addEntry(parentCluster, entry);
  }

  /// Reads a file from the card at `memcardPath`.
  Uint8List rawReadFile(String memcardPath) {
    final entry = _findRawEntry(memcardPath);
    if (entry == null || entry.isDirectory) {
      throw Exception('File not found: $memcardPath');
    }
    return _image.readChain(entry.firstCluster, entry.fileSize);
  }

  /// Lists entries in a directory path on the card; directories have a trailing '/'.
  List<String> rawLs(String path) {
    final dir = _normalizeRawPath(path);
    final dirCluster = _resolveRawDirCluster(dir == '/' ? '/' : dir);
    final entries = _image.listDirectory(dirCluster);
    final list = entries.map((e) => e.isDirectory ? '${e.filename}/' : e.filename).toList();
    list.sort();
    return list;
  }

  /// Create a directory (and parents) on the card.
  void rawMkdir(String memcardPath) {
    final norm = _normalizeRawPath(memcardPath);
    _ensureRawDir(norm);
  }

  /// Copy within the card. If recursive and src is a directory, copy children.
  void rawCpWithinCard(String srcPath, String dstPath, {bool recursive = false}) {
    final srcEntry = _findRawEntry(srcPath);
    if (srcEntry == null) {
      throw Exception('Source not found: $srcPath');
    }

    if (srcEntry.isDirectory) {
      if (!recursive) throw Exception('Source is a directory; use recursive copy');
      // Ensure destination dir
      rawMkdir(dstPath);
      final children = _image.listDirectory(srcEntry.firstCluster);
      for (final child in children) {
        final childSrc = srcPath.endsWith('/') ? '$srcPath${child.filename}' : '$srcPath/${child.filename}';
        final childDst = dstPath.endsWith('/') ? '$dstPath${child.filename}' : '$dstPath/${child.filename}';
        if (child.isDirectory) {
          rawCpWithinCard(childSrc, childDst, recursive: true);
        } else {
          final data = _image.readChain(child.firstCluster, child.fileSize);
          rawWriteFile(childDst, data);
        }
      }
      return;
    }

    // File copy
    final data = _image.readChain(srcEntry.firstCluster, srcEntry.fileSize);
    rawWriteFile(dstPath, data);
  }

  /// Import from host filesystem into card. Supports files and directories (-r).
  void rawImportFromHost(String hostPath, String memcardPath, {bool recursive = false}) {
    final f = File(hostPath);
    if (f.existsSync()) {
      rawWriteFile(memcardPath, f.readAsBytesSync());
      return;
    }

    final d = Directory(hostPath);
    if (d.existsSync()) {
      if (!recursive) throw Exception('Source is a directory; use recursive import');
      // Create destination directory and recurse
      rawMkdir(memcardPath);
      for (final entity in d.listSync()) {
        final name = entity.uri.pathSegments.isEmpty ? entity.path.split('/').last : entity.uri.pathSegments.last;
        final childDest = memcardPath.endsWith('/') ? '$memcardPath$name' : '$memcardPath/$name';
        if (entity is File) {
          rawWriteFile(childDest, File(entity.path).readAsBytesSync());
        } else if (entity is Directory) {
          rawImportFromHost(entity.path, childDest, recursive: true);
        }
      }
      return;
    }

    throw FileSystemException('Host path does not exist', hostPath);
  }

  /// Export from card to host filesystem. Supports files and directories (-r).
  void rawExportToHost(String memcardPath, String hostPath, {bool recursive = false}) {
    final entry = _findRawEntry(memcardPath);
    if (entry == null) throw Exception('Path not found: $memcardPath');

    if (entry.isDirectory) {
      if (!recursive) throw Exception('Destination is a directory; use recursive export');
      final hostDir = Directory(hostPath);
      if (!hostDir.existsSync()) hostDir.createSync(recursive: true);

      final children = _image.listDirectory(entry.firstCluster);
      for (final child in children) {
        final childMem = memcardPath.endsWith('/') ? '$memcardPath${child.filename}' : '$memcardPath/${child.filename}';
        final childHost = hostPath.endsWith('/') ? '$hostPath${child.filename}' : '$hostPath/${child.filename}';
        if (child.isDirectory) {
          rawExportToHost(childMem, childHost, recursive: true);
        } else {
          File(childHost).writeAsBytesSync(_image.readChain(child.firstCluster, child.fileSize));
        }
      }
      return;
    }

    final hostFile = File(hostPath);
    if (!hostFile.parent.existsSync()) hostFile.parent.createSync(recursive: true);
    hostFile.writeAsBytesSync(_image.readChain(entry.firstCluster, entry.fileSize));
  }

  /// Returns the directory entry for a given memcard path, or null.
  FatxDirEntry? rawEntry(String path) {
    final parts = _splitRawPath(path);
    if (parts.isEmpty) return null;
    final parentPath = parts.length == 1 ? '/' : '/' + parts.sublist(0, parts.length - 1).join('/');
    final parentCluster = _resolveRawDirCluster(parentPath);
    return _findRawEntryInDir(parentCluster, parts.last);
  }

  /// Remove an entry (file or directory). If directory and recursive==false, throws.
  void rawRm(String memcardPath, {bool recursive = false}) {
    final parts = _splitRawPath(memcardPath);
    if (parts.isEmpty) throw Exception('Cannot remove root');

    final parentPath = parts.length == 1 ? '/' : '/' + parts.sublist(0, parts.length - 1).join('/');
    final parentCluster = _resolveRawDirCluster(parentPath);
    final name = parts.last;

    final entry = _findRawEntryInDir(parentCluster, name);
    if (entry == null) throw Exception('Path not found: $memcardPath');

    if (entry.isDirectory && !recursive) throw Exception('Directory not empty (use recursive)');

    _image.deleteEntry(parentCluster, name);
  }

  /// Move (rename) within the card. Implemented as copy + delete.
  void rawMv(String srcPath, String dstPath) {
    rawCpWithinCard(srcPath, dstPath, recursive: true);
    rawRm(srcPath, recursive: true);
  }
}

class XboxTitle {
  final XboxMemoryUnit _mu;
  final FatxDirEntry _entry;
  late final String name;

  XboxTitle._(this._mu, this._entry) {
    final metaBytes = _readFile('TitleMeta.xbx');
    name = (metaBytes != null ? XbxMeta.parseName('TitleMeta.xbx', metaBytes) : null) ?? _entry.filename;
  }

  String get id => _entry.filename;

  /// Total size of all files in this title (including all saves).
  int get size => _mu._image.calculateDirectorySize(_entry.firstCluster);

  /// Last modification time of this title folder.
  DateTime get modifiedAt => _entry.modifiedAt;

  /// Returns a list of all saves belonging to this title.
  List<XboxSave> get saves {
    final entries = _mu._image.listDirectory(_entry.firstCluster);
    return entries
        .where((e) => e.isDirectory)
        .map((e) => XboxSave._(this, e))
        .toList();
  }

  /// Returns the TitleImage.xbx bytes, if present.
  Uint8List? get titleImage => _readFile('TitleImage.xbx');

  /// Finds a save by its friendly name or folder name (case-insensitive).
  XboxSave? findSave(String nameOrFolder) {
    final search = nameOrFolder.toUpperCase();
    for (final save in saves) {
      if (save.name.toUpperCase() == search || save.folderName.toUpperCase() == search) return save;
    }
    return null;
  }

  /// Returns the TitleImage.xbx converted to BMP, if present.
  Uint8List? get titleImageBmp {
    final bytes = titleImage;
    return bytes != null ? XbxImageConverter.convertToBmp(bytes, unswizzle: false) : null;
  }

  /// Returns the TitleMeta.xbx bytes, if present.
  Uint8List? get titleMeta => _readFile('TitleMeta.xbx');

  Uint8List? _readFile(String filename) {
    final entries = _mu._image.listDirectory(_entry.firstCluster);
    final search = filename.toUpperCase();
    final file = entries.where((e) => e.filename.toUpperCase() == search).toList();
    if (file.isEmpty) return null;
    return _mu._image.readChain(file.first.firstCluster, file.first.fileSize);
  }
}

class XboxSave {
  final XboxTitle parent;
  final FatxDirEntry _entry;
  final String folderName;
  late final String name;

  XboxSave._(this.parent, this._entry) : folderName = _entry.filename {
    final metaBytes = _readFile('SaveMeta.xbx');
    name = (metaBytes != null ? XbxMeta.parseName('SaveMeta.xbx', metaBytes) : null) ?? folderName;
  }

  /// Total size of all files in this specific save.
  int get size => parent._mu._image.calculateDirectorySize(_entry.firstCluster);

  /// Last modification time of this specific save.
  DateTime get modifiedAt => _entry.modifiedAt;

  /// Exports this specific save to a ZIP buffer (Thick Export with Game context).
  Uint8List exportZip() {
    final result = FatxSearchResult(
      gameCluster: parent._entry.firstCluster,
      saveCluster: _entry.firstCluster,
      gameName: parent.name,
      saveName: name,
    );
    final exporter = FatxExporter(parent._mu._image);
    return exporter.exportGameOrSave(result);
  }

  /// Returns the SaveImage.xbx bytes, if present (checks save folder then parent title folder).
  Uint8List? get saveImage => _readFile('SaveImage.xbx') ?? parent._readFile('SaveImage.xbx');

  /// Returns the SaveImage.xbx converted to BMP, if present.
  Uint8List? get saveImageBmp {
    final bytes = saveImage;
    return bytes != null ? XbxImageConverter.convertToBmp(bytes, unswizzle: false) : null;
  }

  Uint8List? _readFile(String filename) {
    final entries = parent._mu._image.listDirectory(_entry.firstCluster);
    final search = filename.toUpperCase();
    final file = entries.where((e) => e.filename.toUpperCase() == search).toList();
    if (file.isEmpty) return null;
    return parent._mu._image.readChain(file.first.firstCluster, file.first.fileSize);
  }
}
