/// Repository that orchestrates fetching events from all sources.
/// Handles complexity of loading personal events, local holidays, official holidays, and custom holidays.
library;
import 'dart:async';
import 'package:boshkeh/data/services/subscription_service.dart';
import 'package:boshkeh/data/repositories/events/event_repository.dart';
import 'package:boshkeh/core/utils/app_logger.dart';

import 'package:boshkeh/data/repositories/holidays/holiday_indicator_preference_repository.dart';
import 'package:boshkeh/data/services/country_holiday_service.dart';
import 'package:boshkeh/data/services/national_holiday_service.dart';
import 'package:boshkeh/data/services/explore_holiday_service.dart';
import 'package:boshkeh/data/services/international_holiday_service.dart';
import 'package:boshkeh/data/services/public_event_service.dart';
import 'package:boshkeh/domain/models/events/event.dart' show CalendarEvent;
import 'package:boshkeh/domain/models/events/event_type.dart';
import 'package:boshkeh/domain/models/calendar/year_month.dart' show YearMonth;
import 'package:boshkeh/core/utils/location_provider.dart';
import 'package:boshkeh/domain/calendar/calendar_manager.dart';

class CombinedEventRepository {
  final EventRepository eventRepository;
  final CountryHolidayService countryHolidayService;
  final NationalHolidayService nationalHolidayService;
  final ExploreHolidayService exploreHolidayService;
  final InternationalHolidayService internationalHolidayService;
  final HolidayIndicatorPreferenceRepository indicatorPreferenceRepository;
  final PublicEventService publicEventService;
  final LocationProvider locationProvider;
  final SubscriptionService subscriptionService;

  // Cache for search optimization
  List<CalendarEvent>? _cachedSearchableHolidays;
  DateTime? _lastSearchCacheUpdate;
  bool? _cachedIsShamsi; // Track which calendar type the cache was built for
  static const _searchCacheValidityDuration = Duration(minutes: 5); // Refresh cache every 5 minutes

  CombinedEventRepository({
    required this.eventRepository,
    required this.countryHolidayService,
    required this.nationalHolidayService,
    required this.exploreHolidayService,
    required this.internationalHolidayService,
    required this.indicatorPreferenceRepository,
    required this.publicEventService,
    required this.locationProvider,
    required this.subscriptionService,
  });

