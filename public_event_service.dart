import 'package:boshkeh/core/utils/app_logger.dart';
import 'dart:io';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:boshkeh/domain/models/events/public_event.dart';
import 'package:boshkeh/domain/models/events/event.dart';
import 'package:boshkeh/core/utils/language_manager.dart';
import 'package:boshkeh/core/config/github_config.dart';
import 'package:dio/dio.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

// Top-level function for isolate parsing
List<PublicEvent> _parsePublicEvents(String jsonString) {
  final decoded = jsonDecode(jsonString) as List<dynamic>;
  return decoded.map((e) => PublicEvent.fromJson(e as Map<String, dynamic>)).toList();
}

/// Service that coordinates fetching of public events.
/// Uses Firebase Firestore as the single source of truth.
class PublicEventService {
  static const Duration _cacheValidity = Duration(hours: 1);
  static const String _persistentCacheKey = 'public_events_cache';
  static const String _persistentCacheTimeKey = 'public_events_cache_time';

  List<PublicEvent>? _cachedEvents;
  DateTime? _lastFetchTime;

  PublicEventService();

  /// Get all public events.
  Future<List<PublicEvent>> getEvents({bool forceRefresh = false}) async {
    AppLogger.d('📢 PublicEventService: getEvents called (forceRefresh=$forceRefresh)');
    
    // 1. Return memory cache if valid AND not empty
    if (!forceRefresh && _cachedEvents != null && _cachedEvents!.isNotEmpty && _lastFetchTime != null) {
      if (DateTime.now().difference(_lastFetchTime!) < _cacheValidity) {
        AppLogger.d('📢 PublicEventService: Returning ${_cachedEvents!.length} memory-cached events');
        return _cachedEvents!;
      }
    }
    
    AppLogger.d('📢 PublicEventService: Memory cache miss, fetching from network...');
    
    try {
      AppLogger.d('📢 PublicEventService: Fetching from Firestore...');
      final now = DateTime.now();
      // Fetch only active/upcoming events to limit data usage
      final firestoreSnapshot = await FirebaseFirestore.instance
          .collection('public_events')
          .where('endDateTime', isGreaterThanOrEqualTo: Timestamp.fromDate(now))
          .get(const GetOptions(source: Source.serverAndCache));

      final allEvents = firestoreSnapshot.docs
          .map((doc) => PublicEvent.fromFirestore(doc))
          .toList();
      
      AppLogger.d('📢 PublicEventService: Received ${allEvents.length} non-expired events from Firestore');

      // Sort by start date
      allEvents.sort((a, b) => a.startDateTime.compareTo(b.startDateTime));
      
      _cachedEvents = allEvents;
      _lastFetchTime = DateTime.now();
      
      // Persist to disk for offline cold-start
      _saveToDisk(allEvents);
      
      AppLogger.d('📢 PublicEventService: ✅ Loaded ${allEvents.length} events');
      return allEvents;
    } catch (e, stackTrace) {
      AppLogger.d('📢 PublicEventService: ❌ Error fetching events: $e');
      AppLogger.d('📢 PublicEventService: StackTrace: $stackTrace');
      
      // 2. Fallback to memory cache
      if (_cachedEvents != null && _cachedEvents!.isNotEmpty) {
        return _cachedEvents!;
      }
      
      // 3. Fallback to persistent disk cache (cold start offline)
      final diskEvents = await _loadFromDisk();
      if (diskEvents.isNotEmpty) {
        _cachedEvents = diskEvents;
        _lastFetchTime = DateTime.now();
        AppLogger.d('📢 PublicEventService: 📴 Returning ${diskEvents.length} events from persistent cache');
        return diskEvents;
      }
      
      return [];
    }
  }

