/// Regression test for Issue #6: "Lỗi từ điển" (User glossary ignored).
///
/// **Validates:** The fix for the bug where the system always overrode the
/// user-uploaded CSV with an AI-generated glossary. After the fix, calling
/// `TranslationController.applyUserGlossary` with a valid user file path
/// must copy the user's content verbatim into the standard glossary slot,
/// and the function must return `true`.
///
/// On the UNFIXED code, this method did not exist and the user-supplied
/// path was completely ignored — `processFile()` always called
/// `AIService.generateGlossary()` and overwrote the file.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flux_origin/controllers/translation_controller.dart';

void main() {
  group('Issue #6 fix: User glossary must be honored, not overridden', () {
    late Directory tempDir;
    late File userGlossary;
    late File targetGlossary;

    const userContent = '"叶尘","Diệp Trần"\n'
        '"长老","Trưởng lão"\n'
        '"宗","Tông"\n'
        '"掌门","Chưởng môn"\n'
        '"师兄","Sư huynh"';

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('user_dict_test_');
      userGlossary = File(
          '${tempDir.path}${Platform.pathSeparator}my_terms.csv');
      await userGlossary.writeAsString(userContent);
      targetGlossary = File(
          '${tempDir.path}${Platform.pathSeparator}book1_glossary.csv');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
        'REGRESSION #6.1: applyUserGlossary copies user file verbatim into the target slot',
        () async {
      final controller = TranslationController();

      final applied = await controller.applyUserGlossary(
        userGlossaryPath: userGlossary.path,
        glossaryFile: targetGlossary,
      );

      expect(applied, isTrue,
          reason:
              'A valid user glossary must be applied (returns true) so the controller skips AI generation');

      expect(await targetGlossary.exists(), isTrue,
          reason: 'Target glossary file must be created at the expected path');

      final written = await targetGlossary.readAsString();
      expect(written, equals(userContent),
          reason:
              'Target glossary must contain the user-supplied content EXACTLY — no AI merge, no header rewrite, no term reordering');
    });

    test(
        'REGRESSION #6.2: missing user file falls back gracefully (returns false, no crash)',
        () async {
      final controller = TranslationController();
      final nonExistent = File(
          '${tempDir.path}${Platform.pathSeparator}does_not_exist.csv');

      final applied = await controller.applyUserGlossary(
        userGlossaryPath: nonExistent.path,
        glossaryFile: targetGlossary,
      );

      expect(applied, isFalse,
          reason:
              'Missing file must return false so the caller can fall back to AI generation');
      expect(await targetGlossary.exists(), isFalse,
          reason: 'No file must be created when the user path is invalid');
    });

    test(
        'REGRESSION #6.3: null user path falls back to AI flow (returns false)',
        () async {
      final controller = TranslationController();

      final applied = await controller.applyUserGlossary(
        userGlossaryPath: null,
        glossaryFile: targetGlossary,
      );

      expect(applied, isFalse,
          reason:
              'When the user does not provide a path, the controller must fall back to AI generation');
      expect(await targetGlossary.exists(), isFalse);
    });

    test(
        'REGRESSION #6.4: empty user file falls back gracefully (returns false)',
        () async {
      final controller = TranslationController();
      final emptyFile = File(
          '${tempDir.path}${Platform.pathSeparator}empty.csv');
      await emptyFile.writeAsString('   \n  \n  ');

      final applied = await controller.applyUserGlossary(
        userGlossaryPath: emptyFile.path,
        glossaryFile: targetGlossary,
      );

      expect(applied, isFalse,
          reason: 'Empty/whitespace-only file must return false');
      expect(await targetGlossary.exists(), isFalse);
    });

    test(
        'REGRESSION #6.5: user content with quoted commas is preserved exactly (no CSV re-parse)',
        () async {
      final controller = TranslationController();
      const trickyContent = '"a, b","c, d"\n'
          '"e","f"';
      final trickyFile = File(
          '${tempDir.path}${Platform.pathSeparator}tricky.csv');
      await trickyFile.writeAsString(trickyContent);

      final applied = await controller.applyUserGlossary(
        userGlossaryPath: trickyFile.path,
        glossaryFile: targetGlossary,
      );

      expect(applied, isTrue);
      final written = await targetGlossary.readAsString();
      expect(written, equals(trickyContent),
          reason:
              'User content with quoted commas must be copied byte-for-byte — the fix must not re-parse the user file');
    });

    test(
        'REGRESSION #6.6: applying user glossary twice is idempotent (no corruption)',
        () async {
      final controller = TranslationController();

      await controller.applyUserGlossary(
        userGlossaryPath: userGlossary.path,
        glossaryFile: targetGlossary,
      );
      await controller.applyUserGlossary(
        userGlossaryPath: userGlossary.path,
        glossaryFile: targetGlossary,
      );

      final written = await targetGlossary.readAsString();
      expect(written, equals(userContent),
          reason: 'Re-applying the same user file must produce the same content');
    });
  });
}