  /// Get all events for a given month from all sources.
  /// Handles personal events, local holidays, official Iranian holidays, and custom Iranian holidays.
  ///
  /// [yearMonth] The month to load events for
  /// [isShamsi] Whether to use Jalali calendar format
  /// Returns List of all events for the month (distinct by ID)
  Future<List<CalendarEvent>> getAllEventsForMonth(
    YearMonth yearMonth,
    bool isShamsi,
  ) async {

    try {
      // Create CalendarManager instance to use unified conversion logic
      final calendarManager = CalendarManager();
      
      // Calculate view range timestamps (UTC)
      DateTime startDateTime;
      DateTime endDateTime;
      
      if (isShamsi) {
        // Convert Gregorian YearMonth to Jalali to know which Shamsi month we are viewing
        // Just like in CalendarView, we use the 15th to find the center of the month
        final (jYear, jMonth, _) = calendarManager.convertDate(
          CalendarType.gregorian,
          CalendarType.shamsi,
          yearMonth.year,
          yearMonth.month,
          15,
        );
        
        // Find start: Jalali 1st -> Gregorian
        final (startGYear, startGMonth, startGDay) = calendarManager.convertDate(
          CalendarType.shamsi,
          CalendarType.gregorian,
          jYear, 
          jMonth, 
          1, // 1st day of Shamsi month
        );
        
        // Find end: Jalali Last Day -> Gregorian
        final jDaysInMonth = calendarManager.getDaysInMonth(CalendarType.shamsi, jYear, jMonth);
        final (endGYear, endGMonth, endGDay) = calendarManager.convertDate(
          CalendarType.shamsi,
          CalendarType.gregorian,
          jYear,
          jMonth,
          jDaysInMonth, // Last day of Shamsi month
        );
        
        // Create UTC timestamps
        startDateTime = DateTime.utc(startGYear, startGMonth, startGDay);
        endDateTime = DateTime.utc(endGYear, endGMonth, endGDay, 23, 59, 59);
        
      } else {
        // Gregorian Mode: Standard 1st to End of Month
        startDateTime = DateTime.utc(yearMonth.year, yearMonth.month, 1);
        final endDay = yearMonth.lengthOfMonth();
        endDateTime = DateTime.utc(yearMonth.year, yearMonth.month, endDay, 23, 59, 59);
      }

      AppLogger.d('CombinedEventRepository: Fetching events for range: $startDateTime to $endDateTime (isShamsi: $isShamsi)');

      // 1. Get all data sources in parallel
      final personalEventsFuture = () async {
        try {
          // Use new range-based query for personal events
          final events = await eventRepository.getEventsForDateRange(startDateTime, endDateTime);
          return events;
        } catch (e) {
          // Silently handle errors - return empty list
          return <CalendarEvent>[];
        }
      }();

      final holidayEventsFuture = () async {
        try {
          // Get only API (excluding IR) + custom holidays; exclude pure/generated holidays
          final holidays = await countryHolidayService.getAllHolidayEventsForMonth(yearMonth, isShamsi);
          return holidays;
        } catch (e) {
          // Silently handle errors - return empty list
          return <CalendarEvent>[];
        }
      }();

      final exploreHolidaysFuture = () async {
        try {
          // Get explore holidays (Stream C - from remote GitHub)
          final exploreHolidays = await exploreHolidayService.getEventsForMonth(yearMonth, isShamsi);
          return exploreHolidays;
        } catch (e) {
          AppLogger.d('CombinedEventRepository.getAllEventsForMonth: Error loading explore holidays: $e');
          return <CalendarEvent>[];
        }
      }();

      final nationalHolidaysFuture = () async {
        try {
          // Get national holidays (Stream B - core Iranian cultural)
          final nationalHolidays = await nationalHolidayService.getEventsForMonth(yearMonth, isShamsi);
          return nationalHolidays;
        } catch (e) {
          AppLogger.d('CombinedEventRepository.getAllEventsForMonth: Error loading national holidays: $e');
          return <CalendarEvent>[];
        }
      }();

      final internationalHolidaysFuture = () async {
        try {
          // Get international holidays (from global.json on GitHub)
          final internationalHolidays = await internationalHolidayService.getInternationalHolidaysForMonth(yearMonth, isShamsi);
          return internationalHolidays;
        } catch (e) {
          AppLogger.d('CombinedEventRepository.getAllEventsForMonth: Error loading international holidays: $e');
          return <CalendarEvent>[];
        }
      }();

      final publicEventsFuture = () async {
        try {
          // Get public events (Stream D - from GitHub)
          final events = await publicEventService.getCalendarEvents();
          
          // Filter by DATE RANGE instead of Month Index
          return events.where((e) {
            // Check if ANY part of the event overlaps with the view range
            // (Start < RangeEnd) AND (End > RangeStart)
            return e.startDateTime.isBefore(endDateTime) && 
                   e.endDateTime.isAfter(startDateTime);
          }).toList();
        } catch (e) {
          AppLogger.d('CombinedEventRepository: Error loading public events: $e');
          return <CalendarEvent>[];
        }
      }();

      // 2. Await and combine results
      final personalEvents = await personalEventsFuture;
      final holidayEvents = await holidayEventsFuture;
      final nationalHolidays = await nationalHolidaysFuture;
      var exploreHolidays = await exploreHolidaysFuture;
      final internationalHolidays = await internationalHolidaysFuture;
      final publicEvents = await publicEventsFuture;
      
      // 2.5. DEDUPLICATION: Stream B (national) takes priority over Stream C (explore)
      // If a holiday exists in both streams, only show the national version
      // This prevents duplicates like both national_nowruz_2025 and explore_nowruz_2025
      final nationalBaseIds = nationalHolidays
          .map((e) => _extractHolidayId(e.id))
          .toSet();
      
      if (nationalBaseIds.isNotEmpty) {
        final beforeCount = exploreHolidays.length;
        exploreHolidays = exploreHolidays
            .where((e) => !nationalBaseIds.contains(_extractHolidayId(e.id)))
            .toList();
        final removedCount = beforeCount - exploreHolidays.length;
        if (removedCount > 0) {
          AppLogger.d('CombinedEventRepository: Filtered $removedCount explore holidays (already in national)');
        }
      }
      
      AppLogger.d('CombinedEventRepository.getAllEventsForMonth: Personal: ${personalEvents.length}, Country: ${holidayEvents.length}, National: ${nationalHolidays.length}, Explore: ${exploreHolidays.length}, International: ${internationalHolidays.length}, Public: ${publicEvents.length}');
      final allEvents = <CalendarEvent>[...personalEvents, ...holidayEvents, ...nationalHolidays, ...exploreHolidays, ...internationalHolidays, ...publicEvents];
      AppLogger.d('CombinedEventRepository.getAllEventsForMonth: Combined ${allEvents.length} total events');

      // 3. Return a distinct list (prioritize holidays over personal events with same ID)
      final distinctEvents = <String, CalendarEvent>{};
      for (final event in allEvents) {
        try {
          // Use event.id as key, prioritizing holidays (added later)
          distinctEvents[event.id] = event;
        } catch (e, stackTrace) {
          AppLogger.d('CombinedEventRepository.getAllEventsForMonth: Error processing event: $e');
          AppLogger.d('CombinedEventRepository.getAllEventsForMonth: Stack trace: $stackTrace');
        }
      }
      AppLogger.d('CombinedEventRepository.getAllEventsForMonth: ${distinctEvents.length} distinct events');

      // 4. Filter events based on visibility preferences
      final filteredEvents = await _filterEventsByVisibility(distinctEvents.values.toList());
      
      AppLogger.d('CombinedEventRepository.getAllEventsForMonth: Returning ${filteredEvents.length} filtered events for month $yearMonth');
      return filteredEvents;
    } catch (e, stackTrace) {
      AppLogger.d('CombinedEventRepository.getAllEventsForMonth: Exception: $e');
      AppLogger.d('CombinedEventRepository.getAllEventsForMonth: Stack trace: $stackTrace');
      return <CalendarEvent>[];
    }
  }

