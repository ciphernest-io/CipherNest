import 'package:intl/intl.dart';
import '../models/file_model.dart';

class DateSection {
  final String label;
  final List<CnestFile> files;

  DateSection({required this.label, required this.files});
}

/// Groups a list of [CnestFile] (already sorted by createdAt DESC) into
/// date sections: Today, Yesterday, This Week, Last Week, then "Month Year".
List<DateSection> groupByDate(List<CnestFile> files) {
  if (files.isEmpty) return [];

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final thisWeekStart = today.subtract(Duration(days: today.weekday - 1));
  final lastWeekStart = thisWeekStart.subtract(const Duration(days: 7));
  final monthFmt = DateFormat.yMMMM();

  final sections = <DateSection>[];
  String? currentLabel;
  List<CnestFile> currentFiles = [];

  for (final file in files) {
    final date = DateTime(
      file.createdAt.year,
      file.createdAt.month,
      file.createdAt.day,
    );

    String label;
    if (!date.isBefore(today)) {
      label = 'Today';
    } else if (!date.isBefore(yesterday)) {
      label = 'Yesterday';
    } else if (!date.isBefore(thisWeekStart)) {
      label = 'This Week';
    } else if (!date.isBefore(lastWeekStart)) {
      label = 'Last Week';
    } else {
      label = monthFmt.format(file.createdAt);
    }

    if (label != currentLabel) {
      if (currentFiles.isNotEmpty) {
        sections.add(DateSection(label: currentLabel!, files: currentFiles));
      }
      currentLabel = label;
      currentFiles = [file];
    } else {
      currentFiles.add(file);
    }
  }

  if (currentFiles.isNotEmpty && currentLabel != null) {
    sections.add(DateSection(label: currentLabel, files: currentFiles));
  }

  return sections;
}

/// "Month Year" sections (July 2026) — the gallery's mid zoom levels.
List<DateSection> groupByMonth(List<CnestFile> files) {
  final fmt = DateFormat.yMMMM();
  return _groupByLabel(files, (f) => fmt.format(f.createdAt));
}

/// Year sections — the gallery's most zoomed-out level.
List<DateSection> groupByYear(List<CnestFile> files) =>
    _groupByLabel(files, (f) => '${f.createdAt.year}');

/// Folds an already-sorted list into contiguous sections that share a label.
List<DateSection> _groupByLabel(
  List<CnestFile> files,
  String Function(CnestFile) labelOf,
) {
  final sections = <DateSection>[];
  String? currentLabel;
  var currentFiles = <CnestFile>[];

  for (final file in files) {
    final label = labelOf(file);
    if (label != currentLabel) {
      if (currentFiles.isNotEmpty) {
        sections.add(DateSection(label: currentLabel!, files: currentFiles));
      }
      currentLabel = label;
      currentFiles = [file];
    } else {
      currentFiles.add(file);
    }
  }

  if (currentFiles.isNotEmpty && currentLabel != null) {
    sections.add(DateSection(label: currentLabel, files: currentFiles));
  }
  return sections;
}
