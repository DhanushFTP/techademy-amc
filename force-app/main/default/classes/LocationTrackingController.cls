public with sharing class LocationTrackingController {

    // ── Helper to throw AuraHandledException with message properly set ──
    private static void throwAuraError(String msg) {
        AuraHandledException e = new AuraHandledException(msg);
        e.setMessage(msg);
        throw e;
    }

    // ── Start a new tracking session ──
    @AuraEnabled
    public static Id startTracking() {
        // Prevent multiple active sessions
        List<Field_Tracking_Session__c> existing = [
            SELECT Id FROM Field_Tracking_Session__c
            WHERE User__c = :UserInfo.getUserId()
              AND Status__c = 'Active'
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            throwAuraError('You already have an active tracking session.');
        }

        Field_Tracking_Session__c session = new Field_Tracking_Session__c(
            User__c         = UserInfo.getUserId(),
            Start_Time__c   = System.now(),
            Status__c       = 'Active',
            Tracking_Date__c = Date.today()
        );
        insert session;
        return session.Id;
    }

    // ── Log a GPS location point ──
    @AuraEnabled
    public static void logLocation(Id sessionId, Decimal latitude, Decimal longitude) {
        Location_Log__c loc = new Location_Log__c(
            Session__c  = sessionId,
            Latitude__c = latitude,
            Longitude__c = longitude,
            Timestamp__c = System.now()
        );
        insert loc;
    }

    // ── Stop the tracking session ──
    @AuraEnabled
    public static void stopTracking(Id sessionId) {
        Field_Tracking_Session__c session = [
            SELECT Id, Status__c FROM Field_Tracking_Session__c
            WHERE Id = :sessionId LIMIT 1
        ];
        if (session.Status__c == 'Completed') {
            throwAuraError('This session is already completed.');
        }
        session.End_Time__c = System.now();
        session.Status__c   = 'Completed';
        update session;
    }

    // ── Get the current user's active session (if any) ──
    @AuraEnabled
    public static Field_Tracking_Session__c getActiveSession() {
        List<Field_Tracking_Session__c> sessions = [
            SELECT Id, Start_Time__c, Tracking_Date__c
            FROM Field_Tracking_Session__c
            WHERE User__c = :UserInfo.getUserId()
              AND Status__c = 'Active'
            ORDER BY Start_Time__c DESC
            LIMIT 1
        ];
        return sessions.isEmpty() ? null : sessions[0];
    }

    // ── Get location count for active session (for UI display) ──
    @AuraEnabled
    public static Integer getLocationCount(Id sessionId) {
        return [SELECT COUNT() FROM Location_Log__c WHERE Session__c = :sessionId];
    }

    // ── Get tracking data for a user on a specific date (for route map) ──
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getTrackingData(Id userId, Date trackingDate) {
        Map<String, Object> result = new Map<String, Object>();

        List<Field_Tracking_Session__c> sessions = [
            SELECT Id, Start_Time__c, End_Time__c, Status__c
            FROM Field_Tracking_Session__c
            WHERE User__c = :userId
              AND Tracking_Date__c = :trackingDate
            ORDER BY Start_Time__c ASC
        ];

        if (sessions.isEmpty()) {
            result.put('hasData', false);
            return result;
        }

        // Collect all session IDs
        Set<Id> sessionIds = new Set<Id>();
        for (Field_Tracking_Session__c s : sessions) {
            sessionIds.add(s.Id);
        }

        List<Location_Log__c> logs = [
            SELECT Latitude__c, Longitude__c, Timestamp__c, Session__c
            FROM Location_Log__c
            WHERE Session__c IN :sessionIds
            ORDER BY Timestamp__c ASC
        ];

        // Build location points array
        List<Map<String, Object>> points = new List<Map<String, Object>>();
        for (Location_Log__c log : logs) {
            points.add(new Map<String, Object>{
                'lat'       => log.Latitude__c,
                'lng'       => log.Longitude__c,
                'timestamp' => String.valueOf(log.Timestamp__c)
            });
        }

        result.put('hasData', true);
        result.put('points', points);
        result.put('sessionCount', sessions.size());
        result.put('startTime', String.valueOf(sessions[0].Start_Time__c));

        Field_Tracking_Session__c lastSession = sessions[sessions.size() - 1];
        if (lastSession.End_Time__c != null) {
            result.put('endTime', String.valueOf(lastSession.End_Time__c));
        }
        result.put('status', lastSession.Status__c);

        return result;
    }
}