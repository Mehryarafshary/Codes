import 'package:boshkeh/core/utils/app_logger.dart';
import 'package:boshkeh/domain/models/events/public_event.dart';
import 'package:boshkeh/domain/models/events/public_event_reminder.dart';
import 'package:boshkeh/domain/notification/native_reminder_service.dart';
import 'package:boshkeh/data/repositories/events/public_event_reminder_repository.dart';

/// Service for scheduling and managing public event reminder notifications.
/// 
/// This service handles:
/// - Scheduling reminders when users "subscribe" to public events
/// - Day-of reminders for subscribed events
/// - Canceling reminders when users unsubscribe
class PublicEventReminderScheduler {
  final PublicEventReminderRepository _repository;

  /// Default time for public event reminders (9:00 AM local time)
  static const int defaultReminderHour = 9;
  static const int defaultReminderMinute = 0;

  PublicEventReminderScheduler(this._repository);

  /// Schedule a reminder notification for a public event
  /// 
  /// [event] - The public event to remind about
  /// [reminder] - The reminder configuration
  /// [isFarsi] - Whether to use Farsi for notification text
  Future<bool> scheduleReminder({
    required PublicEvent event,
    required PublicEventReminder reminder,
    bool isFarsi = false,
  }) async {
    try {
      final now = DateTime.now();
      
      // Calculate reminder time
      final reminderTime = reminder.reminderTime;
      
      // Skip if reminder time is in the past
      if (reminderTime.isBefore(now)) {
        AppLogger.d('PublicEventReminderScheduler: Skipping past reminder for ${event.id}');
        return false;
      }

      // Calculate delay in seconds from now
      final delaySeconds = reminderTime.difference(now).inSeconds;

      // Build notification content
      final title = isFarsi ? (event.titleFa ?? event.title) : event.title;
      final notificationTitle = isFarsi 
          ? '📅 $title نزدیک است!'
          : '📅 $title is coming up!';
      final notificationBody = isFarsi
          ? '${reminder.reminderOption.displayName(isFarsi: true)} - برنامه‌ریزی کنید!'
          : '${reminder.reminderOption.displayName(isFarsi: false)} - Plan ahead!';

      // Schedule using native service
      final success = await NativeReminderService.scheduleReminder(
        reminderId: reminder.id,
        eventId: event.id,
        eventTitle: title,
        eventLocation: event.location,
        eventStartTime: event.startDateTime.toIso8601String(),
        eventColorValue: 0xFF4CAF50, // Green for public events
        isFiveMinuteReminder: false,
        delaySeconds: delaySeconds,
        notificationTitle: notificationTitle,
        notificationBody: notificationBody,
      );

      if (success) {
        AppLogger.d('✅ PublicEventReminderScheduler: Scheduled reminder ${reminder.id} at $reminderTime');
      }

      return success;
    } catch (e) {
      AppLogger.d('PublicEventReminderScheduler: Error scheduling reminder: $e');
      return false;
    }
  }

  /// Schedule a day-of reminder for a public event
  /// This fires on the morning of the event
  Future<bool> scheduleDayOfReminder({
    required PublicEvent event,
    bool isFarsi = false,
  }) async {
    try {
      final now = DateTime.now();
      
      // Calculate reminder for morning of the event
      final eventDate = event.startDateTime;
      final reminderDateTime = DateTime(
        eventDate.year,
        eventDate.month,
        eventDate.day,
        defaultReminderHour,
        defaultReminderMinute,
      );

      // Skip if reminder time is in the past
      if (reminderDateTime.isBefore(now)) {
        AppLogger.d('PublicEventReminderScheduler: Skipping day-of reminder for ${event.id} (past)');
        return false;
      }

      // Calculate delay in seconds from now
      final delaySeconds = reminderDateTime.difference(now).inSeconds;

      // Build notification content for day-of
      final title = isFarsi ? (event.titleFa ?? event.title) : event.title;
      final notificationTitle = isFarsi 
          ? '🎉 امروز $title است!'
          : '🎉 Today is $title!';
      final notificationBody = isFarsi
          ? event.location != null ? '📍 ${event.location}' : 'وقتش رسیده!'
          : event.location != null ? '📍 ${event.location}' : 'Time to attend!';

      // Use a special ID format for day-of reminders
      final dayOfReminderId = 'public_day_of_${event.id}';

      final success = await NativeReminderService.scheduleReminder(
        reminderId: dayOfReminderId,
        eventId: event.id,
        eventTitle: title,
        eventLocation: event.location,
        eventStartTime: event.startDateTime.toIso8601String(),
        eventColorValue: 0xFF4CAF50, // Green for public events
        isFiveMinuteReminder: false,
        delaySeconds: delaySeconds,
        notificationTitle: notificationTitle,
        notificationBody: notificationBody,
      );

      if (success) {
        AppLogger.d('✅ PublicEventReminderScheduler: Scheduled day-of reminder for ${event.id}');
      }

      return success;
    } catch (e) {
      AppLogger.d('PublicEventReminderScheduler: Error scheduling day-of reminder: $e');
      return false;
    }
  }