  /// Get events for multiple months in parallel.
  /// Useful for preloading adjacent months for smooth navigation.
  ///
  /// [months] List of months to load events for
  /// [isShamsi] Whether to use Jalali calendar format
  /// Returns Map of YearMonth to list of events
  Future<Map<YearMonth, List<CalendarEvent>>> getEventsForMonths(
    List<YearMonth> months,
    bool isShamsi,
  ) async {
    try {
      // Launch all month loading operations in parallel
      final monthFutures = months.map((month) async {
        return MapEntry(month, await getAllEventsForMonth(month, isShamsi));
      });

      // Await all results and convert to map
      final results = await Future.wait(monthFutures);
      return Map.fromEntries(results);
    } catch (e) {
      return <YearMonth, List<CalendarEvent>>{};
    }
  }

  /// Deletes a user event by delegating to the personal event repository.
  /// Holidays cannot be deleted.
  Future<bool> deleteEvent(String eventId) async {
    // This repository's job is to orchestrate. Deletion only applies
    // to the personal event repository.
    return await eventRepository.deleteEvent(eventId);
  }

  /// Restore a soft-deleted event
  Future<bool> restoreEvent(String eventId) async {
    return await eventRepository.restoreEvent(eventId);
  }

  /// Finalize deletion (cleanup local-only events)
  Future<void> finalizeDelete(String eventId) async {
    await eventRepository.finalizeDelete(eventId);
  }

  /// Delete a single instance of a recurring event
  /// Adds an EXDATE exception to the master event to exclude the specified date
  Future<bool> deleteSingleInstance(String masterEventId, DateTime instanceDate) async {
    return await eventRepository.deleteSingleInstance(masterEventId, instanceDate);
  }

  /// Creates a user event by delegating to the personal event repository.
  Future<bool> createEvent(CalendarEvent event) async {
    return await eventRepository.createEvent(event);
  }

  /// Updates a user event by delegating to the personal event repository.
  Future<bool> updateEvent(CalendarEvent event) async {
    return await eventRepository.updateEvent(event);
  }

