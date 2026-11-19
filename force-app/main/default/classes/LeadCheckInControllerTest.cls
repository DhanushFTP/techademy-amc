/******************************************************************
 * Class Name    : LeadCheckInControllerTest
 * Company       : Fingertip Technologies Pvt Ltd
 * Created Date  : 06-11-2026
 * @description  : Tests for LeadCheckInController (lead check-in /
 *                 check-out within the check-in distance, failure
 *                 logging, open check-in, map markers through
 *                 CheckInMapController, distance from the
 *                 Check_In_Max_Distance_Meters label) and the
 *                 Lead_Check_In_Lead_Required validation rule.
 * @author       : Tharun N
 * @group        : Lead
 * Used By       : - LeadCheckInController
 * Change Log:
 * -----------------------------------------------------------------------------
 * Ver | Author          | Date       | Description
 * -----------------------------------------------------------------------------
 * 1.0 | Tharun N        | 06-11-2026 | Initial version
 * 1.1 | Tharun N        | 16-11-2026 | Tests for the check-in distance from
 *     |                 |            | the Check_In_Max_Distance_Meters label
 *     |                 |            | (1000 m): label value used, a check-in
 *     |                 |            | about 750 m away, and the distance in
 *     |                 |            | the error message. Standard header.
 * -----------------------------------------------------------------------------
 ******************************************************************/
@IsTest
private class LeadCheckInControllerTest {

    private static final Decimal LEAD_LAT = 12.892157;
    private static final Decimal LEAD_LNG = 77.465362;
    // ~100 m from the lead
    private static final Decimal NEAR_LAT = 12.8925;
    private static final Decimal NEAR_LNG = 77.4650;
    // ~5 km from the lead
    private static final Decimal FAR_LAT = 12.93;
    private static final Decimal FAR_LNG = 77.50;
    private static final String LOG_POINT = 'Lead Checkin';
    private static final String REP_LAST_NAME = 'Lead Check In Test Rep';

