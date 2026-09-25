class TaskScheduleTimes {
  const TaskScheduleTimes._();

  static DateTime eventTime({
    required DateTime dueDate,
    DateTime? startTime,
    DateTime? now,
  }) {
    if (startTime != null) return startTime;
    final current = now ?? DateTime.now();
    final hasExplicitTime = dueDate.hour != 0 ||
        dueDate.minute != 0 ||
        dueDate.second != 0 ||
        dueDate.millisecond != 0 ||
        dueDate.microsecond != 0;
    if (hasExplicitTime && dueDate.isAfter(current)) return dueDate;
    final nine = DateTime(dueDate.year, dueDate.month, dueDate.day, 9);
    if (nine.isAfter(current)) return nine;
    return dueDate;
  }

  static DateTime newTaskDueDate({DateTime? now}) =>
      (now ?? DateTime.now()).add(const Duration(minutes: 10));

  static DateTime reminderTime({
    required DateTime taskDateTime,
    required int minutes,
  }) {
    if (minutes <= 0 || minutes > 1440) {
      throw RangeError.range(minutes, 1, 1440, 'minutes');
    }
    return taskDateTime.subtract(Duration(minutes: minutes));
  }
}
