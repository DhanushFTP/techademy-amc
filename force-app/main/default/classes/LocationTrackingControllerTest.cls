@IsTest
private class LocationTrackingControllerTest {

    // ── Start tracking creates a session ──
    @IsTest
    static void testStartTracking() {
        Test.startTest();
        Id sessionId = LocationTrackingController.startTracking();
        Test.stopTest();

        Field_Tracking_Session__c session = [
            SELECT Status__c, Tracking_Date__c, User__c
            FROM Field_Tracking_Session__c
            WHERE Id = :sessionId
        ];
        System.assertEquals('Active', session.Status__c, 'Session should be Active');
        System.assertEquals(Date.today(), session.Tracking_Date__c, 'Date should be today');
        System.assertEquals(UserInfo.getUserId(), session.User__c, 'Should be current user');
    }

    // ── Duplicate active session should fail ──
    @IsTest
    static void testStartTrackingDuplicate() {
        LocationTrackingController.startTracking();

        Test.startTest();
        try {
            LocationTrackingController.startTracking();
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('already have an active'), 'Should reject duplicate session');
        }
        Test.stopTest();
    }

    // ── Log location creates a record ──
    @IsTest
    static void testLogLocation() {
        Id sessionId = LocationTrackingController.startTracking();

        Test.startTest();
        LocationTrackingController.logLocation(sessionId, 12.9716, 77.5946);
        LocationTrackingController.logLocation(sessionId, 12.9720, 77.5950);
        Test.stopTest();

        List<Location_Log__c> logs = [
            SELECT Latitude__c, Longitude__c, Timestamp__c
            FROM Location_Log__c
            WHERE Session__c = :sessionId
            ORDER BY Timestamp__c ASC
        ];
        System.assertEquals(2, logs.size(), 'Should have 2 location logs');
        System.assertEquals(12.9716, logs[0].Latitude__c, 'First lat should match');
    }

    // ── Stop tracking completes the session ──
    @IsTest
    static void testStopTracking() {
        Id sessionId = LocationTrackingController.startTracking();

        Test.startTest();
        LocationTrackingController.stopTracking(sessionId);
        Test.stopTest();

        Field_Tracking_Session__c session = [
            SELECT Status__c, End_Time__c
            FROM Field_Tracking_Session__c
            WHERE Id = :sessionId
        ];
        System.assertEquals('Completed', session.Status__c, 'Session should be Completed');
        System.assertNotEquals(null, session.End_Time__c, 'End time should be set');
    }

    // ── Double stop should fail ──
    @IsTest
    static void testDoubleStop() {
        Id sessionId = LocationTrackingController.startTracking();
        LocationTrackingController.stopTracking(sessionId);

        Test.startTest();
        try {
            LocationTrackingController.stopTracking(sessionId);
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('already completed'), 'Should reject double stop');
        }
        Test.stopTest();
    }

    // ── Get active session returns current session ──
    @IsTest
    static void testGetActiveSession() {
        LocationTrackingController.startTracking();

        Test.startTest();
        Field_Tracking_Session__c session = LocationTrackingController.getActiveSession();
        Test.stopTest();

        System.assertNotEquals(null, session, 'Should return active session');
    }

    // ── Get active session returns null when none ──
    @IsTest
    static void testGetActiveSessionNone() {
        Test.startTest();
        Field_Tracking_Session__c session = LocationTrackingController.getActiveSession();
        Test.stopTest();

        System.assertEquals(null, session, 'Should return null when no active session');
    }

    // ── Get location count ──
    @IsTest
    static void testGetLocationCount() {
        Id sessionId = LocationTrackingController.startTracking();
        LocationTrackingController.logLocation(sessionId, 12.97, 77.59);
        LocationTrackingController.logLocation(sessionId, 12.98, 77.60);
        LocationTrackingController.logLocation(sessionId, 12.99, 77.61);

        Test.startTest();
        Integer count = LocationTrackingController.getLocationCount(sessionId);
        Test.stopTest();

        System.assertEquals(3, count, 'Should count 3 locations');
    }

    // ── Get tracking data with data ──
    @IsTest
    static void testGetTrackingDataWithData() {
        Id sessionId = LocationTrackingController.startTracking();
        LocationTrackingController.logLocation(sessionId, 12.97, 77.59);
        LocationTrackingController.logLocation(sessionId, 12.98, 77.60);
        LocationTrackingController.stopTracking(sessionId);

        Test.startTest();
        Map<String, Object> result = LocationTrackingController.getTrackingData(
            UserInfo.getUserId(), Date.today()
        );
        Test.stopTest();

        System.assertEquals(true, result.get('hasData'), 'Should have data');
        List<Object> points = (List<Object>) result.get('points');
        System.assertEquals(2, points.size(), 'Should have 2 points');
    }

    // ── Get tracking data without data ──
    @IsTest
    static void testGetTrackingDataNoData() {
        Test.startTest();
        Map<String, Object> result = LocationTrackingController.getTrackingData(
            UserInfo.getUserId(), Date.today()
        );
        Test.stopTest();

        System.assertEquals(false, result.get('hasData'), 'Should not have data');
    }
}