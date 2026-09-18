import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../models/birthday_model.dart';
import '../models/category_model.dart';
import '../models/checklist_model.dart';
import '../models/focus_session_model.dart';
import '../models/habit_completion_item.dart';
import '../models/habit_log_item.dart';
import '../models/habit_model.dart';
import '../models/task_model.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._internal();
  DatabaseHelper._internal();
  static Database? _database;
  static String? _cachedDbPath;
  static Completer<void>? _dbInitCompleter;

  static const int schemaVersion = 12;

  /// Test hook: when set, all database paths resolve here instead of the
  /// production `taskflow.db`. Lets each parallel test isolate own a private
  /// file, avoiding cross-isolate lock/cleanup races on one shared database.
  static String? testDbPathOverride;

  Future<Database> get database async {
    if (_database != null) return _database!;
    // Serialize concurrent callers so only one _initDB runs.
    if (_dbInitCompleter != null) {
      await _dbInitCompleter!.future;
      return _database!;
    }
    _dbInitCompleter = Completer<void>();
    try {
      _database = await _initDB('taskflow.db');
      _dbInitCompleter!.complete();
    } catch (e) {
      _dbInitCompleter!.completeError(e);
      rethrow;
    } finally {
      _dbInitCompleter = null;
    }
    return _database!;
  }

  Future<String> get databasePath async {
    if (_cachedDbPath == null) {
      final dbPath = await getDatabasesPath();
      _cachedDbPath = testDbPathOverride ?? p.join(dbPath, 'taskflow.db');
    }
    return _cachedDbPath!;
  }

  Future<Database> _initDB(String filePath) async {
    if (_cachedDbPath == null) {
      final dbPath = await getDatabasesPath();
      _cachedDbPath = testDbPathOverride ?? p.join(dbPath, 'taskflow.db');
    }

    final db = await openDatabase(
      _cachedDbPath!,
      version: schemaVersion,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
    // Enable WAL plus a busy timeout so the background widget isolate's own
    // connection to the same file can read/write concurrently without
    // hitting SQLITE_BUSY lock contention.
    await db.rawQuery('PRAGMA journal_mode = WAL;');
    await db.rawQuery('PRAGMA busy_timeout = 5000;');
    return db;
  }

  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      final columns = await db.rawQuery('PRAGMA table_info(habits)');
      final hasLastCompletedDate = columns.any(
        (column) => column['name'] == 'lastCompletedDate',
      );
      if (!hasLastCompletedDate) {
        await db
            .execute('ALTER TABLE habits ADD COLUMN lastCompletedDate INTEGER');
      }
    }
    if (oldVersion < 3) {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'habit_logs'",
      );
      if (tables.isEmpty) {
        await db.execute('''
          CREATE TABLE habit_logs (
            id TEXT PRIMARY KEY,
            habitId TEXT,
            date TEXT,
            isCompleted INTEGER DEFAULT 0
          )
        ''');
      }
    }
    if (oldVersion < 4) {
      final columns = await db.rawQuery('PRAGMA table_info(tasks)');
      var hasNew = columns.any((c) => c['name'] == 'reminderMinutes');
      final hasOld = columns.any((c) => c['name'] == 'reminderMinutesBefore');
      if (!hasNew) {
        await db.execute(
            "ALTER TABLE tasks ADD COLUMN reminderMinutes TEXT DEFAULT '[]'");
        hasNew = true;
      }
      if (hasOld && hasNew) {
        final rows = await db.query('tasks', columns: ['id', 'reminderMinutesBefore', 'reminderMinutes']);
        for (final row in rows) {
          final oldVal = row['reminderMinutesBefore'];
          final newVal = row['reminderMinutes'];
          if (newVal == null || newVal == '[]' || newVal == '') {
            final List<int> migrated = [];
            if (oldVal is int && oldVal > 0) {
              migrated.add(oldVal);
            }
            await db.update(
              'tasks',
              {'reminderMinutes': jsonEncode(migrated)},
              where: 'id = ?',
              whereArgs: [row['id']],
            );
          }
        }
        // DROP COLUMN needs SQLite >= 3.35; on older devices the leftover
        // column is harmless (Task.fromMap ignores it once reminderMinutes
        // is populated), so swallow the failure instead of breaking upgrade.
        try {
          await db
              .execute('ALTER TABLE tasks DROP COLUMN reminderMinutesBefore');
        } catch (e) {
          debugPrint('reminderMinutesBefore drop skipped: $e');
        }
      }
    }
    if (oldVersion < 5) {
      await _createV5Tables(db);
    }
    if (oldVersion < 6) {
      await _createV6Tables(db);
    }
    if (oldVersion < 7) {
      await _createV7Tables(db);
    }
    if (oldVersion < 8) {
      await _createV8Tables(db);
    }
    if (oldVersion < 9) {
      await _createV9Tables(db);
    }
    if (oldVersion < 10) {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'tasks'",
      );
      if (tables.isNotEmpty) {
        final columns = await db.rawQuery('PRAGMA table_info(tasks)');
        if (!columns.any((c) => c['name'] == 'repeatMonthday')) {
          await db.execute(
              'ALTER TABLE tasks ADD COLUMN repeatMonthday INTEGER DEFAULT NULL');
        }
        // Backfill the recurrence anchor (original day-of-month) from the
        // current dueDate so existing monthly/yearly tasks stop drifting.
        final rows = await db.query('tasks');
        for (final row in rows) {
          final due = row['dueDate'];
          if (due is int && due > 0) {
            await db.update(
              'tasks',
              {'repeatMonthday': DateTime.fromMillisecondsSinceEpoch(due).day},
              where: 'id = ?',
              whereArgs: [row['id']],
            );
          }
        }
      }
    }
    if (oldVersion < 11) {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'tasks'",
      );
      if (tables.isNotEmpty) {
        final columns = await db.rawQuery('PRAGMA table_info(tasks)');
        if (!columns.any((c) => c['name'] == 'alarmEnabled')) {
          await db.execute('ALTER TABLE tasks ADD COLUMN alarmEnabled INTEGER DEFAULT 0');
        }
        if (!columns.any((c) => c['name'] == 'alarmTime')) {
          await db.execute('ALTER TABLE tasks ADD COLUMN alarmTime INTEGER DEFAULT NULL');
        }
      }
    }
    if (oldVersion < 12) {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'tasks'",
      );
      if (tables.isNotEmpty) {
        final columns = await db.rawQuery('PRAGMA table_info(tasks)');
        if (!columns.any((c) => c['name'] == 'alarmSound')) {
          await db.execute('ALTER TABLE tasks ADD COLUMN alarmSound TEXT DEFAULT NULL');
        }
        if (!columns.any((c) => c['name'] == 'alarmSoundType')) {
          await db.execute('ALTER TABLE tasks ADD COLUMN alarmSoundType TEXT DEFAULT NULL');
        }
        if (!columns.any((c) => c['name'] == 'alarmSoundUri')) {
          await db.execute('ALTER TABLE tasks ADD COLUMN alarmSoundUri TEXT DEFAULT NULL');
        }
        if (!columns.any((c) => c['name'] == 'snoozeDuration')) {
          await db.execute('ALTER TABLE tasks ADD COLUMN snoozeDuration INTEGER DEFAULT 5');
        }
        if (!columns.any((c) => c['name'] == 'vibrationEnabled')) {
          await db.execute('ALTER TABLE tasks ADD COLUMN vibrationEnabled INTEGER DEFAULT 1');
        }
      }
    }
    // Indexes must run AFTER every table exists: on upgrade paths the
    // checklist_items / focus_sessions tables are only created in v5.
    if (oldVersion > 0 && oldVersion < schemaVersion) {
      await _createIndexes(db);
    }
  }

  /// v7 adds the immutable per-day completion checklist history.
  ///
  /// Existing habit_log_items rows are copied in as completed snapshots so no
  /// history is lost during the upgrade. The migration is idempotent: rows are
  /// re-inserted with their original ids (INSERT OR REPLACE).
  Future<void> _createV7Tables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS habit_completion_items (
        id TEXT PRIMARY KEY,
        habitId TEXT NOT NULL,
        completionDate TEXT NOT NULL,
        text TEXT NOT NULL,
        completed INTEGER DEFAULT 1,
        position INTEGER DEFAULT 0
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_habit_completion_items_habit_date '
        'ON habit_completion_items(habitId, completionDate)');

    // Migrate legacy daily log entries ('{habitId}-yyyy-MM-dd' logIds) into
    // the snapshot table. The date is always the trailing 10 characters.
    await db.execute('''
      INSERT OR REPLACE INTO habit_completion_items
        (id, habitId, completionDate, text, completed, position)
      SELECT id,
        substr(logId, 1, length(logId) - 11),
        substr(logId, length(logId) - 9),
        text,
        1,
        position
      FROM habit_log_items
      WHERE length(logId) >= 12
    ''');
  }

  /// v8 adds per-birthday reminder time (reminderHour, reminderMinute) so
  /// each birthday can independently control when its notification fires.
  Future<void> _createV8Tables(Database db) async {
    // Check if birthdays table exists before trying to alter it (defensive).
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'birthdays'",
    );
    if (tables.isEmpty) return;

    // Add columns only if they don't exist (idempotent for upgrade paths).
    final columns = await db.rawQuery('PRAGMA table_info(birthdays)');
    if (!columns.any((c) => c['name'] == 'reminderHour')) {
      await db.execute('ALTER TABLE birthdays ADD COLUMN reminderHour INTEGER DEFAULT 9');
    }
    if (!columns.any((c) => c['name'] == 'reminderMinute')) {
      await db.execute('ALTER TABLE birthdays ADD COLUMN reminderMinute INTEGER DEFAULT 0');
    }
  }

  /// v9 adds the `mode` column to `focus_sessions` so strict mode is persisted.
  Future<void> _createV9Tables(Database db) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'focus_sessions'",
    );
    if (tables.isEmpty) return;

    final columns = await db.rawQuery('PRAGMA table_info(focus_sessions)');
    if (!columns.any((c) => c['name'] == 'mode')) {
      await db.execute("ALTER TABLE focus_sessions ADD COLUMN mode TEXT DEFAULT 'normal'");
    }
  }

  Future<void> _createV6Tables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS habit_log_items (
        id TEXT PRIMARY KEY,
        logId TEXT NOT NULL,
        text TEXT NOT NULL,
        position INTEGER DEFAULT 0
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_habit_log_items_logId ON habit_log_items(logId)');
  }

  Future<void> _createIndexes(Database db) async {
    final indexTargets = <String, List<String>>{
      'tasks': [
        'CREATE INDEX IF NOT EXISTS idx_tasks_filter_sort ON tasks(isDeleted, isArchived, dueDate)',
        'CREATE INDEX IF NOT EXISTS idx_tasks_category ON tasks(category)',
        'CREATE INDEX IF NOT EXISTS idx_tasks_conflict ON tasks(isDeleted, isArchived, startTime, endTime)',
        'CREATE INDEX IF NOT EXISTS idx_tasks_completed ON tasks(isCompleted)',
        'CREATE INDEX IF NOT EXISTS idx_tasks_favorite ON tasks(isFavorite)',
      ],
      'habit_logs': [
        'CREATE INDEX IF NOT EXISTS idx_habit_logs_habitId ON habit_logs(habitId)',
        'CREATE INDEX IF NOT EXISTS idx_habit_logs_date ON habit_logs(date)',
      ],
      'checklist_items': [
        'CREATE INDEX IF NOT EXISTS idx_checklist_items_checklistId ON checklist_items(checklistId)',
      ],
      'focus_sessions': [
        'CREATE INDEX IF NOT EXISTS idx_focus_sessions_start ON focus_sessions(startTime)',
        'CREATE INDEX IF NOT EXISTS idx_focus_sessions_completed ON focus_sessions(completed)',
      ],
    };

    // Skip indexes whose table does not exist yet (partial upgrade paths).
    final existingTables = (await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'table'"))
        .map((row) => row['name'] as String)
        .toSet();

    for (final entry in indexTargets.entries) {
      if (!existingTables.contains(entry.key)) continue;
      for (final sql in entry.value) {
        await db.execute(sql);
      }
    }
  }

  Future<void> _createV5Tables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS checklists (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        createdAt INTEGER,
        updatedAt INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS checklist_items (
        id TEXT PRIMARY KEY,
        checklistId TEXT NOT NULL,
        text TEXT NOT NULL,
        completed INTEGER DEFAULT 0,
        position INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS birthdays (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        birthDate INTEGER NOT NULL,
        phone TEXT,
        notes TEXT,
        reminderDaysBefore TEXT DEFAULT '0',
        createdAt INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS focus_sessions (
        id TEXT PRIMARY KEY,
        taskId TEXT,
        label TEXT,
        startTime INTEGER,
        endTime INTEGER,
        plannedMinutes INTEGER,
        completed INTEGER DEFAULT 0,
        mode TEXT DEFAULT 'normal'
      )
    ''');
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE tasks (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        description TEXT,
        category TEXT,
        priority TEXT,
        dueDate INTEGER,
        startTime INTEGER,
        endTime INTEGER,
        isCompleted INTEGER DEFAULT 0,
        isArchived INTEGER DEFAULT 0,
        isDeleted INTEGER DEFAULT 0,
        isFavorite INTEGER DEFAULT 0,
        isPinned INTEGER DEFAULT 0,
        notes TEXT,
        repeatRule TEXT,
        color TEXT,
        checklist TEXT,
        reminderMinutes TEXT DEFAULT '[]',
        estimatedDuration TEXT,
        alarmEnabled INTEGER DEFAULT 0,
        alarmTime INTEGER DEFAULT NULL,
        alarmSound TEXT DEFAULT NULL,
        alarmSoundType TEXT DEFAULT NULL,
        alarmSoundUri TEXT DEFAULT NULL,
        snoozeDuration INTEGER DEFAULT 5,
        vibrationEnabled INTEGER DEFAULT 1,
        completedAt INTEGER,
        repeatMonthday INTEGER,
        createdAt INTEGER,
        updatedAt INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE categories (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        colorHex TEXT,
        icon TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE habits (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT,
        currentStreak INTEGER DEFAULT 0,
        bestStreak INTEGER DEFAULT 0,
        lastCompletedDate INTEGER,
        createdAt INTEGER,
        updatedAt INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE habit_logs (
        id TEXT PRIMARY KEY,
        habitId TEXT,
        date TEXT,
        isCompleted INTEGER DEFAULT 0
      )
    ''');

    await _createV5Tables(db);
    await _createV6Tables(db);
    await _createV7Tables(db);
    await _createV8Tables(db);

    final defaultCategories = [
      {'id': '1', 'name': 'Personal', 'colorHex': '#4CAF50', 'icon': 'person'},
      {'id': '2', 'name': 'College', 'colorHex': '#2196F3', 'icon': 'school'},
      {'id': '3', 'name': 'Study', 'colorHex': '#9C27B0', 'icon': 'menu_book'},
      {'id': '4', 'name': 'Gym', 'colorHex': '#FF9800', 'icon': 'fitness_center'},
      {'id': '5', 'name': 'Shopping', 'colorHex': '#E91E63', 'icon': 'shopping_bag'},
      {'id': '6', 'name': 'Work', 'colorHex': '#607D8B', 'icon': 'work'},
      {'id': '7', 'name': 'Health', 'colorHex': '#F44336', 'icon': 'medical_services'},
      {'id': '8', 'name': 'Finance', 'colorHex': '#FFC107', 'icon': 'account_balance_wallet'},
      {
        'id': '9',
        'name': 'Family',
        'colorHex': '#795548',
        'icon': 'family_restroom'
      },
      {'id': '10', 'name': 'Travel', 'colorHex': '#00BCD4', 'icon': 'flight_takeoff'},
    ];

    final batch = db.batch();
    for (final item in defaultCategories) {
      batch.insert('categories', item,
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);

    await _createIndexes(db);
  }

  Future<Task> createTask(Task task) async {
    final db = await database;
    await db.insert('tasks', task.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    return task;
  }

  Future<Task?> getTask(String id) async {
    final db = await database;
    final maps = await db.query('tasks', where: 'id = ?', whereArgs: [id]);
    if (maps.isNotEmpty) {
      return Task.fromMap(maps.first);
    }
    return null;
  }

  Future<List<Task>> getAllTasks({bool includeArchived = false}) async {
    final db = await database;
    final result = await db.query(
      'tasks',
      where: includeArchived
          ? 'isDeleted = 0'
          : 'isDeleted = 0 AND isArchived = 0',
      orderBy: 'dueDate ASC',
    );
    return result.map((json) => Task.fromMap(json)).toList();
  }

  Future<List<Task>> getArchivedTasks() async {
    final db = await database;
    final result = await db.query(
      'tasks',
      where: 'isDeleted = 0 AND isArchived = 1',
      orderBy: 'dueDate ASC',
    );
    return result.map((json) => Task.fromMap(json)).toList();
  }

  Future<List<Task>> getTasksByDate(DateTime date) async {
    final db = await database;
    final startOfDay = DateTime(date.year, date.month, date.day);
    final endOfDay = DateTime(date.year, date.month, date.day, 23, 59, 59);

    final result = await db.query(
      'tasks',
      where:
          'dueDate >= ? AND dueDate <= ? AND isDeleted = 0 AND isArchived = 0',
      whereArgs: [
        startOfDay.millisecondsSinceEpoch,
        endOfDay.millisecondsSinceEpoch
      ],
      orderBy: 'dueDate ASC',
    );
    return result.map((json) => Task.fromMap(json)).toList();
  }

  Future<List<Task>> searchTasks(String query) async {
    final db = await database;
    final escaped = query
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    final value = '%$escaped%';
    const likeClause =
        "(title LIKE ? ESCAPE '\\' OR description LIKE ? ESCAPE '\\' "
        "OR notes LIKE ? ESCAPE '\\' OR category LIKE ? ESCAPE '\\')";
    final result = await db.query(
      'tasks',
      where: '$likeClause AND isDeleted = 0 AND isArchived = 0',
      whereArgs: [value, value, value, value],
      orderBy: 'dueDate ASC',
    );
    return result.map((json) => Task.fromMap(json)).toList();
  }

  Future<List<Task>> getConflictingTasks({
    required DateTime start,
    required DateTime end,
    String? excludeTaskId,
  }) async {
    final db = await database;
    final startMs = start.millisecondsSinceEpoch;
    final endMs = end.millisecondsSinceEpoch;

    final result = await db.query(
      'tasks',
      where:
          'isDeleted = 0 AND isArchived = 0 AND startTime IS NOT NULL AND endTime IS NOT NULL '
          'AND startTime < ? AND endTime > ?'
          '${excludeTaskId != null ? ' AND id != ?' : ''}',
      whereArgs: excludeTaskId != null
          ? [endMs, startMs, excludeTaskId]
          : [endMs, startMs],
      orderBy: 'startTime ASC',
    );
    return result.map((json) => Task.fromMap(json)).toList();
  }

  Future<int> updateTask(Task task) async {
    final db = await database;
    return db.update(
      'tasks',
      task.toMap(),
      where: 'id = ?',
      whereArgs: [task.id],
    );
  }

  Future<int> archiveTask(String id) async {
    final db = await database;
    return db.update(
      'tasks',
      {'isArchived': 1, 'updatedAt': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> restoreTask(String id) async {
    final db = await database;
    return db.update(
      'tasks',
      {
        'isArchived': 0,
        'isDeleted': 0,
        'updatedAt': DateTime.now().millisecondsSinceEpoch
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteTask(String id) async {
    final db = await database;
    return db.update(
      'tasks',
      {
        'isDeleted': 1,
        'isArchived': 1,
        'updatedAt': DateTime.now().millisecondsSinceEpoch
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteTaskPermanently(String id) async {
    final db = await database;
    return db.delete('tasks', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearTasks() async {
    final db = await database;
    await db.delete('tasks');
  }

  Future<TaskCategory> createCategory(TaskCategory category) async {
    final db = await database;
    await db.insert('categories', category.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    return category;
  }

  Future<List<TaskCategory>> getAllCategories() async {
    final db = await database;
    final result = await db.query('categories', orderBy: 'name ASC');
    return result.map((json) => TaskCategory.fromMap(json)).toList();
  }

  Future<int> updateCategory(TaskCategory category) async {
    final db = await database;
    return db.update(
      'categories',
      category.toMap(),
      where: 'id = ?',
      whereArgs: [category.id],
    );
  }

  Future<int> deleteCategory(String id) async {
    final db = await database;
    return db.delete('categories', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> reassignTasksCategory(String fromName, String toName) async {
    final db = await database;
    return db.update(
      'tasks',
      {
        'category': toName,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'category = ?',
      whereArgs: [fromName],
    );
  }

  Future<Habit> createHabit(Habit habit) async {
    final db = await database;
    await db.insert('habits', habit.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    return habit;
  }

  Future<Habit?> getHabit(String id) async {
    final db = await database;
    final maps = await db.query('habits', where: 'id = ?', whereArgs: [id]);
    if (maps.isNotEmpty) {
      return Habit.fromMap(maps.first);
    }
    return null;
  }

  Future<List<Habit>> getAllHabits() async {
    final db = await database;
    final result = await db.query('habits', orderBy: 'createdAt DESC');
    return result.map((json) => Habit.fromMap(json)).toList();
  }

  Future<void> logHabitCompletion(String habitId, String dateKey) async {
    final db = await database;
    await db.insert(
      'habit_logs',
      {
        'id': '$habitId-$dateKey',
        'habitId': habitId,
        'date': dateKey,
        'isCompleted': 1
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> updateHabit(Habit habit) async {
    final db = await database;
    return db.update(
      'habits',
      habit.toMap(),
      where: 'id = ?',
      whereArgs: [habit.id],
    );
  }

  Future<int> deleteHabit(String id) async {
    final db = await database;
    return db.transaction((txn) async {
      await txn.execute(
        'DELETE FROM habit_log_items WHERE logId LIKE ?',
        ['$id-%'],
      );
      await txn.delete('habit_completion_items',
          where: 'habitId = ?', whereArgs: [id]);
      await txn.delete('habit_logs', where: 'habitId = ?', whereArgs: [id]);
      return txn.delete('habits', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<List<Map<String, dynamic>>> getHabitLogs(String habitId) async {
    final db = await database;
    return db.query('habit_logs',
        where: 'habitId = ?', whereArgs: [habitId], orderBy: 'date DESC');
  }

  /// Deletes the habit log entry for [habitId] on [dateKey] ('yyyy-MM-dd').
  Future<void> removeHabitCompletion(String habitId, String dateKey) async {
    final db = await database;
    await db.delete(
      'habit_logs',
      where: 'habitId = ? AND date = ?',
      whereArgs: [habitId, dateKey],
    );
    // Also remove the completion checklist snapshot for that day.
    await db.delete(
      'habit_completion_items',
      where: 'habitId = ? AND completionDate = ?',
      whereArgs: [habitId, dateKey],
    );
  }

  /// Returns all unique completion dates for [habitId] as DateTime objects,
  /// sorted ascending. Used for streak recalculation.
  Future<List<DateTime>> getHabitCompletionDates(String habitId) async {
    final db = await database;
    final logs = await db.query(
      'habit_logs',
      columns: ['date'],
      where: 'habitId = ?',
      whereArgs: [habitId],
    );
    final dates = <DateTime>[];
    for (final log in logs) {
      final raw = log['date'];
      if (raw is String && raw.length >= 10) {
        final dateStr = raw.substring(raw.length - 10);
        final date = DateTime.tryParse(dateStr);
        if (date != null) {
          dates.add(DateTime(date.year, date.month, date.day));
        }
      }
    }
    dates.sort();
    return dates;
  }

  /// Replaces the completion checklist snapshot for [habitId] on [dateKey]
  /// ('yyyy-MM-dd'). Called once, at the moment the habit is completed.
  Future<void> saveCompletionChecklist(
    String habitId,
    String dateKey,
    List<HabitCompletionItem> items,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'habit_completion_items',
        where: 'habitId = ? AND completionDate = ?',
        whereArgs: [habitId, dateKey],
      );
      for (final item in items) {
        await txn.insert('habit_completion_items', item.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  /// Returns the checklist snapshotted when the habit was completed on
  /// [dateKey]. Empty if no checklist was recorded that day.
  Future<List<HabitCompletionItem>> getCompletionChecklist(
    String habitId,
    String dateKey,
  ) async {
    final db = await database;
    final result = await db.query(
      'habit_completion_items',
      where: 'habitId = ? AND completionDate = ?',
      whereArgs: [habitId, dateKey],
      orderBy: 'position ASC',
    );
    return result.map(HabitCompletionItem.fromMap).toList();
  }

  Future<void> addCompletionItem(HabitCompletionItem item) async {
    final db = await database;
    await db.insert('habit_completion_items', item.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateCompletionItem(HabitCompletionItem item) async {
    final db = await database;
    await db.update(
      'habit_completion_items',
      item.toMap(),
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  Future<void> deleteCompletionItem(String id) async {
    final db = await database;
    await db.delete('habit_completion_items', where: 'id = ?', whereArgs: [id]);
  }

  Future<HabitLogItem> createHabitLogItem(HabitLogItem item) async {
    final db = await database;
    await db.insert('habit_log_items', item.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    return item;
  }

  Future<List<HabitLogItem>> getHabitLogItems(String logId) async {
    final db = await database;
    final result = await db.query(
      'habit_log_items',
      where: 'logId = ?',
      whereArgs: [logId],
      orderBy: 'position ASC',
    );
    return result.map(HabitLogItem.fromMap).toList();
  }

  Future<int> updateHabitLogItem(HabitLogItem item) async {
    final db = await database;
    return db.update(
      'habit_log_items',
      item.toMap(),
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  Future<int> deleteHabitLogItem(String id) async {
    final db = await database;
    return db.delete('habit_log_items', where: 'id = ?', whereArgs: [id]);
  }

  Future<Checklist> createChecklist(Checklist checklist) async {
    final db = await database;
    await db.insert('checklists', checklist.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    return checklist;
  }

  Future<List<Checklist>> getAllChecklists() async {
    final db = await database;
    final result = await db.query('checklists', orderBy: 'updatedAt DESC');
    return result.map((json) => Checklist.fromMap(json)).toList();
  }

  Future<int> updateChecklist(Checklist checklist) async {
    final db = await database;
    return db.update(
      'checklists',
      checklist.toMap(),
      where: 'id = ?',
      whereArgs: [checklist.id],
    );
  }

  Future<int> deleteChecklist(String id) async {
    final db = await database;
    await db.delete('checklist_items',
        where: 'checklistId = ?', whereArgs: [id]);
    return db.delete('checklists', where: 'id = ?', whereArgs: [id]);
  }

  Future<ChecklistItem> createChecklistItem(ChecklistItem item) async {
    final db = await database;
    await db.insert('checklist_items', item.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    await _touchChecklist(item.checklistId);
    return item;
  }

  Future<List<ChecklistItem>> getChecklistItems(String checklistId) async {
    final db = await database;
    final result = await db.query(
      'checklist_items',
      where: 'checklistId = ?',
      whereArgs: [checklistId],
      orderBy: 'position ASC',
    );
    return result.map((json) => ChecklistItem.fromMap(json)).toList();
  }

  Future<Map<String, List<ChecklistItem>>> getAllChecklistItems() async {
    final db = await database;
    final result =
        await db.query('checklist_items', orderBy: 'position ASC');
    final map = <String, List<ChecklistItem>>{};
    for (final row in result) {
      final item = ChecklistItem.fromMap(row);
      map.putIfAbsent(item.checklistId, () => []).add(item);
    }
    return map;
  }

  Future<int> updateChecklistItem(ChecklistItem item) async {
    final db = await database;
    await _touchChecklist(item.checklistId);
    return db.update(
      'checklist_items',
      item.toMap(),
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  Future<int> deleteChecklistItem(String id, String checklistId) async {
    final db = await database;
    await _touchChecklist(checklistId);
    return db.delete('checklist_items', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> _touchChecklist(String checklistId) async {
    final db = await database;
    await db.update(
      'checklists',
      {'updatedAt': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [checklistId],
    );
  }

  Future<Birthday> createBirthday(Birthday birthday) async {
    final db = await database;
    await db.insert('birthdays', birthday.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    return birthday;
  }

  Future<List<Birthday>> getAllBirthdays() async {
    final db = await database;
    final result = await db.query('birthdays', orderBy: 'name ASC');
    return result.map((json) => Birthday.fromMap(json)).toList();
  }

  Future<int> updateBirthday(Birthday birthday) async {
    final db = await database;
    return db.update(
      'birthdays',
      birthday.toMap(),
      where: 'id = ?',
      whereArgs: [birthday.id],
    );
  }

  Future<int> deleteBirthday(String id) async {
    final db = await database;
    return db.delete('birthdays', where: 'id = ?', whereArgs: [id]);
  }

  Future<FocusSession> createFocusSession(FocusSession session) async {
    final db = await database;
    await db.insert('focus_sessions', session.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    return session;
  }

  Future<List<FocusSession>> getFocusSessions({int limit = 100}) async {
    final db = await database;
    final result = await db.query(
      'focus_sessions',
      orderBy: 'startTime DESC',
      limit: limit,
    );
    return result.map((json) => FocusSession.fromMap(json)).toList();
  }

  Future<int> getTotalFocusMinutes({
    required DateTime rangeStart,
    DateTime? rangeEnd,
  }) async {
    final db = await database;
    final endMs =
        (rangeEnd ?? DateTime.now()).millisecondsSinceEpoch;
    // Overlap (not containment) so sessions crossing the range boundary are
    // counted for the minutes that actually fall inside the range.
    final result = await db.rawQuery(
      'SELECT SUM(MIN(endTime, ?) - MAX(startTime, ?)) as total '
      'FROM focus_sessions '
      'WHERE completed = 1 AND startTime < ? AND endTime > ?',
      [endMs, rangeStart.millisecondsSinceEpoch, endMs,
       rangeStart.millisecondsSinceEpoch],
    );
    final total = result.first['total'];
    if (total is int) return total ~/ 60000;
    return 0;
  }

  Future<void> initDatabase() async {
    await database;
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }

  /// Reads raw rows from a whitelisted [table]. Used to snapshot rows just
  /// before a destructive delete so an Undo action can faithfully restore
  /// them later (original IDs preserved via INSERT OR REPLACE).
  Future<List<Map<String, dynamic>>> queryRows(
    String table, {
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
  }) async {
    if (!_knownTables.contains(table)) return const [];
    final db = await database;
    return db.query(
      table,
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
    );
  }

  /// Re-inserts [rows] into a whitelisted [table] inside one transaction using
  /// INSERT OR REPLACE so the original row IDs survive an Undo.
  Future<void> restoreRows(
      String table, List<Map<String, dynamic>> rows) async {
    if (!_knownTables.contains(table) || rows.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final row in rows) {
        batch.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  /// Sets the category name for a single task. Used to revert the automatic
  /// task reassignment that ran while a category was deleted.
  Future<int> setTaskCategory(String taskId, String category) async {
    final db = await database;
    return db.update(
      'tasks',
      {
        'category': category,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  /// Restores a deleted checklist item (re-insert with its original ID) and
  /// bumps the owning checklist's updatedAt so it resurfaces at the top.
  Future<void> restoreChecklistItem(ChecklistItem item) async {
    final db = await database;
    await _touchChecklist(item.checklistId);
    await db.insert('checklist_items', item.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static const List<String> _knownTables = [
    'tasks',
    'categories',
    'habits',
    'habit_logs',
    'habit_log_items',
    'habit_completion_items',
    'checklists',
    'checklist_items',
    'birthdays',
    'focus_sessions'
  ];

  Future<Map<String, List<Map<String, dynamic>>>> exportAllTables() async {
    final db = await database;
    return db.transaction((txn) async {
      final tables = <String, List<Map<String, dynamic>>>{};
      for (final table in _knownTables) {
        tables[table] = await txn.query(table);
      }
      return tables;
    });
  }

  /// Replaces the contents of ALL known tables with [data].
  ///
  /// Only whitelisted table names are accepted (a corrupt/hand-edited backup
  /// must not be able to run arbitrary SQL through table names), and every
  /// table is cleared first so a partial backup cannot silently merge with
  /// existing data.
  Future<void> importAllTables(
      Map<String, List<Map<String, dynamic>>> data) async {
    final db = await database;
    await db.transaction((txn) async {
      // Wipe every known table regardless of what the backup contains so
      // restore is a true replace, not a merge.
      for (final table in _knownTables) {
        await txn.delete(table);
      }
      for (final entry in data.entries) {
        if (!_knownTables.contains(entry.key)) continue;
        // Use batch inserts for performance.
        final batch = txn.batch();
        for (final row in entry.value) {
          batch.insert(entry.key, row,
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      }
    });
  }

  Future<Map<String, int>> getDataCounts() async {
    final db = await database;
    return db.transaction((txn) async {
      final counts = <String, int>{};
      for (final table in _knownTables) {
        final result = await txn.rawQuery('SELECT COUNT(*) as c FROM $table');
        counts[table] = result.first['c'] as int? ?? 0;
      }
      return counts;
    });
  }
}