    @TestSetup
    static void setup() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert newRep();
        }
        Id repId = [SELECT Id FROM User WHERE LastName = :REP_LAST_NAME LIMIT 1].Id;

        Lead repLead = new Lead(LastName = 'Lead Check In Rep Lead', Company = 'Lead Check In Co', OwnerId = repId,
            Lead_Geo_Location__Latitude__s = LEAD_LAT, Lead_Geo_Location__Longitude__s = LEAD_LNG);
        insert new List<Lead>{
            new Lead(LastName = 'Lead Check In Test Lead', Company = 'Lead Check In Co',
                Lead_Geo_Location__Latitude__s = LEAD_LAT, Lead_Geo_Location__Longitude__s = LEAD_LNG),
            new Lead(LastName = 'Lead Check In No Geo Lead', Company = 'Lead Check In Co'),
            repLead
        };
        // Lead assignment automation may change the owner on create, so set it again
        update new Lead(Id = repLead.Id, OwnerId = repId);
    }

    // ── Check in ──

    @IsTest
    static void checkInWithinRadius() {
        Lead ld = lead('Lead Check In Test Lead');

        Test.startTest();
        LeadCheckInController.CheckInResult result = LeadCheckInController.checkIn(ld.Id, NEAR_LAT, NEAR_LNG);
        Test.stopTest();

        Assert.isTrue(result.success, 'Check-in about 100 m away should succeed: ' + result.message);
        Lead_Check_In__c rec = [
            SELECT Lead__c, Status__c, Rep_Name__c, OwnerId, Check_In_Time__c, Check_In_Latitude__c
            FROM Lead_Check_In__c
            WHERE Id = :result.checkInId
        ];
        Assert.areEqual(ld.Id, rec.Lead__c, 'Linked to the lead');
        Assert.areEqual('Checked In', rec.Status__c, 'Status Checked In');
        Assert.areEqual(UserInfo.getUserId(), rec.Rep_Name__c, 'Rep is the running user');
        Assert.areEqual(UserInfo.getUserId(), rec.OwnerId, 'Owned by the rep');
        Assert.isNotNull(rec.Check_In_Time__c, 'Check-in time set');
        Assert.isNotNull(rec.Check_In_Latitude__c, 'Latitude set');
        Assert.areEqual(1, logCount('Status: Success'), 'Success is logged');
    }

    @IsTest
    static void checkInOutsideRadiusIsRefusedAndLogged() {
        Lead ld = lead('Lead Check In Test Lead');

        Test.startTest();
        LeadCheckInController.CheckInResult result = LeadCheckInController.checkIn(ld.Id, FAR_LAT, FAR_LNG);
        Test.stopTest();

        Assert.isFalse(result.success, 'Check-in 5 km away is refused');
        Assert.isTrue(result.message.contains('meters away'), 'Distance in the message: ' + result.message);
        Assert.areEqual(0, [SELECT COUNT() FROM Lead_Check_In__c], 'No check-in saved');
        Assert.areEqual(1, logCount('Status: Failed'), 'Refused attempt is logged');
    }

    @IsTest
    static void checkInWithoutLeadLocationIsRefused() {
        Lead ld = lead('Lead Check In No Geo Lead');

        Test.startTest();
        LeadCheckInController.CheckInResult result = LeadCheckInController.checkIn(ld.Id, NEAR_LAT, NEAR_LNG);
        Test.stopTest();

        Assert.isFalse(result.success, 'No lead location: refused');
        Assert.isTrue(result.message.contains('Lead Geo Location is not set'), 'Asks to capture it: ' + result.message);
    }

    @IsTest
    static void checkInOnOtherRecordIsRefused() {
        Account acc = new Account(Name = 'Lead Check In Test Account', Type = 'University');
        insert acc;

        Test.startTest();
        LeadCheckInController.CheckInResult onAccount = LeadCheckInController.checkIn(acc.Id, NEAR_LAT, NEAR_LNG);
        LeadCheckInController.CheckInResult onNull = LeadCheckInController.checkIn(null, NEAR_LAT, NEAR_LNG);
        Test.stopTest();

        Assert.isFalse(onAccount.success, 'Account Id refused');
        Assert.isTrue(onAccount.message.contains('only on Leads'), 'Clear message: ' + onAccount.message);
        Assert.isFalse(onNull.success, 'Missing Id refused');
    }

    @IsTest
    static void checkInWithoutCoordinatesIsRefused() {
        Lead ld = lead('Lead Check In Test Lead');

        Test.startTest();
        LeadCheckInController.CheckInResult result = LeadCheckInController.checkIn(ld.Id, null, null);
        Test.stopTest();

        Assert.isFalse(result.success, 'No coordinates: refused');
    }

    // ── Check out ──

    @IsTest
    static void checkOutWithinRadius() {
        Lead ld = lead('Lead Check In Test Lead');
        Id checkInId = LeadCheckInController.checkIn(ld.Id, NEAR_LAT, NEAR_LNG).checkInId;

        Test.startTest();
        LeadCheckInController.CheckInResult result = LeadCheckInController.checkOut(checkInId, 12.8920, 77.4655, 'Met the lead');
        Test.stopTest();

        Assert.isTrue(result.success, 'Check-out should succeed: ' + result.message);
        Lead_Check_In__c rec = [
            SELECT Status__c, Check_Out_Time__c, Check_Out_Notes__c, Check_Out_Latitude__c
            FROM Lead_Check_In__c
            WHERE Id = :checkInId
        ];
        Assert.areEqual('Checked Out', rec.Status__c, 'Status Checked Out');
        Assert.isNotNull(rec.Check_Out_Time__c, 'Check-out time set');
        Assert.isNotNull(rec.Check_Out_Latitude__c, 'Check-out latitude set');
        Assert.areEqual('Met the lead', rec.Check_Out_Notes__c, 'Notes saved');
    }

    @IsTest
    static void checkOutOutsideRadiusIsRefused() {
        Lead ld = lead('Lead Check In Test Lead');
        Id checkInId = LeadCheckInController.checkIn(ld.Id, NEAR_LAT, NEAR_LNG).checkInId;

        Test.startTest();
        LeadCheckInController.CheckInResult result = LeadCheckInController.checkOut(checkInId, FAR_LAT, FAR_LNG, null);
        Test.stopTest();

        Assert.isFalse(result.success, 'Check-out 5 km away is refused');
        Assert.isTrue(result.message.contains('meters away'), 'Distance in the message: ' + result.message);
        Assert.areEqual('Checked In',
            [SELECT Status__c FROM Lead_Check_In__c WHERE Id = :checkInId].Status__c, 'Still checked in');
    }

    @IsTest
    static void doubleCheckOutIsRefused() {
        Lead ld = lead('Lead Check In Test Lead');
        Id checkInId = LeadCheckInController.checkIn(ld.Id, NEAR_LAT, NEAR_LNG).checkInId;
        LeadCheckInController.checkOut(checkInId, NEAR_LAT, NEAR_LNG, 'Done');

        Test.startTest();
        LeadCheckInController.CheckInResult again = LeadCheckInController.checkOut(checkInId, NEAR_LAT, NEAR_LNG, 'Again');
        Test.stopTest();

        Assert.isFalse(again.success, 'Second check-out refused');
        Assert.isTrue(again.message.contains('already been checked out'), 'Clear message: ' + again.message);
    }

    @IsTest
    static void checkOutOfMissingCheckInIsRefused() {
        Lead ld = lead('Lead Check In Test Lead');
        Id checkInId = LeadCheckInController.checkIn(ld.Id, NEAR_LAT, NEAR_LNG).checkInId;
        delete new Lead_Check_In__c(Id = checkInId);

        Test.startTest();
        LeadCheckInController.CheckInResult result = LeadCheckInController.checkOut(checkInId, NEAR_LAT, NEAR_LNG, null);
        Test.stopTest();

        Assert.isFalse(result.success, 'Deleted check-in refused');
        Assert.isTrue(result.message.contains('not found'), 'Clear message: ' + result.message);
    }

    // ── A rep on their own lead ──

    @IsTest
    static void repChecksInAndOutOnOwnLead() {
        Id leadId = lead('Lead Check In Rep Lead').Id;
        LeadCheckInController.CheckInResult checkedIn;
        LeadCheckInController.CheckInResult checkedOut;
        Lead_Check_In__c active;
        System.runAs(rep()) {
            Test.startTest();
            checkedIn = LeadCheckInController.checkIn(leadId, NEAR_LAT, NEAR_LNG);
            active = LeadCheckInController.getActiveCheckIn(leadId);
            checkedOut = LeadCheckInController.checkOut(checkedIn.checkInId, NEAR_LAT, NEAR_LNG, 'Rep visit');
            Test.stopTest();
        }
        Assert.isTrue(checkedIn.success, 'Rep can check in on their lead: ' + checkedIn.message);
        Assert.isNotNull(active, 'Open check-in found for the rep');
        Assert.isTrue(checkedOut.success, 'Rep can check out of their own check-in: ' + checkedOut.message);
        Assert.areEqual(rep().Id, [SELECT OwnerId FROM Lead_Check_In__c WHERE Id = :checkedIn.checkInId].OwnerId,
            'Check-in owned by the rep');
    }

    // ── Open check-in ──

    @IsTest
    static void getActiveCheckInFindsOpenCheckIn() {
        Lead ld = lead('Lead Check In Test Lead');
        Lead other = lead('Lead Check In No Geo Lead');
        LeadCheckInController.checkIn(ld.Id, NEAR_LAT, NEAR_LNG);

        Test.startTest();
        Lead_Check_In__c onLead = LeadCheckInController.getActiveCheckIn(ld.Id);
        Lead_Check_In__c onOther = LeadCheckInController.getActiveCheckIn(other.Id);
        Test.stopTest();

        Assert.isNotNull(onLead, 'Open check-in found on the lead');
        Assert.isNull(onOther, 'No open check-in on another lead');
    }

    // ── Phone errors ──

    @IsTest
    static void clientErrorIsLogged() {
        Lead ld = lead('Lead Check In Test Lead');

        Test.startTest();
        LeadCheckInController.logClientError(ld.Id, 'Location unavailable');
        Test.stopTest();

        Assert.areEqual(1, logCount('Location unavailable'), 'Phone error logged under Lead Checkin');
    }

    // ── Map on the Lead page (checkInMap -> CheckInMapController -> LeadCheckInController) ──

    @IsTest
    static void leadMapShowsCheckInAndCheckOut() {
        Lead ld = lead('Lead Check In Test Lead');
        Id checkInId = LeadCheckInController.checkIn(ld.Id, NEAR_LAT, NEAR_LNG).checkInId;
        LeadCheckInController.checkOut(checkInId, 12.8920, 77.4655, 'Visit notes');

        Test.startTest();
        List<Map<String, Object>> markers = CheckInMapController.getCheckInsForParent(ld.Id);
        Test.stopTest();

        Assert.areEqual(2, markers.size(), 'One check-in and one check-out marker');
        Assert.areEqual('standard:location', markers[0].get('icon'), 'Check-in marker first');
        Assert.isTrue(String.valueOf(markers[1].get('description')).contains('Visit notes'), 'Check-out notes shown');
    }

    // ── Lead_Check_In_Lead_Required validation rule ──

    @IsTest
    static void checkInWithoutLeadIsBlocked() {
        Test.startTest();
        Database.SaveResult result = Database.insert(new Lead_Check_In__c(
            Check_In_Latitude__c  = NEAR_LAT,
            Check_In_Longitude__c = NEAR_LNG,
            Rep_Name__c           = UserInfo.getUserId(),
            Status__c             = 'Checked In'
        ), false);
        Test.stopTest();

        Assert.isFalse(result.isSuccess(), 'A lead check-in needs a lead');
        Assert.areEqual(StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION, result.getErrors()[0].getStatusCode(),
            'Blocked by Lead_Check_In_Lead_Required');
    }

    // ── Check-in distance (Check_In_Max_Distance_Meters label) ──

    /**
    * Method Name: maxDistanceComesFromLabel
    * @author: Tharun N
    * @description: The check-in distance is read from the custom label
    *               Check_In_Max_Distance_Meters.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void maxDistanceComesFromLabel() {
        Test.startTest();
        Double maxDistance = LeadCheckInController.maxDistanceMeters();
        Test.stopTest();

        Assert.areEqual(Double.valueOf(System.Label.Check_In_Max_Distance_Meters.trim()), maxDistance,
            'Distance should come from Check_In_Max_Distance_Meters');
    }

    /**
    * Method Name: checkInAbout750MetersFollowsLabel
    * @author: Tharun N
    * @description: A check-in about 750 m from the lead (refused under the
    *               old 500 m rule) is allowed when the label allows 750 m
    *               or more, as with 1000 m, and refused otherwise.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void checkInAbout750MetersFollowsLabel() {
        Lead ld = lead('Lead Check In Test Lead');
        Double maxDistance = LeadCheckInController.maxDistanceMeters();

        Test.startTest();
        // ~750 m north of the lead
        LeadCheckInController.CheckInResult result = LeadCheckInController.checkIn(ld.Id, 12.898900, LEAD_LNG);
        Test.stopTest();

        Assert.areEqual(maxDistance >= 750, result.success,
            'A check-in about 750 m away should follow the ' + maxDistance.intValue() + ' m limit: ' + result.message);
    }

    /**
    * Method Name: outsideRadiusMessageShowsConfiguredDistance
    * @author: Tharun N
    * @description: The "too far" message shows the distance from the
    *               label, not 500.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void outsideRadiusMessageShowsConfiguredDistance() {
        Lead ld = lead('Lead Check In Test Lead');
        Double maxDistance = LeadCheckInController.maxDistanceMeters();

        Test.startTest();
        LeadCheckInController.CheckInResult result = LeadCheckInController.checkIn(ld.Id, FAR_LAT, FAR_LNG);
        Test.stopTest();

        Assert.isFalse(result.success, 'Check-in 5 km away is refused');
        Assert.isTrue(result.message.contains('within ' + maxDistance.intValue() + ' meters'),
            'Message should show the configured distance: ' + result.message);
    }

    // ── Helpers ──

    private static User newRep() {
        // The B2A Account manager profile is what field reps use; Standard User is the fallback
        Profile repProfile = [
            SELECT Id FROM Profile
            WHERE Name IN ('B2A Account manager', 'Standard User')
            ORDER BY Name
            LIMIT 1
        ];
        String unique = String.valueOf(System.currentTimeMillis());
        return new User(
            Username          = 'lead.checkin.rep.' + unique + '@leadcheckintest.com.invalid',
            LastName          = REP_LAST_NAME,
            Email             = 'lead.checkin.rep@leadcheckintest.com.invalid',
            Alias             = 'lcirep',
            TimeZoneSidKey    = 'Asia/Kolkata',
            LocaleSidKey      = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId         = repProfile.Id
        );
    }

    private static User rep() {
        return [SELECT Id FROM User WHERE LastName = :REP_LAST_NAME LIMIT 1];
    }

    private static Lead lead(String lastName) {
        return [SELECT Id FROM Lead WHERE LastName = :lastName LIMIT 1];
    }

    // Long text area cannot be filtered in SOQL, so the match is done here
    private static Integer logCount(String contains) {
        Integer count = 0;
        for (lcon__Error_Message_Handler__c log : [
            SELECT lcon__Error_Message__c FROM lcon__Error_Message_Handler__c
            WHERE lcon__Error_Point__c = :LOG_POINT
        ]) {
            if (log.lcon__Error_Message__c != null && log.lcon__Error_Message__c.contains(contains)) {
                count++;
            }
        }
        return count;
    }
}