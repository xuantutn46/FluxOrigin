/// Tests for the new Batch Translation feature (issue #5).
///
/// Covers the file-discovery / path-handling logic in
/// [BatchTranslationController], which is the only piece of the batch
/// pipeline that can be tested without a live AI server.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flux_origin/controllers/batch_translation_controller.dart';
import 'package:path/path.dart' as path;

void main() {
  group('BatchTranslationController.scanFolder', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot =
          await Directory.systemTemp.createTemp('batch_scan_test_');
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    Future<void> touch(String relPath, {List<int>? bytes}) async {
      final f = File('${tempRoot.path}${Platform.pathSeparator}$relPath');
      await f.create(recursive: true);
      if (bytes != null) {
        await f.writeAsBytes(bytes);
      } else {
        await f.writeAsString('placeholder content for $relPath');
      }
    }

    test('returns empty list when folder does not exist', () async {
      final result = await BatchTranslationController.scanFolder(
        '${tempRoot.path}${Platform.pathSeparator}nope',
        extensions: const ['.txt'],
      );
      expect(result, isEmpty,
          reason: 'Missing folder must not throw — return [] so the UI shows a clean state');
    });

    test('finds all .txt files at the top level', () async {
      await touch('a.txt');
      await touch('b.txt');
      await touch('c.md'); // should be ignored
      await touch('d.json'); // should be ignored

      final result = await BatchTranslationController.scanFolder(
        tempRoot.path,
        extensions: const ['.txt'],
      );

      expect(result.length, equals(2));
      expect(
        result.map((p) => p.split(Platform.pathSeparator).last).toList(),
        containsAll(['a.txt', 'b.txt']),
        reason: 'Only .txt files must be returned, sorted',
      );
    });

    test('recursive=true descends into sub-folders', () async {
      await touch('top.txt');
      await touch('sub1${Platform.pathSeparator}inner1.txt');
      await touch('sub1${Platform.pathSeparator}sub2${Platform.pathSeparator}deep.txt');
      await touch('sub1${Platform.pathSeparator}skip.md');

      final result = await BatchTranslationController.scanFolder(
        tempRoot.path,
        recursive: true,
        extensions: const ['.txt'],
      );

      expect(result.length, equals(3),
          reason: 'recursive must pick up nested .txt files at any depth');
      final names = result
          .map((p) => p.split(Platform.pathSeparator).last)
          .toList();
      expect(names, containsAll(['top.txt', 'inner1.txt', 'deep.txt']));
    });

    test('recursive=false leaves sub-folder files alone', () async {
      await touch('top.txt');
      await touch('sub${Platform.pathSeparator}hidden.txt');

      final result = await BatchTranslationController.scanFolder(
        tempRoot.path,
        recursive: false,
        extensions: const ['.txt'],
      );

      expect(result.length, equals(1));
      expect(result.first.endsWith('top.txt'), isTrue);
    });

    test('skips hidden files / folders (starting with .)', () async {
      await touch('normal.txt');
      await touch('.hidden.txt');
      await touch('.cache${Platform.pathSeparator}inside.txt');
      await touch('.DS_Store'); // even when extension is non-.txt, must be skipped

      final result = await BatchTranslationController.scanFolder(
        tempRoot.path,
        recursive: true,
        extensions: const ['.txt'],
      );

      expect(result.length, equals(1),
          reason: 'Hidden files / folders must never enter the batch');
      expect(result.first.endsWith('normal.txt'), isTrue);
    });

    test('extension matching is case-insensitive', () async {
      await touch('UPPER.TXT');
      await touch('lower.txt');
      await touch('Mixed.Txt');

      final result = await BatchTranslationController.scanFolder(
        tempRoot.path,
        extensions: const ['.txt'],
      );

      expect(result.length, equals(3),
          reason: '.TXT / .Txt / .txt must all be treated as .txt');
    });

    test('returns results sorted (deterministic order across OSes)', () async {
      await touch('zeta.txt');
      await touch('alpha.txt');
      await touch('mike.txt');

      final result = await BatchTranslationController.scanFolder(
        tempRoot.path,
        extensions: const ['.txt'],
      );

      final names = result
          .map((p) => p.split(Platform.pathSeparator).last)
          .toList();
      expect(names, equals(['alpha.txt', 'mike.txt', 'zeta.txt']),
          reason: 'scanFolder must sort so the UI order is stable');
    });

    test('accepts multiple extensions', () async {
      await touch('a.txt');
      await touch('b.md');
      await touch('c.json'); // ignored
      await touch('d.txt');

      final result = await BatchTranslationController.scanFolder(
        tempRoot.path,
        extensions: const ['.txt', '.md'],
      );

      expect(result.length, equals(3),
          reason: 'When multiple extensions are given, all are accepted');
    });
  });

  group('BatchTranslationController output-path naming', () {
    // Build a per-test temp folder so path.join uses the host separator
    // (no hard-coded '/' or '\\'). Recreated for every test to avoid
    // cross-test pollution.
    late Directory localTmp;

    setUp(() async {
      localTmp = await Directory.systemTemp.createTemp('batch_path_');
    });

    tearDown(() async {
      if (await localTmp.exists()) {
        await localTmp.delete(recursive: true);
      }
    });

    test('produces <name>_translated.txt next to the source', () {
      final src = path.join(localTmp.path, 'books', 'chapter1.txt');
      final out = BatchTranslationController.debugDeriveOutputPath(src);
      final expected =
          path.join(localTmp.path, 'books', 'chapter1_translated.txt');
      expect(out, equals(expected));
    });

    test('preserves the source folder for files with spaces', () {
      final src = path.join(localTmp.path, 'My Books', 'Vol 1', 'chap 1.txt');
      final out = BatchTranslationController.debugDeriveOutputPath(src);
      expect(out.endsWith('chap 1_translated.txt'), isTrue,
          reason: 'Spaces in filenames must round-trip through path.join');
    });

    test('strips the original extension and adds _translated.txt', () {
      final src = path.join(localTmp.path, 'x.epub');
      final out = BatchTranslationController.debugDeriveOutputPath(src);
      final expected = path.join(localTmp.path, 'x_translated.txt');
      expect(out, equals(expected),
          reason:
              'EPUB inputs should still produce a .txt output by the same convention');
    });

    test('places output in the same folder as the source', () {
      final src = path.join(localTmp.path, 'nested', 'deep', 'input.txt');
      final out = BatchTranslationController.debugDeriveOutputPath(src);
      expect(path.dirname(out), equals(path.dirname(src)),
          reason:
              'The output file must live next to the source — never in a different folder');
    });
  });
}