  /// Get the events flow from the underlying event repository.
  /// This allows the ViewModel to listen for real-time updates.
  Stream<List<CalendarEvent>> getEventsFlow() {
    return eventRepository.eventsFlow.map((events) => events.cast<CalendarEvent>().toList());
  }

  /// Get events for a specific date as a Flow from the underlying repository.
  Stream<List<CalendarEvent>> getEventsForDateFlow(DateTime date) {
    return eventRepository.getEventsForDateFlow(date).map((events) => events.cast<CalendarEvent>().toList());
  }

  /// Search all events (user events + holidays + international holidays) by text query
  /// Returns only one instance per event (master events only for recurring)
  /// Results are sorted by relevance (exact title matches first)
  /// Search all events (user events + holidays + international holidays) by text query
  /// Returns only one instance per event (master events only for recurring)
  /// Results are sorted by relevance (exact title matches first)
  Future<List<CalendarEvent>> searchAllEvents(
    String query,
    bool isShamsi,
  ) async {
    if (query.trim().isEmpty) return <CalendarEvent>[];

    try {
      // Normalize query for all searches (Turkish + Farsi character handling)
      final normalizedQuery = _normalizeForSearch(query.toLowerCase());

      // 1. Search user events (Always fresh from DB as they change frequently)
      final userEventsFuture = eventRepository.searchEvents(query);

      // 2. Get searchable holidays (Cached)
      final holidayEventsFuture = _getOrFetchSearchableHolidays(isShamsi);

      final userEvents = await userEventsFuture;
      final allHolidays = await holidayEventsFuture;
      
      // 3. Filter holidays in memory
      final matchingHolidays = _filterHolidaysByQuery(allHolidays, normalizedQuery);

      final allMatchingEvents = [...userEvents, ...matchingHolidays];

      // Remove duplicates by title + year (allows same holiday in different years)
      final distinctEvents = <String, CalendarEvent>{};
      for (final event in allMatchingEvents) {
        final year = event.startDateTime.year;
        final dedupeKey = '${event.title.toLowerCase()}_$year';
        // Keep the first occurrence (priority: user events > holidays)
        if (!distinctEvents.containsKey(dedupeKey)) {
          distinctEvents[dedupeKey] = event;
        }
      }

      // Sort by relevance: exact title matches first, then by date
      final results = distinctEvents.values.toList();
      results.sort((a, b) {
        final aTitleMatch = _normalizeForSearch(a.title.toLowerCase()).contains(normalizedQuery);
        final bTitleMatch = _normalizeForSearch(b.title.toLowerCase()).contains(normalizedQuery);
        
        // Title matches first
        if (aTitleMatch && !bTitleMatch) return -1;
        if (!aTitleMatch && bTitleMatch) return 1;
        
        // Then sort by date (upcoming first)
        return a.startDateTime.compareTo(b.startDateTime);
      });

      return results;
    } catch (e) {
      AppLogger.d('CombinedEventRepository.searchAllEvents: Top-level error: $e');
      return <CalendarEvent>[];
    }
  }

  /// Warm up the search cache in the background
  /// Call this when entering search screen to ensure fast results
  Future<void> warmupSearchCache(bool isShamsi) async {
    await _getOrFetchSearchableHolidays(isShamsi);
  }