  /// Cancel a specific reminder
  Future<bool> cancelReminder(String reminderId) async {
    try {
      final success = await NativeReminderService.cancelScheduledReminder(
        reminderId: reminderId,
      );
      
      if (success) {
        AppLogger.d('✅ PublicEventReminderScheduler: Cancelled reminder $reminderId');
      }
      
      return success;
    } catch (e) {
      AppLogger.d('PublicEventReminderScheduler: Error canceling reminder: $e');
      return false;
    }
  }

  /// Cancel the day-of reminder for an event
  Future<bool> cancelDayOfReminder(String eventId) async {
    final dayOfReminderId = 'public_day_of_$eventId';
    return cancelReminder(dayOfReminderId);
  }

  /// Cancel all reminders for a public event (including day-of)
  Future<void> cancelAllRemindersForEvent(String eventId) async {
    // Cancel day-of reminder
    await cancelDayOfReminder(eventId);
    
    // Get and cancel all custom reminders
    final reminders = await _repository.getRemindersForEvent(eventId);
    for (final reminder in reminders) {
      await cancelReminder(reminder.id);
    }
    
    AppLogger.d('✅ PublicEventReminderScheduler: Cancelled all ${reminders.length + 1} reminders for $eventId');
  }

  /// Subscribe to a public event with a reminder option
  /// This saves the reminder and schedules the notification
  Future<bool> subscribeToEvent({
    required PublicEvent event,
    required PublicEventReminderOption option,
    bool isFarsi = false,
  }) async {
    try {
      // Save to repository
      final reminder = await _repository.addReminder(
        eventId: event.id,
        eventTitle: event.title,
        eventStartTime: event.startDateTime,
        option: option,
      );

      // Schedule the notification
      final success = await scheduleReminder(
        event: event,
        reminder: reminder,
        isFarsi: isFarsi,
      );

      // Also schedule day-of reminder if this is the first subscription
      final hasOthers = await _repository.getReminderCount(event.id) > 1;
      if (!hasOthers) {
        await scheduleDayOfReminder(event: event, isFarsi: isFarsi);
      }

      return success;
    } catch (e) {
      AppLogger.d('PublicEventReminderScheduler: Error subscribing: $e');
      return false;
    }
  }

  /// Unsubscribe from a public event (remove specific reminder)
  Future<void> unsubscribeFromReminder(String reminderId) async {
    await cancelReminder(reminderId);
    await _repository.removeReminder(reminderId);
  }

  /// Completely unsubscribe from a public event (remove all reminders)
  Future<void> unsubscribeFromEvent(String eventId) async {
    await cancelAllRemindersForEvent(eventId);
    await _repository.removeAllRemindersForEvent(eventId);
    AppLogger.d('✅ PublicEventReminderScheduler: Fully unsubscribed from $eventId');
  }

  /// Re-schedule all valid reminders (for use after app start or boot)
  Future<int> rescheduleAllReminders({bool isFarsi = false}) async {
    try {
      final reminders = await _repository.getValidReminders();
      int scheduledCount = 0;

      for (final reminder in reminders) {
        // Create a minimal PublicEvent for scheduling
        final event = PublicEvent(
          id: reminder.eventId,
          title: reminder.eventTitle,
          startDateTime: reminder.eventStartTime,
          endDateTime: reminder.eventStartTime.add(const Duration(hours: 2)),
        );

        final success = await scheduleReminder(
          event: event,
          reminder: reminder,
          isFarsi: isFarsi,
        );

        if (success) scheduledCount++;
      }

      // Clean up past reminders
      await _repository.cleanupPastReminders();

      AppLogger.d('✅ PublicEventReminderScheduler: Re-scheduled $scheduledCount reminders');
      return scheduledCount;
    } catch (e) {
      AppLogger.d('PublicEventReminderScheduler: Error rescheduling: $e');
      return 0;
    }
  }
}
