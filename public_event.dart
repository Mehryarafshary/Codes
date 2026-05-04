import 'package:boshkeh/domain/models/events/event.dart';
import 'package:boshkeh/domain/models/events/event_type.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Represents a public event (protest, gathering, etc.) fetched from GitHub.
/// 
/// Simplified JSON format for easy editing:
/// {
///   "id": "event_001",
///   "title": "Event Name",
///   "titleFa": "نام رویداد",  // Optional
///   "date": "2026-03-21",      // YYYY-MM-DD
///   "time": "14:00",           // HH:MM (optional, defaults to 12:00)
///   "location": "Tehran",      // Optional
///   "description": "...",      // Optional
///   "country": "Iran",         // Optional - display name
///   "countryCode": "IR"        // Optional - ISO code or "ONLINE"
/// }
class PublicEvent {
  final String id;
  final String title;
  final String? titleFa;
  final DateTime startDateTime;
  final DateTime endDateTime;
  final String? location;
  final String? locationFa;
  final String? description;
  final String? descriptionFa;
  final String? posterUrl;
  final String? organizerId;
  final String? organizerName;
  final String? category;
  final String? country;      // Display name (e.g., "Iran", "Online")
  final String? countryCode;  // ISO code (e.g., "IR", "ONLINE")
  final String? timezoneId;   // IANA Timezone ID (e.g., "Asia/Tehran")
  final String? relatedHolidayId; // Cached ID of the AI-matched related holiday
  final int viewCount;        // Number of unique users who viewed the event
  final int addCount;         // Number of unique users who added the event to calendar

  const PublicEvent({
    required this.id,
    required this.title,
    required this.startDateTime, required this.endDateTime, this.titleFa,
    this.location,
    this.locationFa,
    this.description,
    this.descriptionFa,
    this.posterUrl,
    this.organizerId,
    this.organizerName,
    this.category,
    this.country,
    this.countryCode,
    this.timezoneId,
    this.relatedHolidayId,
    this.viewCount = 0,
    this.addCount = 0,
  });

  /// Get title in specified language
  String getTitle(String languageCode) {
    if (languageCode == 'fa' && titleFa != null && titleFa!.isNotEmpty) {
      return titleFa!;
    }
    return title;
  }

  /// Get location in specified language
  String? getLocation(String languageCode) {
    if (languageCode == 'fa' && locationFa != null && locationFa!.isNotEmpty) {
      return locationFa!;
    }
    return location;
  }

  /// Get description in specified language
  String? getDescription(String languageCode) {
    if (languageCode == 'fa' && descriptionFa != null && descriptionFa!.isNotEmpty) {
      return descriptionFa!;
    }
    return description;
  }

  /// Parse from simplified JSON
  factory PublicEvent.fromJson(Map<String, dynamic> json) {
    // Parse date (required)
    final dateStr = json['date'] as String? ?? '';
    final timeStr = json['time'] as String? ?? '12:00';
    
    DateTime startDateTime;
    try {
      // Parse date
      final dateParts = dateStr.split('-');
      final year = int.parse(dateParts[0]);
      final month = int.parse(dateParts[1]);
      final day = int.parse(dateParts[2]);
      
      // Parse time
      final timeParts = timeStr.split(':');
      final hour = int.parse(timeParts[0]);
      final minute = timeParts.length > 1 ? int.parse(timeParts[1]) : 0;
      
      startDateTime = DateTime.utc(year, month, day, hour, minute);
    } catch (e) {
      // Default to now if parsing fails
      startDateTime = DateTime.now();
    }
    
    // End time defaults to 2 hours after start
    final endDateTime = startDateTime.add(const Duration(hours: 2));

    return PublicEvent(
      id: json['id'] as String? ?? 'unknown',
      title: json['title'] as String? ?? 'Untitled Event',
      titleFa: json['titleFa'] as String?,
      startDateTime: startDateTime,
      endDateTime: endDateTime,
      location: json['location'] as String?,
      locationFa: json['locationFa'] as String?,
      description: json['description'] as String?,
      descriptionFa: json['descriptionFa'] as String?,
      posterUrl: json['posterUrl'] as String? ?? json['poster_url'] as String? ?? json['image'] as String?,
      organizerId: json['organizerId'] as String?,
      organizerName: json['organizerName'] as String?,
      category: json['category'] as String?,
      country: json['country'] as String?,
      countryCode: json['countryCode'] as String?,
      timezoneId: json['timezoneId'] as String?,
      relatedHolidayId: json['relatedHolidayId'] as String?,
      viewCount: json['viewCount'] as int? ?? 0,
      addCount: json['addCount'] as int? ?? 0,
    );
  }

