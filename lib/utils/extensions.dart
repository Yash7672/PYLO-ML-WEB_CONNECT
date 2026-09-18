import 'package:intl/intl.dart';

final DateFormat _displayFormat = DateFormat('MMM dd, yyyy');

extension DateExtension on DateTime {
  String toDisplayString() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // Day-arithmetic via constructor (DateTime rolls month/year over), NOT
    // add(Duration(days:1)) which is wrong across DST transitions and can
    // land 'tomorrow' back on today.
    final tomorrow = DateTime(today.year, today.month, today.day + 1);
    final checkDate = DateTime(year, month, day);

    if (checkDate == today) {
      return 'Today';
    } else if (checkDate == tomorrow) {
      return 'Tomorrow';
    } else {
      return _displayFormat.format(this);
    }
  }

  bool isSameDate(DateTime other) {
    return year == other.year && month == other.month && day == other.day;
  }
}