  /// Save events to persistent SharedPreferences cache
  Future<void> _saveToDisk(List<PublicEvent> events) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = events.map((e) => e.toJson()).toList();
      await prefs.setString(_persistentCacheKey, jsonEncode(jsonList));
      await prefs.setString(_persistentCacheTimeKey, DateTime.now().toIso8601String());
      AppLogger.d('📢 PublicEventService: 💾 Saved ${events.length} events to persistent cache');
    } catch (e) {
      AppLogger.d('📢 PublicEventService: Error saving to disk: $e');
    }
  }

  /// Load events from persistent SharedPreferences cache
  Future<List<PublicEvent>> _loadFromDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_persistentCacheKey);
      if (jsonString == null || jsonString.isEmpty) return [];

      return await compute(_parsePublicEvents, jsonString);
    } catch (e) {
      AppLogger.d('📢 PublicEventService: Error loading from disk: $e');
      return [];
    }
  }

  /// Get events as CalendarEvents for display in the calendar.
  Future<List<CalendarEvent>> getCalendarEvents() async {
    final events = await getEvents();
    final languageCode = LanguageManager().currentLanguage;
    return events.map((e) => e.toCalendarEvent(languageCode: languageCode)).toList();
  }

  /// Force refresh from network
  Future<List<PublicEvent>> refresh() => getEvents(forceRefresh: true);

  /// Get events created by a specific organizer
  Future<List<PublicEvent>> getEventsByOrganizer(String organizerId) async {
    AppLogger.d('📢 PublicEventService: getEventsByOrganizer($organizerId)');
    
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('public_events')
          .where('organizerId', isEqualTo: organizerId)
          .get(const GetOptions(source: Source.serverAndCache));

      final events = snapshot.docs
          .map((doc) => PublicEvent.fromFirestore(doc))
          .toList();
      
      // Sort client-side to avoid composite index requirement
      events.sort((a, b) => b.startDateTime.compareTo(a.startDateTime));
      
      AppLogger.d('📢 PublicEventService: Found ${events.length} events for organizer $organizerId');
      return events;
    } catch (e) {
      AppLogger.d('📢 PublicEventService: ❌ Error fetching organizer events: $e');
      return [];
    }
  }

  /// Upload poster image to Firebase Storage
  Future<String?> _uploadPoster(String eventId, File imageFile) async {
    final storageRef = FirebaseStorage.instance.ref().child('posters/$eventId.jpg');
    await storageRef.putFile(imageFile);
    return await storageRef.getDownloadURL();
  }

  /// Create a new public event
  Future<void> createEvent(PublicEvent event, File? posterImage) async {
    try {
      String? downloadUrl;
      if (posterImage != null) {
        downloadUrl = await _uploadPoster(event.id, posterImage);
      }

      final eventData = {
        'id': event.id,
        'title': event.title,
        'startDateTime': Timestamp.fromDate(event.startDateTime),
        'endDateTime': Timestamp.fromDate(event.endDateTime),
        'location': event.location,
        'description': event.description,
        'posterUrl': downloadUrl ?? event.posterUrl,
        'organizerId': event.organizerId,
        'organizerName': event.organizerName,
        'category': event.category,
        'country': event.country,
        'countryCode': event.countryCode,
        'timezoneId': event.timezoneId,
        'createdAt': FieldValue.serverTimestamp(),
      };

      await FirebaseFirestore.instance
          .collection('public_events')
          .doc(event.id)
          .set(eventData);
          
      // Invalidate cache
      _cachedEvents = null;
      _lastFetchTime = null;
      
      // Send broadcast notification to all users (non-blocking)
      _broadcastNewEventNotification(event).catchError((e) {
        AppLogger.d('📢 PublicEventService: Broadcast notification failed: $e');
      });
      
    } catch (e) {
      AppLogger.d('📢 PublicEventService: ❌ Error creating event: $e');
      rethrow;
    }
  }

  Future<void> _broadcastNewEventNotification(PublicEvent event) async {
    try {
      final dio = Dio();
      final baseUrl = GitHubConfig.baseUrl;
      
      final response = await dio.post(
        '$baseUrl/broadcast-public-event',
        data: {
          'title': event.title,
          'titleFa': event.titleFa,
          'eventId': event.id,
          'startDateTime': event.startDateTime.toIso8601String(),
          'location': event.location,
          'countryCode': event.countryCode,
        },
      );
      
      AppLogger.d('📢 PublicEventService: ✅ Broadcast notification sent for ${event.id}');
      AppLogger.d('📢 PublicEventService: Response: ${response.statusCode} - ${response.data}');
    } on DioException catch (e) {
      // Enhanced error logging for debugging
      AppLogger.d('📢 PublicEventService: ⚠️ Broadcast notification error:');
      AppLogger.d('   Status: ${e.response?.statusCode}');
      AppLogger.d('   Message: ${e.message}');
      AppLogger.d('   Response: ${e.response?.data}');
      // Don't rethrow - notification failure shouldn't block event creation
    } catch (e) {
      AppLogger.d('📢 PublicEventService: ⚠️ Broadcast notification error: $e');
      // Don't rethrow - notification failure shouldn't block event creation
    }
  }

  /// Delete an event (Creator only)
  Future<void> deleteEvent(String eventId) async {
    await FirebaseFirestore.instance.collection('public_events').doc(eventId).delete();
    // Invalidate cache
    _cachedEvents = null;
    _lastFetchTime = null;
    AppLogger.d('📢 PublicEventService: Deleted event $eventId and invalidated cache');
  }

  /// Update the related holiday for a public event (KV Cache implementation)
  Future<void> updateRelatedHoliday(String eventId, String holidayId) async {
    try {
      await FirebaseFirestore.instance.collection('public_events').doc(eventId).update({
        'relatedHolidayId': holidayId,
      });
      AppLogger.d('📢 PublicEventService: ✅ Saved related holiday KV cache: $holidayId for event $eventId');
    } catch (e) {
      AppLogger.d('📢 PublicEventService: ❌ Error saving related holiday KV cache: $e');
    }
  }

  /// Track a unique view for a public event.
  /// Each user can only be counted once per event.
  /// Returns true if this was the first view by this user.
  Future<bool> trackView(String eventId, String userId) async {
    try {
      final interactionRef = FirebaseFirestore.instance
          .collection('public_events')
          .doc(eventId)
          .collection('interactions')
          .doc(userId);

      final doc = await interactionRef.get();
      
      if (doc.exists && doc.data()?['viewed'] == true) {
        // User already viewed this event
        AppLogger.d('📢 PublicEventService: User $userId already viewed event $eventId');
        return false;
      }

      // Use a transaction to safely increment the counter
      await FirebaseFirestore.instance.runTransaction((transaction) async {
        final eventRef = FirebaseFirestore.instance.collection('public_events').doc(eventId);
        final eventSnapshot = await transaction.get(eventRef);
        
        if (!eventSnapshot.exists) return;
        
        final currentCount = eventSnapshot.data()?['viewCount'] as int? ?? 0;
        
        // Update the event's view count
        transaction.update(eventRef, {'viewCount': currentCount + 1});
        
        // Mark this user as having viewed
        transaction.set(interactionRef, {
          'viewed': true,
          'viewedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true),);
      });

      AppLogger.d('📢 PublicEventService: ✅ Tracked view for event $eventId by user $userId');
      return true;
    } catch (e) {
      AppLogger.d('📢 PublicEventService: ❌ Error tracking view: $e');
      return false;
    }
  }

  /// Track a unique calendar add for a public event.
  /// Each user can only be counted once per event (first add only).
  /// Returns true if this was the first add by this user.
  Future<bool> trackAdd(String eventId, String userId) async {
    try {
      final interactionRef = FirebaseFirestore.instance
          .collection('public_events')
          .doc(eventId)
          .collection('interactions')
          .doc(userId);

      final doc = await interactionRef.get();
      
      if (doc.exists && doc.data()?['added'] == true) {
        // User already added this event
        AppLogger.d('📢 PublicEventService: User $userId already added event $eventId');
        return false;
      }

      // Use a transaction to safely increment the counter
      await FirebaseFirestore.instance.runTransaction((transaction) async {
        final eventRef = FirebaseFirestore.instance.collection('public_events').doc(eventId);
        final eventSnapshot = await transaction.get(eventRef);
        
        if (!eventSnapshot.exists) return;
        
        final currentCount = eventSnapshot.data()?['addCount'] as int? ?? 0;
        
        // Update the event's add count
        transaction.update(eventRef, {'addCount': currentCount + 1});
        
        // Mark this user as having added
        transaction.set(interactionRef, {
          'added': true,
          'addedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true),);
      });

      AppLogger.d('📢 PublicEventService: ✅ Tracked add for event $eventId by user $userId');
      return true;
    } catch (e) {
      AppLogger.d('📢 PublicEventService: ❌ Error tracking add: $e');
      return false;
    }
  }
}