  /// Helper to get or fetch all holidays for the current + next year
  /// Uses a cache to avoid expensive 48-month loop on every keystroke
  Future<List<CalendarEvent>> _getOrFetchSearchableHolidays(bool isShamsi) async {
    final now = DateTime.now();
    
    // Check cache validity (Time & Calendar Type)
    if (_cachedSearchableHolidays != null && 
        _lastSearchCacheUpdate != null &&
        _cachedIsShamsi == isShamsi &&
        now.difference(_lastSearchCacheUpdate!) < _searchCacheValidityDuration) {
      return _cachedSearchableHolidays!;
    }

    try {
      final currentYear = now.year;
      final allHolidays = <CalendarEvent>[];

      // Fetch National & International Holidays for current and next year (24 months total)
      // We do this in parallel chunks to speed up the "cache miss" scenario
      
      final monthsToLoad = <YearMonth>[];
      for (var year = currentYear; year <= currentYear + 1; year++) {
        for (var month = 1; month <= 12; month++) {
          monthsToLoad.add(YearMonth.of(year, month));
        }
      }

      // Process in batches of 6 to avoid overwhelming threads/network
      const batchSize = 6;
      for (var i = 0; i < monthsToLoad.length; i += batchSize) {
        final end = (i + batchSize < monthsToLoad.length) ? i + batchSize : monthsToLoad.length;
        final batch = monthsToLoad.sublist(i, end);
        
        final batchResults = await Future.wait(
          batch.map((ym) async {
            final national = await countryHolidayService.getAllHolidayEventsForMonth(ym, isShamsi);
            final international = await internationalHolidayService.getInternationalHolidaysForMonth(ym, isShamsi);
            final explore = await exploreHolidayService.getEventsForMonth(ym, isShamsi);
            return [...national, ...international, ...explore];
          }),
        );
        
        for (final events in batchResults) {
          allHolidays.addAll(events);
        }
      }

      _cachedSearchableHolidays = allHolidays;
      _lastSearchCacheUpdate = now;
      _cachedIsShamsi = isShamsi;
      AppLogger.d('CombinedEventRepository: Refreshed search cache with ${allHolidays.length} holidays');
      
      return allHolidays;
    } catch (e) {
      AppLogger.d('CombinedEventRepository: Error refreshing holiday cache: $e');
      // On error, return existing cache if available, or empty list
      return _cachedSearchableHolidays ?? <CalendarEvent>[];
    }
  }

  /// Normalize text for search by handling Turkish and Farsi characters
  String _normalizeForSearch(String text) {
    return text
        // Turkish characters
        .replaceAll('ı', 'i')
        .replaceAll('ğ', 'g')
        .replaceAll('ü', 'u')
        .replaceAll('ş', 's')
        .replaceAll('ö', 'o')
        .replaceAll('ç', 'c')
        // Farsi/Arabic variations
        .replaceAll('ی', 'ي')
        .replaceAll('ک', 'ك')
        .replaceAll('ە', 'ه')
        .replaceAll('ؤ', 'و')
        .replaceAll('أ', 'ا')
        .replaceAll('إ', 'ا')
        .replaceAll('آ', 'ا')
        // Remove diacritics (common in Farsi)
        .replaceAll(RegExp(r'[\u064B-\u065F]'), '');
  }

  /// Filter holidays by search query with multi-field matching
  List<CalendarEvent> _filterHolidaysByQuery(List<CalendarEvent> holidays, String normalizedQuery) {
    final matchingHolidays = holidays.where((holiday) {
      final title = _normalizeForSearch(holiday.title.toLowerCase());
      final description = _normalizeForSearch((holiday.description ?? '').toLowerCase());
      final nativeTitle = _normalizeForSearch((holiday.nativeTitle ?? '').toLowerCase());
      final englishTitle = _normalizeForSearch((holiday.englishTitle ?? '').toLowerCase());
      final summary = _normalizeForSearch((holiday.summary ?? '').toLowerCase());
      
      // Also check localized titles
      bool localizedMatch = false;
      if (holiday.localizedTitles != null) {
        for (final localizedTitle in holiday.localizedTitles!.values) {
          if (_normalizeForSearch(localizedTitle.toLowerCase()).contains(normalizedQuery)) {
            localizedMatch = true;
            break;
          }
        }
      }

      return title.contains(normalizedQuery) ||
          description.contains(normalizedQuery) ||
          nativeTitle.contains(normalizedQuery) ||
          englishTitle.contains(normalizedQuery) ||
          summary.contains(normalizedQuery) ||
          localizedMatch;
    }).toList();

    return matchingHolidays;
  }

  /// Clean up old cache entries to prevent memory issues
  Future<void> cleanupOldCache() async {
    try {
      // Access the recurrence instance cache through the event repository
      await eventRepository.cleanupOldCache();
    } catch (e) {
    }
  }