  /// Serialize to JSON for persistent caching
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'titleFa': titleFa,
      'date': '${startDateTime.year.toString().padLeft(4, '0')}-${startDateTime.month.toString().padLeft(2, '0')}-${startDateTime.day.toString().padLeft(2, '0')}',
      'time': '${startDateTime.hour.toString().padLeft(2, '0')}:${startDateTime.minute.toString().padLeft(2, '0')}',
      'location': location,
      'locationFa': locationFa,
      'description': description,
      'descriptionFa': descriptionFa,
      'posterUrl': posterUrl,
      'organizerId': organizerId,
      'organizerName': organizerName,
      'category': category,
      'country': country,
      'countryCode': countryCode,
      'timezoneId': timezoneId,
      'relatedHolidayId': relatedHolidayId,
      'viewCount': viewCount,
      'addCount': addCount,
    };
  }

  /// Convert to CalendarEvent for calendar display
  CalendarEvent toCalendarEvent({required String languageCode}) {
    return CalendarEvent(
      id: 'public_$id',
      title: getTitle(languageCode),
      localizedTitles: {
        'en': title,
        if (titleFa != null) 'fa': titleFa!,
      },
      startDateTime: startDateTime.toLocal(),
      endDateTime: endDateTime.toLocal(),
      isAllDay: false,
      eventType: EventType.culturalHoliday,
      color: EventColor.publicEventGreen,
      location: getLocation(languageCode),
      fullDescription: getDescription(languageCode),
      category: 'public_event',
    );
  }

  /// Check if event is in the past (using End Time)
  /// An event is past only if it has fully finished.
  bool get isPast => endDateTime.isBefore(DateTime.now().toUtc());

  /// Check if the event is online (based on countryCode or location URL)
  bool get isOnline {
    // Check countryCode first (new way)
    if (countryCode?.toUpperCase() == 'ONLINE') return true;
    // Fallback to URL detection for legacy data
    final loc = location?.toLowerCase() ?? '';
    return loc.startsWith('http') || loc.startsWith('www.') || loc.contains('zoom.us') || loc.contains('meet.google') || loc.contains('youtu.be') || loc.contains('youtube.com');
  }

  /// Get the actionable URL for online events
  String? get onlineUrl {
    if (!isOnline) return null;
    var url = location!;
    if (url.startsWith('www.')) {
      url = 'https://$url';
    }
    return url;
  }

  /// Create from Firestore Document
  factory PublicEvent.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    
    // Firestore Timestamps
    final start = (data['startDateTime'] as Timestamp?)?.toDate() ?? DateTime.now();
    final end = (data['endDateTime'] as Timestamp?)?.toDate() ?? start.add(const Duration(hours: 2));

    return PublicEvent(
      id: doc.id,
      title: data['title'] ?? 'Untitled',
      startDateTime: start,
      endDateTime: end,
      location: data['location'],
      description: data['description'],
      posterUrl: data['posterUrl'],
      organizerId: data['organizerId'],
      organizerName: data['organizerName'],
      category: data['category'],
      country: data['country'],
      countryCode: data['countryCode'],
      timezoneId: data['timezoneId'],
      relatedHolidayId: data['relatedHolidayId'],
      viewCount: data['viewCount'] as int? ?? 0,
      addCount: data['addCount'] as int? ?? 0,
    );
  }
}

// For backwards compatibility - these are no longer used in simplified format
enum PublicEventStatus { active, cancelled, past }
enum PublicEventSource { official, verified, community }

class PublicEventLocation {
  final String name;
  const PublicEventLocation({required this.name});
}
