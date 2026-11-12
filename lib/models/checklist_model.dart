import 'package:uuid/uuid.dart';

class Checklist {
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Display order among the parent lists (lower sorts first). Persisted in
  /// SQLite so a drag-and-drop reorder survives an app restart. Legacy rows
  /// without a stored value read as 0.
  final int position;

  Checklist({
    String? id,
    required this.title,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.position = 0,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Checklist copyWith({
    String? id,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? position,
  }) {
    return Checklist(
      id: id ?? this.id,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      position: position ?? this.position,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        'position': position,
      };

  factory Checklist.fromMap(Map<String, dynamic> map) {
    return Checklist(
      id: map['id'],
      title: map['title'] ?? '',
      createdAt: map['createdAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['createdAt'])
          : DateTime.now(),
      updatedAt: map['updatedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['updatedAt'])
          : DateTime.now(),
      position: (map['position'] as num?)?.toInt() ?? 0,
    );
  }
}

class ChecklistItem {
  final String id;
  final String checklistId;
  final String text;
  final bool completed;
  final int position;

  ChecklistItem({
    String? id,
    required this.checklistId,
    required this.text,
    this.completed = false,
    this.position = 0,
  }) : id = id ?? const Uuid().v4();

  ChecklistItem copyWith({
    String? id,
    String? checklistId,
    String? text,
    bool? completed,
    int? position,
  }) {
    return ChecklistItem(
      id: id ?? this.id,
      checklistId: checklistId ?? this.checklistId,
      text: text ?? this.text,
      completed: completed ?? this.completed,
      position: position ?? this.position,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'checklistId': checklistId,
        'text': text,
        'completed': completed ? 1 : 0,
        'position': position,
      };

  factory ChecklistItem.fromMap(Map<String, dynamic> map) {
    return ChecklistItem(
      id: map['id'],
      checklistId: map['checklistId'] ?? '',
      text: map['text'] ?? '',
      completed: map['completed'] == 1 || map['completed'] == true,
      position: map['position'] ?? 0,
    );
  }
}