  /// Filter events based on visibility preferences
  /// Rules:
  /// - User events: always visible
  /// - Stream B (national_ prefix): always visible (core Iranian cultural holidays)
  /// - Country holidays (location-based): respect category visibility
  /// - Stream C (explore_ prefix, non-essential): check preference + require login
  /// - International holidays: check category visibility
  /// 
  /// OPTIMIZED: Uses batch preference loading to avoid N+1 query problem.
  /// Loads all preferences ONCE, then filters synchronously in memory.
  Future<List<CalendarEvent>> _filterEventsByVisibility(List<CalendarEvent> events) async {
    if (events.isEmpty) return [];
    
    final filtered = <CalendarEvent>[];
    final countryCode = await locationProvider.getCountryCode();
    final isUserPremium = await subscriptionService.isUserPremium;
    
    // OPTIMIZATION: Load all preferences in one batch instead of per-event queries
    final batchContext = await indicatorPreferenceRepository.loadBatchContext(isUserPremium: isUserPremium);
    
    for (final event in events) {
      // User events are always visible
      if (event.eventType == EventType.userEvent) {
        filtered.add(event);
        continue;
      }
      
      // Stream B: National holidays (core Iranian cultural) are ALWAYS visible
      // These have IDs like "national_nowruz_2025"
      // Note: Country holidays start with "national_holiday_", so we must exclude them here
      if (event.id.startsWith('national_') && !event.id.startsWith('national_holiday_')) {
        filtered.add(event);
        continue;
      }
      
      // Stream D: Public Events
      if (event.id.startsWith('public_')) {
        // Use synchronous batch check instead of async DB call
        final isVisible = batchContext.shouldShowHolidaySync(
          holidayId: event.id,
          isUserEvent: false,
          isNationalHoliday: false,
          isEssential: false, // Public events are opt-in, not essential defaults
          category: 'public_event',
          isExplore: true, // Treat as explore so they are hidden by default (opt-in)
        );
        if (isVisible) {
          filtered.add(event);
        }
        continue;
      }
      
      // Extract holiday ID from event ID
      // Event IDs from explore holidays are like "explore_nowruz_2025"
      // Other holiday IDs might be different formats
      final holidayId = _extractHolidayId(event.id);
      final isExplore = event.id.startsWith('explore_');
      
      // Check if it's a country holiday for user's country (Stream A)
      final isCountryHoliday = event.eventType == EventType.nationalHoliday &&
          event.countryCode != null &&
          event.countryCode == countryCode;
      
      // Check if it's essential using pre-loaded data (no DB call)
      final isEssential = batchContext.essentialMap[holidayId] ?? false;

      // Determine category for category-based filtering
      String? category;
      if (event.eventType == EventType.internationalHoliday) {
        category = 'international';
      } else if (event.eventType == EventType.nationalHoliday) {
        category = 'national';
      } else if (event.category != null) {
        category = event.category;
      }

      
      // Use synchronous batch check instead of async DB call
      final shouldShow = batchContext.shouldShowHolidaySync(
        holidayId: holidayId,
        isUserEvent: false,
        isNationalHoliday: isCountryHoliday,
        isEssential: isEssential,
        category: category,
        isExplore: isExplore,
      );
      
      if (shouldShow) {
        filtered.add(event);
      }
    }
    
    return filtered;
  }

  /// Extract holiday ID from event ID
  /// Handles different ID formats:
  /// - "explore_nowruz_2025" -> "nowruz"
  /// - "holiday_IR_2025-03-21_Nowruz" -> "holiday_IR_2025-03-21_Nowruz"
  String _extractHolidayId(String eventId) {
    // If it's an explore holiday, extract the base ID
    if (eventId.startsWith('explore_')) {
      // Format is explore_{holiday_id}_{year}
      // Remove 'explore_' prefix
      var remaining = eventId.substring('explore_'.length);
      
      // Check if it ends with _{year}
      final lastUnderscoreIndex = remaining.lastIndexOf('_');
      if (lastUnderscoreIndex != -1) {
        final possibleYear = remaining.substring(lastUnderscoreIndex + 1);
        // If the last part is a 4-digit number, assume it's the year suffix and strip it
        if (possibleYear.length == 4 && int.tryParse(possibleYear) != null) {
          return remaining.substring(0, lastUnderscoreIndex);
        }
      }
      return remaining;
    }
    // For other holidays, use the full ID
    return eventId;
  }

  /// Check if a holiday is essential
  Future<bool> _isEssentialHoliday(String holidayId) async {
    return await indicatorPreferenceRepository.isEssential(holidayId);
  }


}



